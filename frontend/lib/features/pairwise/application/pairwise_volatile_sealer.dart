import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_volatile_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';

/// Why one device was sealed nothing.
enum PairwiseVolatileRefusal {
  /// Its account's authenticated live device list does not name it.
  notLive,

  /// Its account's identity or device list is blocked: a changed safety
  /// number, or a device-log fork.
  identityBlocked,

  /// Its account's device list could not be authenticated just now.
  unverified,

  /// No ready primary session exists with it. Starting one on a volatile frame
  /// is refused: see [PairwiseVolatileSealer].
  noSession,

  /// Its session is waiting on a repair, which the durable path carries.
  sessionUnderRepair,

  /// The sealed frame is not one of the lengths the channel carries.
  offBucket,

  /// The native core refused to seal it.
  sealFailed,
}

/// What one target of a volatile seal came to.
sealed class PairwiseVolatileSealOutcome {
  const PairwiseVolatileSealOutcome({
    required this.userId,
    required this.deviceId,
  });

  final String userId;
  final String deviceId;
}

/// Sealed, and its advanced session state committed.
final class PairwiseVolatileSealed extends PairwiseVolatileSealOutcome {
  PairwiseVolatileSealed({
    required super.userId,
    required super.deviceId,
    required Uint8List frame,
  }) : frame = Uint8List.fromList(frame);

  /// The exact `EnvelopeV1` to send. Nothing else holds it.
  final Uint8List frame;

  @override
  String toString() => 'PairwiseVolatileSealed(<redacted>)';
}

final class PairwiseVolatileRefused extends PairwiseVolatileSealOutcome {
  const PairwiseVolatileRefused({
    required super.userId,
    required super.deviceId,
    required this.reason,
  });

  final PairwiseVolatileRefusal reason;
}

/// Seals one payload to each target device's pairwise session for a volatile
/// frame, and commits every advanced state before handing any frame back.
///
/// It is the durable fan-out without its queue (`voice-signalling-v1.md`,
/// "Volatile seal and open"): the same authenticated live device list, the
/// same reviewed native ratchet step, the same compare-and-set commit, and no
/// outbox row, because a frame is either delivered at once or dropped, and a
/// retry seals again on the next message number.
///
/// **It seals only on a ready primary session.** The design record starts a
/// session over a volatile frame when none exists; that is refused here, as
/// [PairwiseVolatileRefusal.noSession]. The ratchet writes its initial header
/// on the first message only, so a first message that is dropped — the
/// ordinary fate of a `signal` frame to a device that is not connected —
/// leaves this device holding a session its peer never saw, and every later
/// message on it, durable ones included, reaches a peer that cannot open it.
/// A session begins on the durable path, where the first message is queued
/// until it is delivered.
final class PairwiseVolatileSealer {
  const PairwiseVolatileSealer({
    required this.store,
    required this.volatileStore,
    required this.liveDevices,
    required this.crypto,
    required this.clock,
  });

  final PairwiseTransportStore store;
  final PairwiseVolatileStore volatileStore;
  final PairwiseLiveDeviceResolverPort liveDevices;
  final PairwiseOutboundPreparationPort crypto;
  final TimeSource clock;

