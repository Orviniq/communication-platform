import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_downloads.dart';
import 'package:communication_platform/features/attachments/application/attachment_file_actions.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_uploads.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_download_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_preview_sheet.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_upload_tray.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/presentation/chat_attachment_tiles.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_crypto_fake.dart';
import '../../support/attachment_platform_fake.dart';

/// The privacy audit of ADR-089: the text of each value this phase added says
/// nothing about the attachment it is about.
///
/// Each value is built from canaries: a capability, a key, a file name, a
/// path, a MIME type, a caption and a message id that appear nowhere else.
/// Its `toString` is then searched for each of them, in each form the value
/// could print it in. A value whose text names its state names a state and
/// nothing else.
void main() {
  // 43 characters of the capability alphabet.
  final capability = 'CanaryCapability${'q' * 27}';
  final key = Uint8List.fromList(List<int>.generate(32, (i) => 0x71 + i));
  const name = 'CanaryFileName.pdf';
  const pathSegment = 'CanaryPathSegment';
  // A picker's MIME type is kept as it came. A descriptor keeps a type from a
  // short safe list only, so its canary is one of that list.
  const pickedMime = 'application/x-canary-mime';
  const descriptorMime = 'image/webp';
  const caption = 'CanaryCaption';
  const messageId = 'CanaryMessageId';
  final separator = Platform.pathSeparator;
  final directory = Directory(
    ['', 'data', pathSegment, privateAttachmentCacheName].join(separator),
  );
  final copy = File(
    [directory.path, 'outgoing', 'ab' * 16, name].join(separator),
  );

  /// Each form the text of a value could carry a canary in.
  final forbidden = <String>[
    'CanaryCapability',
    // The key as a list, in base64 and in hexadecimal.
    key.sublist(0, 4).join(', '),
    base64Url.encode(key).substring(0, 16),
    base64.encode(key).substring(0, 16),
    protocolBytesToHex(key).substring(0, 16),
    'CanaryFileName',
    pathSegment,
    'x-canary-mime',
    'webp',
    caption,
    messageId,
  ];

  void expectRedacted(Object value) {
    final text = value.toString();
    for (final canary in forbidden) {
      expect(
        text,
        isNot(contains(canary)),
        reason: '${value.runtimeType} printed "$text"',
      );
    }
  }

  final descriptor = EncryptedAttachmentDescriptor(
    capabilityId: capability,
    key: key,
    header: fakeAttachmentHeader(plaintextSize: 1000),
    secretstreamHeader: Uint8List(24),
    encryptedSize: encryptedStreamSize(1000, 65536),
    bucketSize: 65536,
    plaintextSize: 1000,
    displayName: name,
    mimeType: descriptorMime,
    mediaKind: AttachmentMediaKind.image,
    width: 640,
    height: 480,
    caption: caption,
  );
  final picked = PickedAttachment(
    file: copy,
    displayName: name,
    mimeType: pickedMime,
    length: 1000,
    mediaKind: AttachmentMediaKind.image,
    width: 640,
    height: 480,
  );
  final job = AttachmentUploadJob(
    id: 'cd' * 16,
    conversationId: messageId,
    target: const AttachmentUploadTarget.direct(messageId),
    attachment: picked,
    caption: caption,
    state: AttachmentUploadState.failed,
    failure: AttachmentUploadFailureKind.failed,
    descriptor: descriptor,
  );
  final quote = AttachmentUploadQuote(
    fileBytes: 1000,
    uploadBytes: 65536,
    published: true,
    remainingBytes: 1 << 20,
    resetsAt: DateTime.utc(2026, 10, 12),
  );

  test('the canaries are in the values, so their absence means something', () {
    expect(descriptor.capabilityId, capability);
    expect(descriptor.key, key);
    expect(descriptor.displayName, name);
    expect(descriptor.mimeType, descriptorMime);
    expect(descriptor.caption, caption);
    expect(picked.file.path, contains(pathSegment));
    expect(picked.mimeType, pickedMime);
    expect(job.attachment.displayName, name);
  });

  test('a picked file, an upload job and a download job', () {
    expectRedacted(picked);
    expectRedacted(job);
    expect(job.toString(), 'AttachmentUploadJob(failed)');
    for (final state in AttachmentDownloadState.values) {
      final download = AttachmentDownloadJob(
        messageId: messageId,
        descriptor: descriptor,
        state: state,
        progress: 0.5,
      );
      expectRedacted(download);
      expect(download.toString(), 'AttachmentDownloadJob(${state.name})');
    }
  });

  test('each failure kind and each outcome', () {
    for (final stage in AttachmentDownloadStage.values) {
      for (final failure in const <Failure>[
        BackendFailure(BackendFailureCode.notFound),
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
        StorageFailure(StorageFailureKind.unavailable),
        TransportFailure(TransportFailureKind.offline),
      ]) {
        expectRedacted(AttachmentDownloadFailed(failure, stage: stage));
      }
    }
    expectRedacted(AttachmentDownloaded(copy));
    for (final Object kind in [
      ...AttachmentUploadFailureKind.values,
      ...AttachmentUploadState.values,
      ...AttachmentFileOutcome.values,
      ...AttachmentCaptionProblem.values,
      ...AttachmentPickKind.values,
    ]) {
      expectRedacted(kind);
    }
  });

  test('each view model and each intent', () {
    expectRedacted(AttachmentPreviewViewModel.of(picked, quote));
    final row = AttachmentUploadRowViewModel.of(job);
    expect(row.name, name);
    expectRedacted(row);
    for (final state in ChatAttachmentTileState.values) {
      expectRedacted(state);
    }
    for (final intent in <Object>[
      OpenAttachmentIntent(attachment: descriptor),
      DownloadAttachmentIntent(messageId: messageId, attachment: descriptor),
      RetryAttachmentDownloadIntent(descriptor),
      CancelAttachmentDownloadIntent(descriptor),
      CancelAttachmentUploadIntent(job.id),
      RetryAttachmentUploadIntent(job.id),
      DiscardAttachmentUploadIntent(job.id),
    ]) {
      expectRedacted(intent);
    }
  });

  test('each record a port answers', () {
    expectRedacted(descriptor);
    expectRedacted(
      AttachmentUploadResponse(capabilityId: capability, bucketSize: 65536),
    );
    expectRedacted(quote);
    expectRedacted(const AttachmentUploadTarget.direct(messageId));
    expectRedacted(
      AttachmentLocalState(
        messageId: messageId,
        descriptor: descriptor,
        state: AttachmentTransferState.ready,
        cacheId: 'ef' * 16,
        expiresAt: DateTime.utc(2026, 10, 18),
      ),
    );
    expectRedacted(
      CachedAttachmentEntry(
        attachmentId: capability,
        cacheId: 'ef' * 16,
        expiresAt: DateTime.utc(2026, 10, 18),
      ),
    );
    expectRedacted(
      AttachmentSource(
        length: 1000,
        displayName: name,
        mimeType: pickedMime,
        openRead: () => const Stream.empty(),
      ),
    );
    expectRedacted(
      AttachmentDailyAllowance(day: DateTime.utc(2026, 10, 11), spentBytes: 1),
    );
  });

  test('each part of the pipeline, holding the canaries', () {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final states = DriftAttachmentLocalState(database);
    final holds = AttachmentOutgoingHolds()..hold(copy);
    final storage = PrivateAttachmentStorage(root: directory);
    final cache = AttachmentFileCache(
      root: directory,
      states: states,
      clock: const _Clock(),
    );
    final transfer = AttachmentTransferService(
      crypto: AttachmentCryptoService(FakeAttachmentCryptoPort()),
      transport: const _Unused(),
      storage: storage,
    );
    final uploads = AttachmentUploads(
      platform: FakeAttachmentPlatform(),
      holds: holds,
      limits: () => (buckets: const {65536}, dailyBytes: 1 << 20),
      clock: const _Clock(),
      files: () async => cache,
      allowance: () => throw UnimplementedError(),
      states: () async => states,
      transfer: () async => transfer,
      messages: () => throw UnimplementedError(),
    );
    addTearDown(uploads.close);
    final downloads = AttachmentDownloads(
      holds: holds,
      files: () async => cache,
      states: () async => states,
      transfer: () async => transfer,
    );
    addTearDown(downloads.close);

    for (final part in <Object>[
      holds,
      storage,
      cache,
      transfer,
      uploads,
      downloads,
      AttachmentFileActions(
        platform: FakeAttachmentPlatform(),
        files: (_) async => copy,
      ),
      MethodChannelAttachmentPlatform(),
      states,
    ]) {
      expectRedacted(part);
    }
  });
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 10, 11, 9);
}

final class _Unused implements AttachmentTransportPort {
  const _Unused();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
