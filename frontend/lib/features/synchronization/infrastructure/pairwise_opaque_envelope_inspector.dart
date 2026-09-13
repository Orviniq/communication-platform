import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/device_control_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart'
    as native;
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';

/// Piece-13 bridge from opaque sync bytes to side-effect-free native pairwise
/// preparation. Application-event semantics deliberately remain opaque.
final class PairwiseOpaqueEnvelopeInspector implements OpaqueEnvelopeInspector {
  const PairwiseOpaqueEnvelopeInspector({
    required this.localDeviceId,
    required this.store,
    required this.liveDevices,
    required this.crypto,
    required this.applicationProtocol,
    required this.deviceControlCrypto,
    required this.conversationResolver,
    required this.currentUserId,
    required this.clock,
  });

  final String localDeviceId;
  final PairwiseTransportStore store;
  final PairwiseLiveDeviceResolverPort liveDevices;
  final PairwiseSessionCryptoPort crypto;
  final ApplicationProtocolPort applicationProtocol;
  final DeviceControlCryptoPort deviceControlCrypto;
  final ApplicationConversationResolverPort conversationResolver;
  final String currentUserId;
  final TimeSource clock;

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
    required bool allowPotentiallyMls,
  }) async {
    if (!_isUuid(envelopeId) || !_isUuid(localDeviceId)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final headerResult = await crypto.inspectPublicHeader(
      envelope: exactCiphertext,
    );
    if (headerResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final header =
        (headerResult as Success<native.PairwisePublicHeaderInspection>).value;
    return switch (header.kind) {
      native.PairwisePublicEnvelopeKind.regular => _inspectRegular(
        envelopeId: envelopeId,
        envelope: exactCiphertext,
        sessionId: header.sessionId,
        allowPotentiallyMls: allowPotentiallyMls,
      ),
      native.PairwisePublicEnvelopeKind.initial => _inspectInitial(
        envelopeId: envelopeId,
        envelope: exactCiphertext,
        allowPotentiallyMls: allowPotentiallyMls,
      ),
    };
  }

  Future<Result<OpaqueEnvelopeInspection>> _inspectRegular({
    required String envelopeId,
    required Uint8List envelope,
    required Uint8List sessionId,
    required bool allowPotentiallyMls,
  }) async {
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
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final decryptedResult = await crypto.decrypt(
      deviceState: context.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: _uuidBytes(localDeviceId),
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
      final queued = await _queueRepair(
        envelopeId: envelopeId,
        context: context,
        session: session,
      );
      if (queued case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      return Result.success(
        OpaqueEnvelopeInspection(
          opaqueEventId: 'pairwise-repair-trigger:$envelopeId',
          dependency: EnvelopeDependency.directOrLocal,
        ),
      );
    }
    final opened = decrypted as native.PairwiseRatchetDecryption;
    if (opened.openedPayload.isEmpty) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }

    var next = opened.nextSession;
    var repairState = session.repairState;
    Uint8List? repairAuthorization = session.repairAuthorization;
    if (opened.payloadKind ==
        native.PairwiseOpenedPayloadKind.authenticatedRepairControl) {
      final authorizationResult = await crypto
          .consumeAuthenticatedRepairRequest(
            deviceState: context.deviceState.opaqueState,
            unixDay: _unixDay(),
            session: next,
          );
      if (authorizationResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final authorization =
          (authorizationResult
                  as Success<native.AuthenticatedRepairAuthorization>)
              .value;
      next = authorization.nextSession;
      repairState = PairwiseRepairState.replacementPending;
      repairAuthorization = authorization.authorization;
    }

    final preparedResult =
        opened.payloadKind ==
            native.PairwiseOpenedPayloadKind.authenticatedRepairControl
        ? Result<_PreparedApplication>.success(
            _PreparedApplication(
              opaqueEventId: 'pairwise-repair-control:$envelopeId',
            ),
          )
        : await _prepareOpenedPayload(
            envelopeId: envelopeId,
            senderUserId: session.remoteUserId,
            senderDeviceId: session.remoteDeviceId,
            openedPayload: opened.openedPayload,
            allowPotentiallyMls: allowPotentiallyMls,
          );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (preparedResult as Success<_PreparedApplication>).value;
    return Result.success(
      OpaqueEnvelopeInspection(
        opaqueEventId: prepared.opaqueEventId,
        dependency: prepared.dependency,
        groupCommit: prepared.groupCommit,
        pairwiseCommit: PairwiseSyncReceiveCommit(
          envelopeId: envelopeId,
          opaqueEventId: prepared.opaqueEventId,
          senderUserId: session.remoteUserId,
          senderDeviceId: session.remoteDeviceId,
          replayMarker: opened.replayMarker,
          openedOpaquePayload: opened.openedPayload,
          sessionTransition: _syncTransition(
            session: session,
            next: next,
            disposition: session.disposition,
            repairState: repairState,
            repairAuthorization: repairAuthorization,
          ),
          applicationEvent: prepared.applicationEvent,
          unsupportedApplicationEvent: prepared.unsupportedApplicationEvent,
          deviceControlEvent: prepared.deviceControlEvent,
          historyApplicationEvents: prepared.historyApplicationEvents,
        ),
      ),
    );
  }

  Future<Result<OpaqueEnvelopeInspection>> _inspectInitial({
    required String envelopeId,
    required Uint8List envelope,
    required bool allowPotentiallyMls,
  }) async {
    var inboundResult = await store.readInboundContext(
      localDeviceId: localDeviceId,
    );
    if (inboundResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var inbound =
        (inboundResult as Success<PairwiseInboundPreparationContext>).value;
    final probeResult = await crypto.probeInitial(
      deviceState: inbound.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: _uuidBytes(localDeviceId),
      envelope: envelope,
    );
    if (probeResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final probe =
        (probeResult as Success<native.PairwiseInitialSenderProjection>).value;
    final senderUserId = _uuidString(probe.senderUserId);
    final senderDeviceId = _uuidString(probe.senderDeviceId);

    final liveResult = await liveDevices.resolveVerifiedLiveDevices(
      senderUserId,
    );
    if (liveResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final matches = (liveResult as Success<List<VerifiedPairwiseLiveDevice>>)
        .value
        .where((device) => device.deviceId == senderDeviceId)
        .toList(growable: false);
    if (matches.length != 1) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final sender = matches.single;
    final currentVersion = sender.device.bundleVersion;
    if (sender.userId != senderUserId ||
        sender.device.isUnsigned ||
        currentVersion == null ||
        probe.senderBundleVersion > currentVersion ||
        probe.senderRegistrationId != sender.device.registrationId ||
        !_same(probe.senderIdentityPublic, sender.device.identityPublic)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    final preparationResult = await store.readPreparationContext(
      localDeviceId: localDeviceId,
      remoteUserId: senderUserId,
      remoteDeviceId: senderDeviceId,
    );
    if (preparationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final preparation =
        (preparationResult as Success<PairwisePreparationContext>).value;
    PairwiseSessionSnapshot? replaced;
    if (probe.replacedSessionId != null) {
      inboundResult = await store.readInboundContext(
        localDeviceId: localDeviceId,
        sessionId: probe.replacedSessionId,
      );
      if (inboundResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      inbound =
          (inboundResult as Success<PairwiseInboundPreparationContext>).value;
      replaced = inbound.session;
      if (replaced == null ||
          replaced.disposition !=
              PairwiseSessionDisposition.primaryBidirectional ||
          replaced.repairState !=
              PairwiseRepairState.authenticatedRequestPending ||
          replaced.remoteUserId != senderUserId ||
          replaced.remoteDeviceId != senderDeviceId) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
    }

    final acceptedResult = await crypto.acceptVerifiedInitial(
      deviceState: preparation.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: _uuidBytes(localDeviceId),
      envelope: envelope,
      probe: probe,
      authenticatedSenderDevice: sender.device,
      otherSessionsSkippedKeys: probe.isRepairReplacement
          ? inbound.otherSessionsSkippedKeyCount
          : preparation.otherSessionsSkippedKeyCount,
      existingPrimarySession: probe.isRepairReplacement
          ? null
          : _nativeSessionOrNull(preparation.primary),
      replacedSession: _nativeSessionOrNull(replaced),
    );
    if (acceptedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final accepted =
        (acceptedResult as Success<native.AcceptedPairwiseInitial>).value;
    if (accepted.openedPayload.isEmpty ||
        !_same(accepted.senderUserId, probe.senderUserId) ||
        !_same(accepted.senderDeviceId, probe.senderDeviceId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final disposition = switch (accepted.disposition) {
      native.PairwiseSessionDisposition.primary =>
        PairwiseSessionDisposition.primaryBidirectional,
      native.PairwiseSessionDisposition.receiveOnlyAlternate =>
        PairwiseSessionDisposition.alternateReceiveOnly,
    };
    PairwiseSyncSessionTransition? demoted;
    final updatedExisting = accepted.updatedExistingSession;
    if (updatedExisting != null) {
      final existing = preparation.primary;
      if (existing == null ||
          !_same(existing.sessionId, updatedExisting.sessionId)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      demoted = _syncTransition(
        session: existing,
        next: updatedExisting,
        disposition: PairwiseSessionDisposition.alternateReceiveOnly,
        repairState: existing.repairState,
        repairAuthorization: existing.repairAuthorization,
      );
    }

    final consumed = <PairwiseSyncConsumedPrekey>[
      if (accepted.consumedOneTimePrekeyId case final id?)
        PairwiseSyncConsumedPrekey(algorithm: 0, keyId: id),
      if (accepted.consumedPqOneTimePrekeyId case final id?)
        PairwiseSyncConsumedPrekey(algorithm: 1, keyId: id),
    ];
    final preparedResult = probe.isRepairReplacement
        ? Result<_PreparedApplication>.success(
            _PreparedApplication(
              opaqueEventId: 'pairwise-repair-replacement:$envelopeId',
            ),
          )
        : await _prepareOpenedPayload(
            envelopeId: envelopeId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            openedPayload: accepted.openedPayload,
            allowPotentiallyMls: allowPotentiallyMls,
          );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (preparedResult as Success<_PreparedApplication>).value;
    return Result.success(
      OpaqueEnvelopeInspection(
        opaqueEventId: prepared.opaqueEventId,
        dependency: prepared.dependency,
        groupCommit: prepared.groupCommit,
        pairwiseCommit: PairwiseSyncReceiveCommit(
          envelopeId: envelopeId,
          opaqueEventId: prepared.opaqueEventId,
          senderUserId: senderUserId,
          senderDeviceId: senderDeviceId,
          replayMarker: accepted.replayMarker,
          openedOpaquePayload: accepted.openedPayload,
          signedPrekeyId: accepted.referencedSignedPrekeyId,
          pqSignedPrekeyId: accepted.referencedPqSignedPrekeyId,
          replacedSessionId: accepted.replacedSessionId,
          sessionTransition: PairwiseSyncSessionTransition(
            localDeviceId: localDeviceId,
            remoteUserId: senderUserId,
            remoteDeviceId: senderDeviceId,
            sessionId: accepted.nextSession.sessionId,
            nextOpaqueState: accepted.nextSession.opaqueState,
            expectedStateVersion: null,
            nextStateVersion: 1,
            nextSkippedKeyCount: accepted.nextSession.skippedKeyCount,
            disposition: disposition.index,
            repairState: PairwiseRepairState.ready.index,
          ),
          demotedExistingSessionTransition: demoted,
          deviceStateTransition: PairwiseSyncDeviceStateTransition(
            nextOpaqueState: accepted.nextDeviceState,
            expectedStateVersion: preparation.deviceState.stateVersion,
            nextStateVersion: preparation.deviceState.stateVersion + 1,
          ),
          consumedOneTimePrekeys: consumed,
          applicationEvent: prepared.applicationEvent,
          unsupportedApplicationEvent: prepared.unsupportedApplicationEvent,
          deviceControlEvent: prepared.deviceControlEvent,
          historyApplicationEvents: prepared.historyApplicationEvents,
        ),
      ),
    );
  }

  Future<Result<_PreparedApplication>> _prepareOpenedPayload({
    required String envelopeId,
    required String senderUserId,
    required String senderDeviceId,
    required Uint8List openedPayload,
    required bool allowPotentiallyMls,
  }) async {
    if (!_isGroupTransport(openedPayload)) {
      return _prepareApplication(
        envelopeId: envelopeId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        openedPayload: openedPayload,
      );
    }
    if (!allowPotentiallyMls) {
      // A queue gap blocks everything that could depend on MLS state this
      // device no longer has, so the object stays deferred.
      return Result.success(
        _PreparedApplication(
          opaqueEventId: 'group-deferred:$envelopeId',
          dependency: EnvelopeDependency.potentiallyMls,
        ),
      );
    }
    return const Result.failure(
      UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
    );
  }

  Future<Result<_PreparedApplication>> _prepareApplication({
    required String envelopeId,
    required String senderUserId,
    required String senderDeviceId,
    required Uint8List openedPayload,
  }) async {
    if (_isDeviceControl(openedPayload)) {
      final controlResult = await deviceControlCrypto.decodeDeviceControl(
        openedPayload,
      );
      if (controlResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final control = (controlResult as Success<DeviceControlEvent>).value;
      if (protocolUuidString(control.senderUserId) !=
              senderUserId.toLowerCase() ||
          protocolUuidString(control.senderDeviceId) !=
              senderDeviceId.toLowerCase()) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      if (control.targetDeviceId != null &&
          !_same(control.targetDeviceId!, _uuidBytes(localDeviceId))) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      if (control is HistoryTransferRequestEvent ||
          control is HistoryTransferBatchEvent ||
          control is HistoryTransferCompleteEvent ||
          control is HistoryTransferUnavailableEvent) {
        if (senderUserId != currentUserId.toLowerCase()) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
        }
      }
      final historyEvents = <ApplicationEventCommit>[];
      if (control is HistoryTransferBatchEvent) {
        for (final canonical in control.canonicalEvents) {
          final prepared = await _prepareTransferredApplication(canonical);
          if (prepared case FailureResult(failure: final failure)) {
            return Result.failure(failure);
          }
          historyEvents.add(
            (prepared as Success<ApplicationEventCommit>).value,
          );
        }
      }
      return Result.success(
        _PreparedApplication(
          opaqueEventId:
              'device-control:${protocolBytesToHex(control.eventId)}',
          deviceControlEvent: control,
          historyApplicationEvents: historyEvents,
        ),
      );
    }
    final decodedResult = await applicationProtocol.decode(openedPayload);
    if (decodedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final decoded = (decodedResult as Success<DecodedApplicationEvent>).value;
    if (decoded is UnsupportedApplicationEvent) {
      final header = decoded.header;
      if (header != null &&
          (protocolUuidString(header.senderUserId) !=
                  senderUserId.toLowerCase() ||
              protocolUuidString(header.senderDeviceId) !=
                  senderDeviceId.toLowerCase())) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      final eventId = header == null
          ? null
          : protocolBytesToHex(header.eventId);
      final recordKey = eventId == null
          ? 'unsupported-envelope:$envelopeId'
          : 'unsupported-event:$eventId';
      return Result.success(
        _PreparedApplication(
          opaqueEventId: recordKey,
          unsupportedApplicationEvent: UnsupportedApplicationCommit(
            recordKey: recordKey,
            version: decoded.version,
            kindValue: decoded.kindValue,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            eventId: header?.eventId,
            conversationId: header?.conversationId,
            senderCounter: header?.senderCounter,
            currentUserId: currentUserId.toLowerCase(),
            retainedBytes: decoded.retainedBytes,
            authenticatedAt: clock.now().toUtc(),
          ),
        ),
      );
    }
    final supported = decoded as SupportedApplicationEvent;
    final event = supported.event;
    if (protocolUuidString(event.senderUserId) != senderUserId.toLowerCase() ||
        protocolUuidString(event.senderDeviceId) !=
            senderDeviceId.toLowerCase() ||
        event.kind == ApplicationEventKind.typingSet) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final conversationResult = await conversationResolver.resolve(
      event: event,
      currentUserId: currentUserId,
    );
    if (conversationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final conversation =
        (conversationResult as Success<ResolvedApplicationConversation>).value;
    final eventId = protocolBytesToHex(event.eventId);
    return Result.success(
      _PreparedApplication(
        opaqueEventId: 'application:$eventId',
        applicationEvent: ApplicationEventCommit(
          event: event,
          canonicalBytes: supported.canonicalBytes,
          currentUserId: currentUserId.toLowerCase(),
          currentDeviceId: localDeviceId.toLowerCase(),
          conversationKind: conversation.kind.index,
          peerUserId: conversation.peerUserId,
          localOrigin: false,
          authenticatedAt: clock.now().toUtc(),
        ),
      ),
    );
  }

  Future<Result<ApplicationEventCommit>> _prepareTransferredApplication(
    Uint8List canonical,
  ) async {
    final decodedResult = await applicationProtocol.decode(canonical);
    if (decodedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final decoded = (decodedResult as Success<DecodedApplicationEvent>).value;
    if (decoded is! SupportedApplicationEvent ||
        decoded.event.kind == ApplicationEventKind.typingSet ||
        !_same(decoded.canonicalBytes, canonical)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final conversationResult = await conversationResolver.resolve(
      event: decoded.event,
      currentUserId: currentUserId,
    );
    if (conversationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final conversation =
        (conversationResult as Success<ResolvedApplicationConversation>).value;
    return Result.success(
      ApplicationEventCommit(
        event: decoded.event,
        canonicalBytes: decoded.canonicalBytes,
        currentUserId: currentUserId.toLowerCase(),
        currentDeviceId: localDeviceId.toLowerCase(),
        conversationKind: conversation.kind.index,
        peerUserId: conversation.peerUserId,
        localOrigin: false,
        authenticatedAt: clock.now().toUtc(),
      ),
    );
  }

  Future<Result<void>> _queueRepair({
    required String envelopeId,
    required PairwiseInboundPreparationContext context,
    required PairwiseSessionSnapshot session,
  }) async {
    final operationId = 'pairwise-repair:$envelopeId';
    final existingResult = await store.readPreparedOperation(operationId);
    if (existingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final existing =
        (existingResult as Success<DurablePairwiseOperation?>).value;
    if (existing != null) {
      if (existing.currentDeviceId != localDeviceId.toLowerCase() ||
          existing.targets.length != 1 ||
          existing.targets.single.recipientUserId != session.remoteUserId ||
          existing.targets.single.recipientDeviceId != session.remoteDeviceId) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      return const Result.success(null);
    }
    if (session.repairState != PairwiseRepairState.ready) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final preparedResult = await crypto.createAuthenticatedRepairRequest(
      deviceState: context.deviceState.opaqueState,
      unixDay: _unixDay(),
      recipientDeviceId: _uuidBytes(session.remoteDeviceId),
      session: _nativeSession(session),
      otherSessionsSkippedKeys: context.otherSessionsSkippedKeyCount,
    );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared =
        (preparedResult as Success<native.PreparedPairwiseEnvelope>).value;
    final marker = Uint8List.fromList(
      utf8.encode('session.repair:$envelopeId'),
    );
    return store.commitPreparedSend(
      PairwiseSendCommit(
        operationId: operationId,
        eventId: operationId,
        currentDeviceId: localDeviceId,
        expectedDeviceStateVersion: context.deviceState.stateVersion,
        openedLocalPayload: marker,
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

  PairwiseSyncSessionTransition _syncTransition({
    required PairwiseSessionSnapshot session,
    required native.PairwiseSessionState next,
    required PairwiseSessionDisposition disposition,
    required PairwiseRepairState repairState,
    required Uint8List? repairAuthorization,
  }) => PairwiseSyncSessionTransition(
    localDeviceId: localDeviceId,
    remoteUserId: session.remoteUserId,
    remoteDeviceId: session.remoteDeviceId,
    sessionId: next.sessionId,
    nextOpaqueState: next.opaqueState,
    expectedStateVersion: session.stateVersion,
    nextStateVersion: session.stateVersion + 1,
    nextSkippedKeyCount: next.skippedKeyCount,
    disposition: disposition.index,
    repairState: repairState.index,
    repairAuthorization: repairAuthorization,
  );

  native.PairwiseSessionState _nativeSession(PairwiseSessionSnapshot session) =>
      native.PairwiseSessionState(
        sessionId: session.sessionId,
        opaqueState: session.opaqueState,
        skippedKeyCount: session.skippedKeyCount,
      );

  native.PairwiseSessionState? _nativeSessionOrNull(
    PairwiseSessionSnapshot? session,
  ) => session == null ? null : _nativeSession(session);

  int _unixDay() =>
      clock.now().toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

Uint8List _uuidBytes(String value) {
  final compact = value.replaceAll('-', '').toLowerCase();
  if (compact.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(compact)) {
    throw const FormatException('invalid UUID');
  }
  return Uint8List.fromList([
    for (var index = 0; index < 32; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

String _uuidString(Uint8List bytes) {
  if (bytes.length != 16) {
    throw const FormatException('invalid UUID bytes');
  }
  final compact = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${compact.substring(0, 8)}-${compact.substring(8, 12)}-'
      '${compact.substring(12, 16)}-${compact.substring(16, 20)}-'
      '${compact.substring(20)}';
}

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

final class _PreparedApplication {
  const _PreparedApplication({
    required this.opaqueEventId,
    this.dependency = EnvelopeDependency.directOrLocal,
    this.groupCommit,
    this.applicationEvent,
    this.unsupportedApplicationEvent,
    this.deviceControlEvent,
    this.historyApplicationEvents = const [],
  });

  final String opaqueEventId;
  final EnvelopeDependency dependency;
  final PreparedGroupInboxCommit? groupCommit;
  final ApplicationEventCommit? applicationEvent;
  final UnsupportedApplicationCommit? unsupportedApplicationEvent;
  final DeviceControlEvent? deviceControlEvent;
  final List<ApplicationEventCommit> historyApplicationEvents;
}

bool _isGroupTransport(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x43 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x47 &&
    bytes[3] == 0x54 &&
    bytes[4] == 0x4f &&
    bytes[5] == 0x30 &&
    bytes[6] == 0x30 &&
    bytes[7] == 0x31;

bool _isDeviceControl(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x43 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x43 &&
    bytes[4] == 0x56 &&
    bytes[5] == 0x30 &&
    bytes[6] == 0x30 &&
    bytes[7] == 0x31;