  /// One outcome for each of [targets], in their order.
  ///
  /// A failure means nothing was committed and no frame exists: the store
  /// refused the commit, or could not be read.
  Future<Result<List<PairwiseVolatileSealOutcome>>> seal({
    required String currentUserId,
    required String currentDeviceId,
    required List<PairwiseLiveDevice> targets,
    required Uint8List payload,
    required Set<int> allowedLengths,
  }) async {
    final local = currentDeviceId.toLowerCase();
    final devices = targets.map((target) => target.deviceId.toLowerCase());
    if (!_isUuid(currentUserId) ||
        !_isUuid(currentDeviceId) ||
        targets.isEmpty ||
        targets.any(
          (target) => !_isUuid(target.userId) || !_isUuid(target.deviceId),
        ) ||
        devices.toSet().length != targets.length ||
        devices.contains(local) ||
        payload.isEmpty ||
        allowedLengths.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }

    final liveByUser = <String, Result<List<VerifiedPairwiseLiveDevice>>>{};
    for (final userId in targets.map((target) => target.userId).toSet()) {
      liveByUser[userId] = await liveDevices.resolveVerifiedLiveDevices(userId);
    }
    final unixDay =
        clock.now().toUtc().millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;

    final outcomes = <PairwiseVolatileSealOutcome>[];
    final transitions = <PairwiseSessionTransition>[];
    final deviceStateVersions = <int>{};
    for (final target in targets) {
      PairwiseVolatileRefused refuse(PairwiseVolatileRefusal reason) =>
          PairwiseVolatileRefused(
            userId: target.userId,
            deviceId: target.deviceId,
            reason: reason,
          );

      final live = liveByUser[target.userId]!;
      if (live case FailureResult(failure: final failure)) {
        outcomes.add(
          refuse(
            failure is SecurityFailure &&
                    failure.kind == SecurityFailureKind.policyBlocked
                ? PairwiseVolatileRefusal.identityBlocked
                : PairwiseVolatileRefusal.unverified,
          ),
        );
        continue;
      }
      final recipient = (live as Success<List<VerifiedPairwiseLiveDevice>>)
          .value
          .where(
            (device) =>
                device.userId.toLowerCase() == target.userId.toLowerCase() &&
                device.deviceId.toLowerCase() == target.deviceId.toLowerCase(),
          )
          .firstOrNull;
      if (recipient == null) {
        outcomes.add(refuse(PairwiseVolatileRefusal.notLive));
        continue;
      }

      // From here on the authenticated list's spelling of both ids is the
      // one used, because it is the one the stored session was written with.
      final contextResult = await store.readPreparationContext(
        localDeviceId: local,
        remoteUserId: recipient.userId,
        remoteDeviceId: recipient.deviceId,
      );
      if (contextResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final context =
          (contextResult as Success<PairwisePreparationContext>).value;
      final primary = context.primary;
      if (primary == null) {
        outcomes.add(refuse(PairwiseVolatileRefusal.noSession));
        continue;
      }
      if (primary.disposition !=
              PairwiseSessionDisposition.primaryBidirectional ||
          primary.repairState != PairwiseRepairState.ready ||
          primary.repairAuthorization != null) {
        outcomes.add(refuse(PairwiseVolatileRefusal.sessionUnderRepair));
        continue;
      }

      final preparedResult = await crypto.prepareOutbound(
        currentDeviceId: local,
        recipient: recipient,
        openedOpaquePayload: payload,
        migrationUnixDay: unixDay,
        context: context,
        claim: null,
      );
      if (preparedResult case FailureResult()) {
        outcomes.add(refuse(PairwiseVolatileRefusal.sealFailed));
        continue;
      }
      final prepared =
          (preparedResult as Success<PairwisePreparedOutbound>).value;
      if (!allowedLengths.contains(prepared.exactCiphertext.length) ||
          prepared.disposition !=
              PairwiseSessionDisposition.primaryBidirectional ||
          prepared.repairState != PairwiseRepairState.ready) {
        // Never committed, so the ratchet step it took is discarded with it
        // and the frame never exists outside this method.
        outcomes.add(refuse(PairwiseVolatileRefusal.offBucket));
        continue;
      }
      deviceStateVersions.add(context.deviceState.stateVersion);
      transitions.add(
        PairwiseSessionTransition(
          localDeviceId: local,
          remoteUserId: recipient.userId,
          remoteDeviceId: recipient.deviceId,
          sessionId: prepared.sessionId,
          nextOpaqueState: prepared.nextOpaqueSessionState,
          expectedStateVersion: primary.stateVersion,
          nextStateVersion: primary.stateVersion + 1,
          nextSkippedKeyCount: prepared.nextSkippedKeyCount,
          disposition: PairwiseSessionDisposition.primaryBidirectional,
          repairState: PairwiseRepairState.ready,
        ),
      );
      outcomes.add(
        PairwiseVolatileSealed(
          userId: target.userId,
          deviceId: target.deviceId,
          frame: prepared.exactCiphertext,
        ),
      );
    }

    if (transitions.isEmpty) {
      return Result.success(List.unmodifiable(outcomes));
    }
    if (deviceStateVersions.length != 1) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final committed = await volatileStore.commitVolatileSeal(
      PairwiseVolatileSealCommit(
        currentDeviceId: local,
        expectedDeviceStateVersion: deviceStateVersions.single,
        transitions: transitions,
      ),
    );
    if (committed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(List.unmodifiable(outcomes));
  }
}

bool _isUuid(String value) => _uuid.hasMatch(value);

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
