import 'dart:async';
import 'dart:io';

import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_platform_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_allowance_store.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// The attachment pipeline, composed (ADR-089).
//
// Nothing here builds a screen. Two rules hold for every provider:
//
// - **One trust.** The transport is built by the networking foundation, on
//   the provisioned trust and the one token coordinator (D12). A runtime that
//   installed no foundation composes no transport, as
//   `networkingFoundationProvider` composes none, and a foundation on the
//   platform's default trust builds none either.
// - **One session.** What does work — the transport, with its requests and
//   its partial download, and the transfer service over it — belongs to one
//   [MessagingScope] and ends with its session, as the voice call does
//   ([attachmentSessionActiveProvider]). The rest holds no work: the files
//   and the rows outlive the session until the wipe deletes them.
//
// A provider that cannot be built throws, and an attachment feature that
// reads it reports itself not available.

/// Whether the session [scope] belongs to is still the one running: false
/// from the moment a logout or an erasure begins, and once a revocation or any
/// other end of the session has signed the account out.
///
/// The same rule as `voiceSessionActiveProvider`, kept here so the attachment
/// pipeline does not depend on the voice feature's composition.
final attachmentSessionActiveProvider = Provider.family<bool, MessagingScope>((
  ref,
  scope,
) {
  final session = ref.watch(authenticationControllerProvider);
  return !session.isTearingDown && session.userId == scope.userId;
});

/// The Android attachment boundary: the pickers, Open, Save and Share.
final attachmentPlatformProvider = Provider<AttachmentPlatformPort>(
  (ref) => MethodChannelAttachmentPlatform(),
);

/// The private cache, or an error when the platform names none.
///
/// There is no other directory to fall back to: one the native wipe does not
/// delete would keep decrypted files after a logout (D8).
final attachmentCacheRootProvider = FutureProvider<Directory>((ref) async {
  final root = await privateAttachmentCacheRoot();
  if (root == null) {
    throw StateError('Attachments are not available: no private cache.');
  }
  return root;
});

/// The temporary files of encryption and download.
final attachmentStorageProvider = FutureProvider<AttachmentStoragePort>(
  (ref) async => PrivateAttachmentStorage(
    root: await ref.watch(attachmentCacheRootProvider.future),
  ),
);

/// Encryption and decryption of attachment streams, through the Rust core.
final attachmentCryptoServiceProvider = Provider<AttachmentCryptoService>(
  (ref) => AttachmentCryptoService(ref.watch(attachmentCryptoProvider)),
);

/// What this device has uploaded today.
final attachmentAllowanceProvider = FutureProvider<AttachmentAllowancePort>(
  (ref) async => DriftAttachmentAllowanceStore(
    await ref.watch(localDatabaseProvider.future),
  ),
);

/// The durable state of each attachment on this device.
final attachmentLocalStateProvider = FutureProvider<AttachmentLocalStatePort>(
  (ref) async =>
      DriftAttachmentLocalState(await ref.watch(localDatabaseProvider.future)),
);

/// The decrypted files and the picker's copies, in the private cache.
///
/// One for the process, so that every sweep, adoption and eviction runs in
/// one queue and the first sweep is the process's first.
final attachmentFileCacheProvider = FutureProvider<AttachmentFileCache>(
  (ref) async => AttachmentFileCache(
    root: await ref.watch(attachmentCacheRootProvider.future),
    states: await ref.watch(attachmentLocalStateProvider.future),
    clock: ref.watch(timeSourceProvider),
  ),
);

/// The outgoing copies something in this process still holds, which no sweep
/// may delete.
///
/// Nothing holds one before the send flow exists. The send flow answers here
/// with every copy waiting in its preview step or in an upload job.
final attachmentLiveOutgoingProvider = Provider<Iterable<File> Function()>(
  (ref) =>
      () => const <File>[],
);

/// The sweep messaging asks for after a deletion.
final attachmentSweepProvider = Provider<AttachmentSweepPort>(
  _FileCacheSweep.new,
);

/// The attachment transport of one session, on the provisioned trust.
///
/// Throws when the runtime installed no networking foundation, when the
/// foundation holds no provisioned trust, and once the session has ended. The
/// session's end disposes it, which aborts its requests and deletes the
/// partial download it kept.
final attachmentTransportProvider =
    FutureProvider.family<AttachmentTransportPort, MessagingScope>((
      ref,
      scope,
    ) async {
      final foundation = ref.watch(networkingFoundationProvider);
      if (!ref.watch(attachmentSessionActiveProvider(scope))) {
        throw StateError('Attachments are not available: the session ended.');
      }
      final transport = foundation.attachmentTransport(
        config: ref.watch(serverConfigSnapshotProvider),
        allowance: await ref.watch(attachmentAllowanceProvider.future),
        clock: ref.watch(timeSourceProvider),
        storage: await ref.watch(attachmentStorageProvider.future),
      );
      ref.onDispose(() => unawaited(transport.close()));
      return transport;
    });

/// Encrypt and upload, and download and decrypt, for one session.
final attachmentTransferServiceProvider =
    FutureProvider.family<AttachmentTransferService, MessagingScope>((
      ref,
      scope,
    ) async {
      final transport = await ref.watch(
        attachmentTransportProvider(scope).future,
      );
      return AttachmentTransferService(
        crypto: ref.watch(attachmentCryptoServiceProvider),
        transport: transport,
        storage: await ref.watch(attachmentStorageProvider.future),
      );
    });

/// [AttachmentSweepPort] over the file cache, resolved when a sweep is asked
/// for rather than when messaging is composed: messaging works whether or not
/// this device can keep attachment files, and a device that cannot has none
/// to sweep.
final class _FileCacheSweep implements AttachmentSweepPort {
  const _FileCacheSweep(this._ref);

  final Ref _ref;

  @override
  Future<void> sweepAfterDeletion() async {
    try {
      final cache = await _ref.read(attachmentFileCacheProvider.future);
      await cache.sweep(
        liveOutgoing: _ref.read(attachmentLiveOutgoingProvider)(),
      );
    } on Object {
      // No private cache, or no database: nothing to sweep, and the wipe
      // deletes whatever there was.
    }
  }
}
