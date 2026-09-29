import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart'
    as native;
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_volatile_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';

/// A frame opened under its session and not yet committed.
///
/// [senderUserId] and [senderDeviceId] are the device the pairwise session
/// authenticated: the one whose session a regular header named, or whose
/// sealed sender block an initial header carried and whose live, cross-signed
/// device record matched it. They are never read from the payload.
final class PairwiseVolatileOpening {
  PairwiseVolatileOpening._(
    this._store,
    this._commit, {
    required this.senderUserId,
    required this.senderDeviceId,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  final String senderUserId;
  final String senderDeviceId;
  final Uint8List payload;
  final PairwiseVolatileStore _store;
  final PairwiseVolatileOpenCommit _commit;

  /// Writes what opening the frame advanced. Until this runs nothing has
  /// changed, so a payload that belongs to another channel can be left
  /// unopened for the channel it belongs to.
  Future<Result<void>> commit() => _store.commitVolatileOpen(_commit);

  @override
  String toString() => 'PairwiseVolatileOpening(<redacted>)';
}

/// Opens the ciphertext of a `signal` frame exactly as a durable envelope is
/// opened, and writes nothing until the caller commits.
///
/// The frame carries no sender, and needs none (`voice-signalling-v1.md`,
/// "How an inbound blob finds its session"): a regular header names its
/// session, and an initial header carries the sealed sender block that locates
/// the private prekeys and names the sender, whose device is then checked
/// against its account's authenticated live device list before the core is
/// asked to accept it.
///
/// Three things a durable envelope may be are refused here, because each is
/// the durable path's: a repair control, a repair replacement, and a frame
/// that crosses the skipped-key bound — which instead asks the peer for the
/// same authenticated repair the durable path asks for, and is dropped.
final class PairwiseVolatileOpener {
  const PairwiseVolatileOpener({
    required this.localDeviceId,
    required this.store,
    required this.volatileStore,
    required this.liveDevices,
    required this.crypto,
    required this.clock,
  });

  final String localDeviceId;
  final PairwiseTransportStore store;
  final PairwiseVolatileStore volatileStore;
  final PairwiseLiveDeviceResolverPort liveDevices;
  final PairwiseSessionCryptoPort crypto;
  final TimeSource clock;

  Future<Result<PairwiseVolatileOpening>> open(Uint8List envelope) async {
    if (!_isUuid(localDeviceId)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final headerResult = await crypto.inspectPublicHeader(envelope: envelope);
    if (headerResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final header =
        (headerResult as Success<native.PairwisePublicHeaderInspection>).value;
    return switch (header.kind) {
      native.PairwisePublicEnvelopeKind.regular => _openRegular(
        envelope,
        header.sessionId,
      ),
      native.PairwisePublicEnvelopeKind.initial => _openInitial(envelope),
    };
  }

  Future<Result<PairwiseVolatileOpening>> _openRegular(
    Uint8List envelope,
    Uint8List sessionId,
  ) async {
    final contextResult = await store.readInboundContext(
      localDeviceId: localDeviceId,
      sessionId: sessionId,
    );
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final context =
        (contextResult as Success<PairwiseInboundPreparationContext>).value;
    final session = context.session;
    if (session == null ||
        session.disposition !=
            PairwiseSessionDisposition.primaryBidirectional) {
      return _unauthenticated();
    }
    final decryptedResult = await crypto.decrypt(
      deviceState: context.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: protocolUuidBytes(localDeviceId),
      session: _nativeSession(session),
      envelope: envelope,
      otherSessionsSkippedKeys: context.otherSessionsSkippedKeyCount,
    );
    if (decryptedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final decrypted =
        (decryptedResult as Success<native.PairwiseRatchetDecryptResult>).value;
    if (decrypted is native.PairwiseRatchetRepairRequired) {
      // The frame is dropped either way. Whether the request could be queued
      // changes nothing about it: a later frame crossing the same bound asks
      // again, and the next durable envelope does too.
      await _requestRepair(context, session);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final opened = decrypted as native.PairwiseRatchetDecryption;
    if (opened.payloadKind != native.PairwiseOpenedPayloadKind.opaque ||
        opened.openedPayload.isEmpty) {
      return _unauthenticated();
    }
    final next = opened.nextSession;
    return Result.success(
      PairwiseVolatileOpening._(
        senderUserId: session.remoteUserId,
        senderDeviceId: session.remoteDeviceId,
        payload: opened.openedPayload,
        volatileStore,
        PairwiseVolatileOpenCommit(
          sessionTransition: PairwiseSessionTransition(
            localDeviceId: localDeviceId,
            remoteUserId: session.remoteUserId,
            remoteDeviceId: session.remoteDeviceId,
            sessionId: next.sessionId,
            nextOpaqueState: next.opaqueState,
            expectedStateVersion: session.stateVersion,
            nextStateVersion: session.stateVersion + 1,
            nextSkippedKeyCount: next.skippedKeyCount,
            disposition: PairwiseSessionDisposition.primaryBidirectional,
            repairState: session.repairState,
            repairAuthorization: session.repairAuthorization,
          ),
        ),
      ),
    );
  }

  Future<Result<PairwiseVolatileOpening>> _openInitial(
    Uint8List envelope,
  ) async {
    final inboundResult = await store.readInboundContext(
      localDeviceId: localDeviceId,
    );
    if (inboundResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final inbound =
        (inboundResult as Success<PairwiseInboundPreparationContext>).value;
    final probeResult = await crypto.probeInitial(
      deviceState: inbound.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: protocolUuidBytes(localDeviceId),
      envelope: envelope,
    );
    if (probeResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final probe =
        (probeResult as Success<native.PairwiseInitialSenderProjection>).value;
    if (probe.isRepairReplacement) {
      return _unauthenticated();
    }
    final senderUserId = protocolUuidString(probe.senderUserId);
    final senderDeviceId = protocolUuidString(probe.senderDeviceId);

    final liveResult = await liveDevices.resolveVerifiedLiveDevices(
      senderUserId,
    );
    if (liveResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final matches = (liveResult as Success<List<VerifiedPairwiseLiveDevice>>)
        .value
        .where((device) => device.deviceId.toLowerCase() == senderDeviceId)
        .toList(growable: false);
    if (matches.length != 1) {
      return _unauthenticated();
    }
    final sender = matches.single;
    final currentVersion = sender.device.bundleVersion;
    if (sender.userId.toLowerCase() != senderUserId ||
        sender.device.isUnsigned ||
        currentVersion == null ||
        probe.senderBundleVersion > currentVersion ||
        probe.senderRegistrationId != sender.device.registrationId ||
        !_same(probe.senderIdentityPublic, sender.device.identityPublic)) {
      return _unauthenticated();
    }

    final preparationResult = await store.readPreparationContext(
      localDeviceId: localDeviceId,
      remoteUserId: sender.userId,
      remoteDeviceId: sender.deviceId,
    );
    if (preparationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final preparation =
        (preparationResult as Success<PairwisePreparationContext>).value;
    final existing = preparation.primary;
    final acceptedResult = await crypto.acceptVerifiedInitial(
      deviceState: preparation.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: protocolUuidBytes(localDeviceId),
      envelope: envelope,
      probe: probe,
      authenticatedSenderDevice: sender.device,
      otherSessionsSkippedKeys: preparation.otherSessionsSkippedKeyCount,
      existingPrimarySession: existing == null
          ? null
          : _nativeSession(existing),
    );
    if (acceptedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final accepted =
        (acceptedResult as Success<native.AcceptedPairwiseInitial>).value;
    if (accepted.openedPayload.isEmpty ||
        accepted.replacedSessionId != null ||
        !_same(accepted.senderUserId, probe.senderUserId) ||
        !_same(accepted.senderDeviceId, probe.senderDeviceId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    PairwiseSessionTransition? demoted;
    final updatedExisting = accepted.updatedExistingSession;
    if (updatedExisting != null) {
      if (existing == null ||
          !_same(existing.sessionId, updatedExisting.sessionId)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      demoted = PairwiseSessionTransition(
        localDeviceId: localDeviceId,
        remoteUserId: existing.remoteUserId,
        remoteDeviceId: existing.remoteDeviceId,
        sessionId: updatedExisting.sessionId,
        nextOpaqueState: updatedExisting.opaqueState,
        expectedStateVersion: existing.stateVersion,
        nextStateVersion: existing.stateVersion + 1,
        nextSkippedKeyCount: updatedExisting.skippedKeyCount,
        disposition: PairwiseSessionDisposition.alternateReceiveOnly,
        repairState: existing.repairState,
        repairAuthorization: existing.repairAuthorization,
      );
    }
    final next = accepted.nextSession;
    return Result.success(
      PairwiseVolatileOpening._(
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        payload: accepted.openedPayload,
        volatileStore,
        PairwiseVolatileOpenCommit(
          sessionTransition: PairwiseSessionTransition(
            localDeviceId: localDeviceId,
            remoteUserId: sender.userId,
            remoteDeviceId: sender.deviceId,
            sessionId: next.sessionId,
            nextOpaqueState: next.opaqueState,
            expectedStateVersion: null,
            nextStateVersion: 1,
            nextSkippedKeyCount: next.skippedKeyCount,
            disposition: switch (accepted.disposition) {
              native.PairwiseSessionDisposition.primary =>
                PairwiseSessionDisposition.primaryBidirectional,
              native.PairwiseSessionDisposition.receiveOnlyAlternate =>
                PairwiseSessionDisposition.alternateReceiveOnly,
            },
            repairState: PairwiseRepairState.ready,
          ),
          demotedExistingSessionTransition: demoted,
          deviceStateTransition: PairwiseDeviceStateTransition(
            nextOpaqueState: accepted.nextDeviceState,
            expectedStateVersion: preparation.deviceState.stateVersion,
            nextStateVersion: preparation.deviceState.stateVersion + 1,
          ),
          consumedOneTimePrekeys: [
            if (accepted.consumedOneTimePrekeyId case final id?)
              ConsumedPairwiseOneTimePrekey(
                kind: PairwiseOneTimePrekeyKind.classicalX25519,
                keyId: id,
              ),
            if (accepted.consumedPqOneTimePrekeyId case final id?)
              ConsumedPairwiseOneTimePrekey(
                kind: PairwiseOneTimePrekeyKind.postQuantumMlKem768,
                keyId: id,
              ),
          ],
          replayMarker: accepted.replayMarker,
          signedPrekeyId: accepted.referencedSignedPrekeyId,
          pqSignedPrekeyId: accepted.referencedPqSignedPrekeyId,
        ),
      ),
    );
  }

  /// The authenticated repair request the durable path sends when its own
  /// envelope crosses the bound (`pairwise-transport-v1.md`, "Replay, skipped
  /// keys, and repair"), queued on the outbox like any other durable send. One
  /// per session: a request already queued, or a session already in repair, is
  /// left alone.
  Future<void> _requestRepair(
    PairwiseInboundPreparationContext context,
    PairwiseSessionSnapshot session,
  ) async {
    if (session.repairState != PairwiseRepairState.ready) {
      return;
    }
    final operationId =
        'pairwise-repair:signal:${protocolBytesToHex(session.sessionId)}';
    final existingResult = await store.readPreparedOperation(operationId);
    if (existingResult is! Success<DurablePairwiseOperation?> ||
        existingResult.value != null) {
      return;
    }
    final preparedResult = await crypto.createAuthenticatedRepairRequest(
      deviceState: context.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: protocolUuidBytes(session.remoteDeviceId),
      session: _nativeSession(session),
      otherSessionsSkippedKeys: context.otherSessionsSkippedKeyCount,
    );
    if (preparedResult case FailureResult()) {
      return;
    }
    final prepared =
        (preparedResult as Success<native.PreparedPairwiseEnvelope>).value;
    await store.commitPreparedSend(
      PairwiseSendCommit(
        operationId: operationId,
        eventId: operationId,
        currentDeviceId: localDeviceId,
        expectedDeviceStateVersion: context.deviceState.stateVersion,
        openedLocalPayload: Uint8List.fromList(
          utf8.encode('session.repair:$operationId'),
        ),
        targets: [
          PreparedPairwiseSendTarget(
            recipientUserId: session.remoteUserId,
            recipientDeviceId: session.remoteDeviceId,
            exactCiphertext: prepared.ciphertext,
            sessionTransition: PairwiseSessionTransition(
              localDeviceId: localDeviceId,
              remoteUserId: session.remoteUserId,
              remoteDeviceId: session.remoteDeviceId,
              sessionId: prepared.nextSession.sessionId,
              nextOpaqueState: prepared.nextSession.opaqueState,
              expectedStateVersion: session.stateVersion,
              nextStateVersion: session.stateVersion + 1,
              nextSkippedKeyCount: prepared.nextSession.skippedKeyCount,
              disposition: PairwiseSessionDisposition.primaryBidirectional,
              repairState: PairwiseRepairState.authenticatedRequestPending,
            ),
          ),
        ],
      ),
    );
  }

  native.PairwiseSessionState _nativeSession(PairwiseSessionSnapshot session) =>
      native.PairwiseSessionState(
        sessionId: session.sessionId,
        opaqueState: session.opaqueState,
        skippedKeyCount: session.skippedKeyCount,
      );

  int _unixDay() =>
      clock.now().toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

Result<PairwiseVolatileOpening> _unauthenticated() => const Result.failure(
  SecurityFailure(SecurityFailureKind.unauthenticatedInput),
);

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _isUuid(String value) => _uuid.hasMatch(value);

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
