import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/devices/application/ports/prekey_maintenance_ports.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';

/// Returns a newly verified peer's held envelopes to inspection
/// (ADR-093 D16).
///
/// The bridge from the contacts application to this feature's store, in the
/// way the live-device resolver adapter bridges the other direction, so that
/// neither application layer imports the other. The release is due one
/// second ahead, the engine's shortest retry, and the supervisor's retry
/// wake runs the cycle that opens them; nothing else needs to be told.
///
/// The store is opened when a verification happens, not when the service is
/// composed: authenticating a peer needs no inbox, and composing it must not
/// open the database for a verification that may never come.
final class SyncHeldEnvelopeRelease implements PeerVerificationObserver {
  const SyncHeldEnvelopeRelease({required this.store, required this.clock});

  static const releaseDelay = Duration(seconds: 1);

  final Future<DurableSyncStore> Function() store;
  final TimeSource clock;

  @override
  Future<void> peerVerified(String userId) async {
    await (await store()).releaseHeldEnvelopes(
      senderUserId: userId,
      dueAt: clock.now().add(releaseDelay),
    );
  }
}

/// Which held senders are verified, from the stored trust records only.
///
/// No network: the sweep asks every cycle, and the inspection after a release
/// refreshes the peer in full anyway.
final class ContactHeldSenderTrust implements HeldSenderTrustPort {
  const ContactHeldSenderTrust(this.local);

  final ContactLocalPort local;

  @override
  Future<Result<Set<String>>> verifiedAmong(List<String> userIds) async {
    final verified = <String>{};
    for (final userId in userIds) {
      final trustResult = await local.readTrust(userId);
      if (trustResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final trust = (trustResult as Success<ContactTrustRecord?>).value;
      if (trust != null && trust.isSensitiveActionAllowed) {
        verified.add(userId);
      }
    }
    return Result.success(Set.unmodifiable(verified));
  }
}

/// The earliest hold day, read from the inbox for prekey maintenance
/// (ADR-093 D17).
final class SyncHeldEnvelopeRetention implements HeldEnvelopeRetentionPort {
  const SyncHeldEnvelopeRetention(this.store);

  final DriftSyncStore store;

  @override
  Future<Result<int?>> earliestHoldUnixDay() async {
    final earliest = await store.readEarliestHoldTime();
    if (earliest case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final heldAt = (earliest as Success<DateTime?>).value;
    return Result.success(
      heldAt == null
          ? null
          : heldAt.toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay,
    );
  }
}
