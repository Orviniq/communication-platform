import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/beta_mls_crypto_port.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_key_package_ports.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

/// Closed-beta adapter for the real native suite. Production never composes it.
final class NativeBetaGroupMls implements GroupMlsCryptoPort {
  const NativeBetaGroupMls(
    this.crypto, {
    this.admission,
    this.applicationProtocol,
    this.applicationIdentity,
    this.transcript,
  });

  final BetaMlsCryptoPort crypto;
  final GroupMlsAdmissionPort? admission;
  final ApplicationProtocolPort? applicationProtocol;
  final GroupApplicationIdentityPort? applicationIdentity;
  final GroupControlTranscriptPort? transcript;

  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) async {
    try {
      final header = _TransportReader(mlsObject)
        ..expect(ascii.encode('CPGTO001'));
      if (header.u16() != 3) {
        throw const FormatException('unsupported group transport');
      }
      return switch (header.u8()) {
        1 => Result.success(
          GroupMlsTransportProbe(
            kind: GroupMlsTransportKind.welcome,
            groupId: _parseIncomingWelcomeTransport(mlsObject).event.groupId,
          ),
        ),
        2 => Result.success(
          _controlProbe(_parseIncomingControlTransport(mlsObject)),
        ),
        3 => Result.success(
          GroupMlsTransportProbe(
            kind: GroupMlsTransportKind.application,
            groupId: _hex(
              _parseIncomingApplicationTransport(mlsObject).groupId,
            ),
          ),
        ),
        _ => throw const FormatException('unsupported group transport kind'),
      };
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  Future<Result<T>> _notIntegrated<T>() async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) async {
    final admissionService = admission;
    final ids = applicationProtocol;
    if (admissionService == null || ids == null) return _notIntegrated();
    final admittedResult = await admissionService.prepareCreate(intent);
    if (admittedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final admitted = (admittedResult as Success<GroupMlsCreationContext>).value;
    final eventIdResult = await ids.generateEventId();
    if (eventIdResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final eventId = (eventIdResult as Success<Uint8List>).value;
    if (eventId.length != 16) return _integrityFailure();
    final createdResult = await crypto.createBetaMlsGroup(
      BetaMlsCreateRequest(
        authentication: admitted.authentication,
        wrappedKeyPackages: admitted.admissions.map(
          (value) => value.wrappedKeyPackage,
        ),
        authenticatedData: eventId,
      ),
    );
    if (createdResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final created = (createdResult as Success<BetaMlsCommitOutput>).value;
    if (created.epoch != 1 || created.welcomes.isEmpty) {
      return _integrityFailure();
    }
    final domainOperation = CreateGroupOperation(
      metadata: intent.metadata,
      invitationPolicy: intent.invitationPolicy,
      historySharingPolicy: intent.historySharingPolicy,
      initialMembers: admitted.authenticatedMembers,
    );
    final descriptor = BetaMlsControlDescriptor(
      eventId: eventId,
      groupId: created.groupId,
      revision: 1,
      mlsEpoch: created.epoch,
      mlsCommitHash: created.commitDigest,
      createdMs: intent.createdMs,
      operation: BetaMlsCreateControlInput(
        metadata: BetaMlsControlMetadata(
          name: intent.metadata.name,
          description: intent.metadata.description,
          photoCapability: intent.metadata.photoCapability,
        ),
        invitationPolicy: intent.invitationPolicy.index,
        historyPolicy: intent.historySharingPolicy.index,
        members: admitted.authenticatedMembers.map(_controlMember),
      ),
    );
    final signedResult = await crypto.signBetaMlsControl(
      BetaMlsSignControlRequest(
        authentication: admitted.authentication,
        descriptor: descriptor,
      ),
    );
    if (signedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final signed = (signedResult as Success<BetaMlsSignedControlOutput>).value;
    final creatorUser = _uuidBytes(intent.creatorUserId);
    final creatorDevice = _uuidBytes(intent.creatorDeviceId);
    if (!_bytesEqual(signed.signerUserId, creatorUser) ||
        !_bytesEqual(signed.signerDeviceId, creatorDevice)) {
      return _integrityFailure();
    }
    final controlMessageResult = await crypto.sendBetaMlsApplication(
      BetaMlsSendApplicationRequest(
        authentication: admitted.authentication,
        sealedGroupState: created.sealedGroupState,
        applicationData: signed.signedPayload,
        authenticatedData: eventId,
      ),
    );
    if (controlMessageResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final controlMessage =
        (controlMessageResult as Success<BetaMlsMessageOutput>).value;
    if (controlMessage.epoch != created.epoch ||
        !_bytesEqual(controlMessage.groupId, created.groupId) ||
        !_bytesEqual(
          controlMessage.exporterConfirmation,
          created.exporterConfirmation,
        )) {
      return _integrityFailure();
    }
    final event = GroupControlEvent(
      eventId: _hex(eventId),
      groupId: _hex(created.groupId),
      revision: 1,
      previousControlStateHash: null,
      mlsEpoch: created.epoch,
      mlsCommitHash: _hex(created.commitDigest),
      signerUserId: intent.creatorUserId.toLowerCase(),
      signerDeviceId: intent.creatorDeviceId.toLowerCase(),
      createdMs: intent.createdMs,
      operation: domainOperation,
    );
    final signedControl = SignedGroupControlEvent(
      event: event,
      controlStateHash: _hex(signed.controlStateHash),
      canonicalBytes: signed.canonicalBytes,
      signature: signed.signature,
    );
    final transcriptEntry = GroupControlTranscriptEntry(
      signedControl: signedControl,
      signedPayload: signed.signedPayload,
      signerAuthenticationProof:
          admitted.authentication.localVerifiedBundleRequest,
    );
    return Result.success(
      PreparedGroupTransition(
        signedControl: signedControl,
        newOpaqueMlsState: controlMessage.sealedGroupState,
        mlsObject: _encodeCreateTransport(
          event: event,
          commit: created.commit,
          authenticationBundleRequests: created.authenticationBundleRequests,
          welcomes: created.welcomes,
          groupInfo: created.groupInfo,
          controlMessage: controlMessage.message,
          signedPayload: signed.signedPayload,
          signerAuthenticationProof:
              admitted.authentication.localVerifiedBundleRequest,
        ),
        mutationId: 'beta-group-create-${event.eventId}',
        recipientUserIds: admitted.authenticatedMembers.map(
          (member) => member.userId,
        ),
        controlTranscriptEntry: transcriptEntry,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final admissionService = admission;
    if (admissionService == null) return _notIntegrated();
    late final _IncomingWelcomeTransport transport;
    try {
      transport = _parseIncomingWelcomeTransport(mlsObject);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final event = transport.event;
    final joiningMembers = switch (event.operation) {
      CreateGroupOperation(:final initialMembers) => initialMembers,
      InviteGroupMembersOperation(:final members) => members,
      _ => const <GroupMember>[],
    };
    if (joiningMembers.isEmpty || event.mlsCommitHash == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final localMember = joiningMembers
        .where(
          (member) =>
              member.userId.toLowerCase() == localUserId.toLowerCase() &&
              member.isActive &&
              member.deviceIds.contains(localDeviceId.toLowerCase()),
        )
        .toList(growable: false);
    if (localMember.length != 1) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final contextResult = await admissionService.prepareJoin(
      localUserId: localUserId,
      localDeviceId: localDeviceId,
    );
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final context = (contextResult as Success<GroupMlsJoinContext>).value;
    late final BetaMlsAuthenticationInput authentication;
    try {
      authentication = _withAdditionalAuthentication(context.authentication, [
        ...transport.authenticationBundleRequests,
        transport.signerAuthenticationProof,
      ]);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    GroupState? previousState;
    var verifiedPreceding = const <GroupControlTranscriptEntry>[];
    if (event.operation is CreateGroupOperation) {
      if (event.revision != 1 || transport.precedingTranscript.isNotEmpty) {
        return _integrityFailure();
      }
    } else {
      final transcriptResult = await _verifyEncodedControlTranscript(
        transport.precedingTranscript,
        context.authentication,
        localUserId: localUserId,
      );
      if (transcriptResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final verified =
          (transcriptResult
                  as Success<(GroupState, List<GroupControlTranscriptEntry>)>)
              .value;
      previousState = verified.$1;
      verifiedPreceding = verified.$2;
      if (previousState.groupId != event.groupId ||
          previousState.controlRevision + 1 != event.revision ||
          previousState.controlStateHash != event.previousControlStateHash) {
        return _integrityFailure();
      }
    }
    final digestResult = await crypto.hashBetaMlsObject(
      BetaMlsHashObjectRequest(
        authentication: authentication,
        object: transport.commit,
      ),
    );
    if (digestResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if (!_bytesEqual(
      (digestResult as Success<Uint8List>).value,
      _hexBytes(event.mlsCommitHash!),
    )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    BetaMlsJoinOutput? joined;
    for (final welcome in transport.welcomes) {
      final result = await crypto.joinBetaMlsGroup(
        BetaMlsJoinRequest(
          authentication: authentication,
          sealedKeyPackageState: context.sealedKeyPackageState,
          welcome: welcome,
        ),
      );
      if (result case Success<BetaMlsJoinOutput>(:final value)) {
        if (joined != null) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.integrityCheckFailed),
          );
        }
        joined = value;
      }
    }
    if (joined == null ||
        joined.epoch != event.mlsEpoch ||
        !_bytesEqual(joined.groupId, _hexBytes(event.groupId))) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final controlResult = await crypto.processBetaMlsMessage(
      BetaMlsProcessMessageRequest(
        authentication: authentication,
        sealedGroupState: joined.sealedGroupState,
        message: transport.controlMessage,
      ),
    );
    if (controlResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final control = (controlResult as Success<BetaMlsProcessedMessage>).value;
    if (control.kind != BetaMlsReceivedKind.application ||
        !_bytesEqual(control.data, transport.signedPayload) ||
        !_bytesEqual(control.authenticatedData, _hexBytes(event.eventId)) ||
        !_bytesEqual(control.groupId, _hexBytes(event.groupId)) ||
        control.epoch != event.mlsEpoch ||
        !_senderMatches(control, event)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final entryResult = await _verifyControlTranscriptEntry(
      event: event,
      signedPayload: transport.signedPayload,
      signerAuthenticationProof: transport.signerAuthenticationProof,
      authentication: context.authentication,
    );
    if (entryResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final transcriptEntry =
        (entryResult as Success<GroupControlTranscriptEntry>).value;
    final applied = const GroupControlStateMachine().apply(
      previous: previousState,
      signedControl: transcriptEntry.signedControl,
      localUserId: localUserId,
    );
    if (applied is! GroupControlAccepted ||
        !_rosterMatches(applied.state, joined.roster)) {
      return _integrityFailure();
    }
    return Result.success(
      PreparedGroupTransition(
        signedControl: transcriptEntry.signedControl,
        newOpaqueMlsState: control.sealedGroupState,
        mlsObject: mlsObject,
        mutationId: 'beta-group-welcome-${event.eventId}',
        recipientUserIds: const [],
        outbound: false,
        consumedKeyPackageState: ConsumedGroupKeyPackageState(
          deviceId: localDeviceId.toLowerCase(),
          expectedStateRevision: context.keyPackageStateRevision,
          nextSealedState: joined.sealedKeyPackageState,
        ),
        controlTranscriptEntry: transcriptEntry,
        precedingControlTranscript: verifiedPreceding,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) async {
    final admissionService = admission;
    final ids = applicationProtocol;
    if (admissionService == null ||
        ids == null ||
        !_operationAuthorized(current, operation, actorUserId)) {
      return _integrityFailure();
    }
    final contextResult = await admissionService.prepareControl(
      current: current,
      operation: operation,
      actorUserId: actorUserId,
      actorDeviceId: actorDeviceId,
    );
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final context = (contextResult as Success<GroupMlsControlContext>).value;
    var precedingTranscript = const <GroupControlTranscriptEntry>[];
    if (context.operation is InviteGroupMembersOperation) {
      final source = transcript;
      if (source == null) return _notIntegrated();
      final transcriptResult = await source.readVerifiedTranscript(
        current.groupId,
      );
      if (transcriptResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      precedingTranscript =
          (transcriptResult as Success<List<GroupControlTranscriptEntry>>)
              .value;
      final verifiedTranscript = await _verifyControlTranscript(
        precedingTranscript,
        context.authentication,
        localUserId: actorUserId,
      );
      if (verifiedTranscript case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final reconstructed = (verifiedTranscript as Success<GroupState>).value;
      if (!_sameGroupState(reconstructed, current)) return _integrityFailure();
    }
    final eventIdResult = await ids.generateEventId();
    if (eventIdResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final eventId = (eventIdResult as Success<Uint8List>).value;
    if (eventId.length != 16) return _integrityFailure();

    BetaMlsCommitOutput? membershipCommit;
    var candidateState = currentOpaqueMlsState;
    if (context.operation is InviteGroupMembersOperation) {
      final result = await crypto.addBetaMlsMembers(
        BetaMlsAddMembersRequest(
          authentication: context.authentication,
          sealedGroupState: currentOpaqueMlsState,
          wrappedKeyPackages: context.admissions.map(
            (value) => value.wrappedKeyPackage,
          ),
          authenticatedData: eventId,
        ),
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      membershipCommit = (result as Success<BetaMlsCommitOutput>).value;
      candidateState = membershipCommit.sealedGroupState;
    } else if (context.operation case RemoveGroupMemberOperation(
      :final targetUserId,
    )) {
      final result = await crypto.removeBetaMlsMembers(
        BetaMlsRemoveMembersRequest(
          authentication: context.authentication,
          sealedGroupState: currentOpaqueMlsState,
          targetUserIds: [_uuidBytes(targetUserId)],
          authenticatedData: eventId,
        ),
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      membershipCommit = (result as Success<BetaMlsCommitOutput>).value;
      candidateState = membershipCommit.sealedGroupState;
    }
    final expectedEpoch =
        current.acceptedEpoch + (context.operation.changesMembership ? 1 : 0);
    if (membershipCommit != null &&
        (membershipCommit.epoch != expectedEpoch ||
            !_bytesEqual(
              membershipCommit.groupId,
              _hexBytes(current.groupId),
            ))) {
      return _integrityFailure();
    }
    final descriptor = BetaMlsControlDescriptor(
      eventId: eventId,
      groupId: _hexBytes(current.groupId),
      revision: current.controlRevision + 1,
      previousControlStateHash: _hexBytes(current.controlStateHash),
      mlsEpoch: expectedEpoch,
      mlsCommitHash: membershipCommit?.commitDigest,
      createdMs: createdMs,
      operation: _controlOperation(context.operation),
    );
    final signedResult = await crypto.signBetaMlsControl(
      BetaMlsSignControlRequest(
        authentication: context.authentication,
        descriptor: descriptor,
      ),
    );
    if (signedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final signed = (signedResult as Success<BetaMlsSignedControlOutput>).value;
    if (!_bytesEqual(signed.signerUserId, _uuidBytes(actorUserId)) ||
        !_bytesEqual(signed.signerDeviceId, _uuidBytes(actorDeviceId))) {
      return _integrityFailure();
    }
    final controlMessageResult = await crypto.sendBetaMlsApplication(
      BetaMlsSendApplicationRequest(
        authentication: context.authentication,
        sealedGroupState: candidateState,
        applicationData: signed.signedPayload,
        authenticatedData: eventId,
      ),
    );
    if (controlMessageResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final controlMessage =
        (controlMessageResult as Success<BetaMlsMessageOutput>).value;
    if (controlMessage.epoch != expectedEpoch ||
        !_bytesEqual(controlMessage.groupId, _hexBytes(current.groupId)) ||
        (membershipCommit != null &&
            !_bytesEqual(
              controlMessage.exporterConfirmation,
              membershipCommit.exporterConfirmation,
            ))) {
      return _integrityFailure();
    }
    final event = GroupControlEvent(
      eventId: _hex(eventId),
      groupId: current.groupId,
      revision: current.controlRevision + 1,
      previousControlStateHash: current.controlStateHash,
      mlsEpoch: expectedEpoch,
      mlsCommitHash: membershipCommit == null
          ? null
          : _hex(membershipCommit.commitDigest),
      signerUserId: actorUserId.toLowerCase(),
      signerDeviceId: actorDeviceId.toLowerCase(),
      createdMs: createdMs,
      operation: context.operation,
    );
    final signedControl = SignedGroupControlEvent(
      event: event,
      controlStateHash: _hex(signed.controlStateHash),
      canonicalBytes: signed.canonicalBytes,
      signature: signed.signature,
    );
    final transcriptEntry = GroupControlTranscriptEntry(
      signedControl: signedControl,
      signedPayload: signed.signedPayload,
      signerAuthenticationProof:
          context.authentication.localVerifiedBundleRequest,
    );
    final applied = const GroupControlStateMachine().apply(
      previous: current,
      signedControl: signedControl,
      localUserId: actorUserId,
    );
    if (applied is! GroupControlAccepted) return _integrityFailure();
    final recipients = <String>{
      for (final member in current.activeMembers) member.userId.toLowerCase(),
      for (final member in applied.state.activeMembers)
        member.userId.toLowerCase(),
    };
    return Result.success(
      PreparedGroupTransition(
        signedControl: signedControl,
        newOpaqueMlsState: controlMessage.sealedGroupState,
        mlsObject: _encodeControlTransport(
          event: event,
          membershipCommit: membershipCommit,
          controlMessage: controlMessage.message,
          signedPayload: signed.signedPayload,
          signerAuthenticationProof:
              context.authentication.localVerifiedBundleRequest,
          precedingTranscript: precedingTranscript,
        ),
        mutationId: 'beta-group-control-${event.eventId}',
        recipientUserIds: recipients,
        controlTranscriptEntry: transcriptEntry,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final admissionService = admission;
    if (admissionService == null) return _notIntegrated();
    late final _IncomingControlTransport transport;
    try {
      transport = _parseIncomingControlTransport(mlsObject);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final event = transport.event;
    if (event.groupId != current.groupId ||
        event.revision != current.controlRevision + 1 ||
        event.previousControlStateHash != current.controlStateHash ||
        event.operation.changesMembership != (transport.commit != null)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final authenticationResult = await admissionService
        .authenticateCurrentGroup(
          current: current,
          actorUserId: localUserId,
          actorDeviceId: localDeviceId,
        );
    if (authenticationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final baseAuthentication =
        (authenticationResult as Success<BetaMlsAuthenticationInput>).value;
    late final BetaMlsAuthenticationInput authentication;
    try {
      authentication = _withAdditionalAuthentication(baseAuthentication, [
        ...transport.authenticationBundleRequests,
        transport.signerAuthenticationProof,
      ]);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    if (event.operation is InviteGroupMembersOperation) {
      if (transport.precedingTranscript.isEmpty) return _integrityFailure();
      final transcriptResult = await _verifyEncodedControlTranscript(
        transport.precedingTranscript,
        baseAuthentication,
        localUserId: localUserId,
      );
      if (transcriptResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final reconstructed =
          (transcriptResult
                  as Success<(GroupState, List<GroupControlTranscriptEntry>)>)
              .value
              .$1;
      if (!_sameGroupState(reconstructed, current)) return _integrityFailure();
    } else if (transport.precedingTranscript.isNotEmpty) {
      return _integrityFailure();
    }

    var candidateState = currentOpaqueMlsState;
    BetaMlsProcessedMessage? processedCommit;
    if (transport.commit case final commit?) {
      final result = await crypto.processBetaMlsMessage(
        BetaMlsProcessMessageRequest(
          authentication: authentication,
          sealedGroupState: candidateState,
          message: commit,
        ),
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      processedCommit = (result as Success<BetaMlsProcessedMessage>).value;
      if (processedCommit.kind != BetaMlsReceivedKind.commit ||
          event.mlsCommitHash == null ||
          !_bytesEqual(
            processedCommit.messageDigest,
            _hexBytes(event.mlsCommitHash!),
          ) ||
          !_bytesEqual(
            processedCommit.authenticatedData,
            _hexBytes(event.eventId),
          ) ||
          !_bytesEqual(processedCommit.groupId, _hexBytes(current.groupId)) ||
          !_senderMatches(processedCommit, event)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      candidateState = processedCommit.sealedGroupState;
    }

    // Only a Commit that evicts this device leaves us unable to read the
    // control message that follows it. A leave carries no Commit, so the
    // departing member is still cryptographically present at this epoch and
    // must process its own announcement like everyone else.
    final removedLocally = switch (event.operation) {
      RemoveGroupMemberOperation(:final targetUserId) =>
        targetUserId.toLowerCase() == localUserId.toLowerCase(),
      _ => false,
    };
    if (!removedLocally) {
      final result = await crypto.processBetaMlsMessage(
        BetaMlsProcessMessageRequest(
          authentication: authentication,
          sealedGroupState: candidateState,
          message: transport.controlMessage,
        ),
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final control = (result as Success<BetaMlsProcessedMessage>).value;
      if (control.kind != BetaMlsReceivedKind.application ||
          !_bytesEqual(control.data, transport.signedPayload) ||
          !_bytesEqual(control.authenticatedData, _hexBytes(event.eventId)) ||
          !_bytesEqual(control.groupId, _hexBytes(current.groupId)) ||
          control.epoch != event.mlsEpoch ||
          !_senderMatches(control, event)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      candidateState = control.sealedGroupState;
    } else if (processedCommit == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    final entryResult = await _verifyControlTranscriptEntry(
      event: event,
      signedPayload: transport.signedPayload,
      signerAuthenticationProof: transport.signerAuthenticationProof,
      authentication: baseAuthentication,
    );
    if (entryResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final transcriptEntry =
        (entryResult as Success<GroupControlTranscriptEntry>).value;
    return Result.success(
      PreparedGroupTransition(
        signedControl: transcriptEntry.signedControl,
        newOpaqueMlsState: candidateState,
        mlsObject: mlsObject,
        mutationId: 'beta-group-inbound-${event.eventId}',
        recipientUserIds: const [],
        outbound: false,
        controlTranscriptEntry: transcriptEntry,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) async {
    final admissionService = admission;
    final protocol = applicationProtocol;
    final identities = applicationIdentity;
    final sender = current.member(senderUserId);
    if (admissionService == null ||
        protocol == null ||
        identities == null ||
        sender == null ||
        !sender.isActive ||
        !sender.deviceIds.contains(senderDeviceId.toLowerCase()) ||
        !GroupAuthorization.allows(
          current,
          senderUserId,
          GroupPermission.sendMessages,
        )) {
      return _integrityFailure();
    }
    final authenticationResult = await admissionService
        .authenticateCurrentGroup(
          current: current,
          actorUserId: senderUserId,
          actorDeviceId: senderDeviceId,
        );
    if (authenticationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final authentication =
        (authenticationResult as Success<BetaMlsAuthenticationInput>).value;
    final eventIdResult = await protocol.generateEventId();
    if (eventIdResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final eventId = (eventIdResult as Success<Uint8List>).value;
    final counterResult = await identities.reserveSenderCounter(
      senderDeviceId.toLowerCase(),
    );
    if (counterResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final senderCounter = (counterResult as Success<int>).value;
    final encodedResult = await protocol.encode(
      ApplicationEventRecord(
        version: ApplicationMessageProtocolV1.version,
        eventId: eventId,
        conversationId: _hexBytes(current.groupId),
        kindValue: ApplicationEventKind.messageCreate.wireValue,
        senderUserId: _uuidBytes(senderUserId),
        senderDeviceId: _uuidBytes(senderDeviceId),
        senderCounter: senderCounter,
        createdMs: createdMs,
        references: const [],
        body: MessageCreateBody(messageId: eventId, text: text),
      ),
    );
    if (encodedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final canonicalEvent = (encodedResult as Success<Uint8List>).value;
    final encryptedResult = await crypto.sendBetaMlsApplication(
      BetaMlsSendApplicationRequest(
        authentication: authentication,
        sealedGroupState: currentOpaqueMlsState,
        applicationData: canonicalEvent,
        authenticatedData: eventId,
      ),
    );
    if (encryptedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final encrypted = (encryptedResult as Success<BetaMlsMessageOutput>).value;
    if (encrypted.epoch != current.acceptedEpoch ||
        !_bytesEqual(encrypted.groupId, _hexBytes(current.groupId))) {
      return _integrityFailure();
    }
    final messageId = _hex(eventId);
    return Result.success(
      PreparedGroupMessage(
        groupId: current.groupId,
        messageId: messageId,
        senderUserId: senderUserId.toLowerCase(),
        senderDeviceId: senderDeviceId.toLowerCase(),
        text: text,
        createdMs: createdMs,
        epoch: current.acceptedEpoch,
        newOpaqueMlsState: encrypted.sealedGroupState,
        mlsObject: _encodeApplicationTransport(
          groupId: encrypted.groupId,
          message: encrypted.message,
        ),
        operationId: 'beta-group-message-$messageId',
        recipientUserIds: current.activeMembers.map((member) => member.userId),
      ),
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final admissionService = admission;
    final protocol = applicationProtocol;
    if (admissionService == null || protocol == null) return _notIntegrated();

    late final _IncomingApplicationTransport transport;
    try {
      transport = _parseIncomingApplicationTransport(mlsObject);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }

    final authenticationResult = await admissionService
        .authenticateCurrentGroup(
          current: current,
          actorUserId: localUserId,
          actorDeviceId: localDeviceId,
        );
    if (authenticationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final processedResult = await crypto.processBetaMlsMessage(
      BetaMlsProcessMessageRequest(
        authentication:
            (authenticationResult as Success<BetaMlsAuthenticationInput>).value,
        sealedGroupState: currentOpaqueMlsState,
        message: transport.message,
      ),
    );
    if (processedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final processed =
        (processedResult as Success<BetaMlsProcessedMessage>).value;
    if (processed.kind != BetaMlsReceivedKind.application ||
        processed.epoch != current.acceptedEpoch ||
        !_bytesEqual(transport.groupId, _hexBytes(current.groupId)) ||
        !_bytesEqual(processed.groupId, _hexBytes(current.groupId)) ||
        processed.senderUserId.length !=
            ApplicationMessageProtocolV1.uuidBytes ||
        processed.senderDeviceId.length !=
            ApplicationMessageProtocolV1.uuidBytes) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    late final String senderUserId;
    late final String senderDeviceId;
    try {
      senderUserId = protocolUuidString(processed.senderUserId);
      senderDeviceId = protocolUuidString(processed.senderDeviceId);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final sender = current.member(senderUserId);
    if (sender == null ||
        !sender.isActive ||
        !sender.deviceIds.contains(senderDeviceId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    final decodedResult = await protocol.decode(processed.data);
    if (decodedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final decoded = (decodedResult as Success<DecodedApplicationEvent>).value;
    if (decoded is! SupportedApplicationEvent ||
        !_bytesEqual(decoded.canonicalBytes, processed.data)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final event = decoded.event;
    if (event.version != ApplicationMessageProtocolV1.version ||
        event.kind != ApplicationEventKind.messageCreate ||
        event.body is! MessageCreateBody ||
        !_bytesEqual(event.eventId, processed.authenticatedData) ||
        !_bytesEqual(event.conversationId, _hexBytes(current.groupId)) ||
        !_bytesEqual(event.senderUserId, processed.senderUserId) ||
        !_bytesEqual(event.senderDeviceId, processed.senderDeviceId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final body = event.body as MessageCreateBody;
    if (!_bytesEqual(body.messageId, event.eventId) ||
        body.contentType != MessageContentType.text ||
        body.attachments.isNotEmpty ||
        body.text.trim().isEmpty) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }

    final messageId = _hex(event.eventId);
    return Result.success(
      PreparedGroupMessage(
        groupId: current.groupId,
        messageId: messageId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        text: body.text,
        createdMs: event.createdMs,
        epoch: current.acceptedEpoch,
        newOpaqueMlsState: processed.sealedGroupState,
        mlsObject: mlsObject,
        operationId: 'beta-group-inbound-message-$messageId',
        recipientUserIds: const [],
        outbound: false,
      ),
    );
  }

  Future<Result<GroupControlTranscriptEntry>> _verifyControlTranscriptEntry({
    required GroupControlEvent event,
    required Uint8List signedPayload,
    required Uint8List signerAuthenticationProof,
    required BetaMlsAuthenticationInput authentication,
  }) async {
    late final BetaMlsAuthenticationInput verifierAuthentication;
    try {
      verifierAuthentication = _withAdditionalAuthentication(authentication, [
        signerAuthenticationProof,
      ]);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final verifiedResult = await crypto.verifyBetaMlsControl(
      BetaMlsVerifyControlRequest(
        authentication: verifierAuthentication,
        descriptor: _controlDescriptor(event),
        signerUserId: _uuidBytes(event.signerUserId),
        signerDeviceId: _uuidBytes(event.signerDeviceId),
        signedPayload: signedPayload,
      ),
    );
    if (verifiedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final verified =
        (verifiedResult as Success<BetaMlsSignedControlOutput>).value;
    if (!_bytesEqual(verified.signedPayload, signedPayload) ||
        !_bytesEqual(verified.signerUserId, _uuidBytes(event.signerUserId)) ||
        !_bytesEqual(
          verified.signerDeviceId,
          _uuidBytes(event.signerDeviceId),
        )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    try {
      return Result.success(
        GroupControlTranscriptEntry(
          signedControl: SignedGroupControlEvent(
            event: event,
            controlStateHash: _hex(verified.controlStateHash),
            canonicalBytes: verified.canonicalBytes,
            signature: verified.signature,
          ),
          signedPayload: signedPayload,
          signerAuthenticationProof: signerAuthenticationProof,
        ),
      );
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
  }

  Future<Result<(GroupState, List<GroupControlTranscriptEntry>)>>
  _verifyEncodedControlTranscript(
    List<_EncodedControlTranscriptEntry> encoded,
    BetaMlsAuthenticationInput authentication, {
    required String localUserId,
  }) async {
    if (encoded.isEmpty || encoded.length > 512) return _integrityFailure();
    GroupState? state;
    final verified = <GroupControlTranscriptEntry>[];
    for (final entry in encoded) {
      final result = await _verifyControlTranscriptEntry(
        event: entry.event,
        signedPayload: entry.signedPayload,
        signerAuthenticationProof: entry.signerAuthenticationProof,
        authentication: authentication,
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final value = (result as Success<GroupControlTranscriptEntry>).value;
      final applied = const GroupControlStateMachine().apply(
        previous: state,
        signedControl: value.signedControl,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) return _integrityFailure();
      state = applied.state;
      verified.add(value);
    }
    return Result.success((state!, List.unmodifiable(verified)));
  }

  Future<Result<GroupState>> _verifyControlTranscript(
    List<GroupControlTranscriptEntry> transcript,
    BetaMlsAuthenticationInput authentication, {
    required String localUserId,
  }) async {
    if (transcript.isEmpty || transcript.length > 512) {
      return _integrityFailure();
    }
    GroupState? state;
    for (final stored in transcript) {
      final result = await _verifyControlTranscriptEntry(
        event: stored.signedControl.event,
        signedPayload: stored.signedPayload,
        signerAuthenticationProof: stored.signerAuthenticationProof,
        authentication: authentication,
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final verified = (result as Success<GroupControlTranscriptEntry>).value;
      if (!_sameTranscriptEntry(verified, stored)) return _integrityFailure();
      final applied = const GroupControlStateMachine().apply(
        previous: state,
        signedControl: verified.signedControl,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) return _integrityFailure();
      state = applied.state;
    }
    return Result.success(state!);
  }

  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final admissionService = admission;
    final source = transcript;
    if (admissionService == null || source == null) return _notIntegrated();
    if (siblingCommits.isEmpty || siblingCommits.length > maximumSiblings) {
      return _integrityFailure();
    }

    // Reconstruct the shared parent so a sibling is judged by the same rules
    // the local branch already passed, not by its own claims.
    final storedResult = await source.readVerifiedTranscript(current.groupId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored =
        (storedResult as Success<List<GroupControlTranscriptEntry>>).value;
    if (stored.length != current.controlRevision) return _integrityFailure();
    final authenticationResult = await admissionService
        .authenticateCurrentGroup(
          current: current,
          actorUserId: localUserId,
          actorDeviceId: localDeviceId,
        );
    if (authenticationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final authentication =
        (authenticationResult as Success<BetaMlsAuthenticationInput>).value;

    GroupState? parent;
    for (final entry in stored.take(stored.length - 1)) {
      final applied = const GroupControlStateMachine().apply(
        previous: parent,
        signedControl: entry.signedControl,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) return _integrityFailure();
      parent = applied.state;
    }
    final localBranch = stored.last.signedControl.event;
    if (localBranch.revision != current.controlRevision ||
        stored.last.signedControl.controlStateHash !=
            current.controlStateHash) {
      return _integrityFailure();
    }
    // Both keys are read from the reconstructed shared parent, so authority is
    // the roster's, never the branch's own claim about its signer.
    final local = GroupForkCanonicalOrder.branchOf(
      parent: parent,
      signedControl: stored.last.signedControl,
    );
    if (local == null) return _integrityFailure();

    final rivals = <String, GroupForkBranch>{};
    for (final sibling in siblingCommits) {
      late final _IncomingControlTransport transport;
      try {
        transport = _parseIncomingControlTransport(sibling);
      } on Object {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      final event = transport.event;
      if (event.groupId != current.groupId ||
          event.revision != current.controlRevision ||
          event.previousControlStateHash != parent?.controlStateHash) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      final entryResult = await _verifyControlTranscriptEntry(
        event: event,
        signedPayload: transport.signedPayload,
        signerAuthenticationProof: transport.signerAuthenticationProof,
        authentication: authentication,
      );
      if (entryResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final verified =
          (entryResult as Success<GroupControlTranscriptEntry>).value;
      // A sibling only counts once it is authorized against the shared parent.
      final applied = const GroupControlStateMachine().apply(
        previous: parent,
        signedControl: verified.signedControl,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      final hash = verified.signedControl.controlStateHash.toLowerCase();
      if (hash == current.controlStateHash.toLowerCase()) {
        // Same branch replayed, not a fork.
        return _integrityFailure();
      }
      final rival = GroupForkCanonicalOrder.branchOf(
        parent: parent,
        signedControl: verified.signedControl,
      );
      if (rival == null) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      rivals[hash] = rival;
    }
    if (rivals.isEmpty) return _integrityFailure();

    if (GroupForkCanonicalOrder.outranks(local, rivals.values)) {
      return Result.success(
        GroupForkLocalBranchCanonical(
          supersededEventIds: rivals.values.map((rival) => rival.eventId),
        ),
      );
    }
    final canonical = GroupForkCanonicalOrder.canonical(rivals.values);
    return Result.success(
      GroupForkLocalBranchSuperseded(
        canonicalEventId: canonical.eventId,
        canonicalControlStateHash: canonical.controlStateHash,
        canonicalSignerUserId: canonical.signerUserId,
      ),
    );
  }

  static const maximumSiblings = 16;

  Result<T> _integrityFailure<T>() => const Result.failure(
    SecurityFailure(SecurityFailureKind.integrityCheckFailed),
  );
}

BetaMlsControlMember _controlMember(GroupMember member) => BetaMlsControlMember(
  userId: _uuidBytes(member.userId),
  displayName: member.displayName,
  role: member.role.index,
  membership: member.membership.index,
  verified: member.verified,
  deviceIds: member.deviceIds.map(_uuidBytes),
);

Uint8List _encodeCreateTransport({
  required GroupControlEvent event,
  required Uint8List commit,
  required List<Uint8List> authenticationBundleRequests,
  required List<Uint8List> welcomes,
  required Uint8List groupInfo,
  required Uint8List controlMessage,
  required Uint8List signedPayload,
  required Uint8List signerAuthenticationProof,
}) {
  final writer = _Writer()
    ..bytes(ascii.encode('CPGTO001'))
    ..u16(3)
    ..u8(1)
    ..frame(Uint8List.fromList(utf8.encode(event.deterministicProjection)))
    ..frame(commit)
    ..u16(authenticationBundleRequests.length);
  for (final request in authenticationBundleRequests) {
    writer.frame(request);
  }
  writer.u16(welcomes.length);
  for (final welcome in welcomes) {
    writer.frame(welcome);
  }
  writer
    ..frame(groupInfo)
    ..frame(controlMessage)
    ..frame(signedPayload)
    ..frame(signerAuthenticationProof);
  return writer.takeBytes();
}

Uint8List _encodeControlTransport({
  required GroupControlEvent event,
  required BetaMlsCommitOutput? membershipCommit,
  required Uint8List controlMessage,
  required Uint8List signedPayload,
  required Uint8List signerAuthenticationProof,
  required List<GroupControlTranscriptEntry> precedingTranscript,
}) {
  final writer = _Writer()
    ..bytes(ascii.encode('CPGTO001'))
    ..u16(3)
    ..u8(2)
    ..frame(Uint8List.fromList(utf8.encode(event.deterministicProjection)))
    ..u8(membershipCommit == null ? 0 : 1);
  if (membershipCommit != null) {
    writer
      ..frame(membershipCommit.commit)
      ..u16(membershipCommit.authenticationBundleRequests.length);
    for (final request in membershipCommit.authenticationBundleRequests) {
      writer.frame(request);
    }
    writer.u16(membershipCommit.welcomes.length);
    for (final welcome in membershipCommit.welcomes) {
      writer.frame(welcome);
    }
    writer.frame(membershipCommit.groupInfo);
  }
  writer.u16(precedingTranscript.length);
  for (final entry in precedingTranscript) {
    writer
      ..frame(
        Uint8List.fromList(
          utf8.encode(entry.signedControl.event.deterministicProjection),
        ),
      )
      ..frame(entry.signedPayload)
      ..frame(entry.signerAuthenticationProof);
  }
  writer
    ..frame(controlMessage)
    ..frame(signedPayload)
    ..frame(signerAuthenticationProof);
  return writer.takeBytes();
}

Uint8List _encodeApplicationTransport({
  required Uint8List groupId,
  required Uint8List message,
}) =>
    (_Writer()
          ..bytes(ascii.encode('CPGTO001'))
          ..u16(3)
          ..u8(3)
          ..frame(groupId)
          ..frame(message))
        .takeBytes();

_IncomingApplicationTransport _parseIncomingApplicationTransport(
  Uint8List value,
) {
  final reader = _TransportReader(value)..expect(ascii.encode('CPGTO001'));
  if (reader.u16() != 3 || reader.u8() != 3) {
    throw const FormatException('unsupported application transport');
  }
  final groupId = reader.frame();
  if (groupId.length != 32) {
    throw const FormatException('invalid application group id');
  }
  final message = reader.frame();
  if (!reader.finished) {
    throw const FormatException('trailing application transport data');
  }
  return _IncomingApplicationTransport(groupId: groupId, message: message);
}

BetaMlsControlOperationInput _controlOperation(
  GroupControlOperation operation,
) => switch (operation) {
  CreateGroupOperation(
    :final metadata,
    :final invitationPolicy,
    :final historySharingPolicy,
    :final initialMembers,
  ) =>
    BetaMlsCreateControlInput(
      metadata: _controlMetadata(metadata),
      invitationPolicy: invitationPolicy.index,
      historyPolicy: historySharingPolicy.index,
      members: initialMembers.map(_controlMember),
    ),
  UpdateGroupMetadataOperation(:final metadata) =>
    BetaMlsUpdateMetadataControlInput(_controlMetadata(metadata)),
  UpdateGroupPoliciesOperation(
    :final invitationPolicy,
    :final historySharingPolicy,
  ) =>
    BetaMlsUpdatePoliciesControlInput(
      invitationPolicy: invitationPolicy.index,
      historyPolicy: historySharingPolicy.index,
    ),
  InviteGroupMembersOperation(:final members) => BetaMlsInviteControlInput(
    members.map(_controlMember),
  ),
  RemoveGroupMemberOperation(:final targetUserId) => BetaMlsRemoveControlInput(
    _uuidBytes(targetUserId),
  ),
  LeaveGroupOperation() => const BetaMlsLeaveControlInput(),
  ChangeGroupRoleOperation(:final targetUserId, :final role) =>
    BetaMlsChangeRoleControlInput(
      targetUserId: _uuidBytes(targetUserId),
      role: role.index,
    ),
  TransferGroupOwnershipOperation(:final targetUserId) =>
    BetaMlsTransferOwnershipControlInput(_uuidBytes(targetUserId)),
};

BetaMlsControlMetadata _controlMetadata(GroupMetadata value) =>
    BetaMlsControlMetadata(
      name: value.name,
      description: value.description,
      photoCapability: value.photoCapability,
    );

BetaMlsControlDescriptor _controlDescriptor(GroupControlEvent event) =>
    BetaMlsControlDescriptor(
      eventId: _hexBytes(event.eventId),
      groupId: _hexBytes(event.groupId),
      revision: event.revision,
      previousControlStateHash: event.previousControlStateHash == null
          ? null
          : _hexBytes(event.previousControlStateHash!),
      mlsEpoch: event.mlsEpoch,
      mlsCommitHash: event.mlsCommitHash == null
          ? null
          : _hexBytes(event.mlsCommitHash!),
      createdMs: event.createdMs,
      operation: _controlOperation(event.operation),
    );

bool _senderMatches(BetaMlsProcessedMessage message, GroupControlEvent event) =>
    _bytesEqual(message.senderUserId, _uuidBytes(event.signerUserId)) &&
    _bytesEqual(message.senderDeviceId, _uuidBytes(event.signerDeviceId));

BetaMlsAuthenticationInput _withAdditionalAuthentication(
  BetaMlsAuthenticationInput base,
  Iterable<Uint8List> additional,
) {
  final merged = <Uint8List>[...base.additionalVerifiedBundleRequests];
  for (final request in additional) {
    if (!merged.any((value) => _bytesEqual(value, request)) &&
        !_bytesEqual(base.localVerifiedBundleRequest, request)) {
      merged.add(request);
    }
  }
  return BetaMlsAuthenticationInput(
    opaqueDeviceState: base.opaqueDeviceState,
    migrationUnixDay: base.migrationUnixDay,
    localVerifiedBundleRequest: base.localVerifiedBundleRequest,
    additionalVerifiedBundleRequests: merged,
  );
}

_IncomingControlTransport _parseIncomingControlTransport(Uint8List value) {
  final reader = _TransportReader(value)..expect(ascii.encode('CPGTO001'));
  if (reader.u16() != 3 || reader.u8() != 2) {
    throw const FormatException('unsupported group transport');
  }
  final projection = jsonDecode(utf8.decode(reader.frame()));
  final event = _groupControlEvent(projection);
  final hasCommit = reader.u8();
  if (hasCommit != 0 && hasCommit != 1) {
    throw const FormatException('invalid membership flag');
  }
  Uint8List? commit;
  final authentication = <Uint8List>[];
  final welcomes = <Uint8List>[];
  Uint8List? groupInfo;
  if (hasCommit == 1) {
    commit = reader.frame();
    final proofCount = reader.u16();
    if (proofCount == 0 || proofCount > 50) {
      throw const FormatException('invalid proof count');
    }
    for (var index = 0; index < proofCount; index += 1) {
      final proof = reader.frame();
      if (proof.length < 8 ||
          proof.length > 16 * 1024 ||
          !_startsWith(proof, ascii.encode('CPBRV001'))) {
        throw const FormatException('invalid authentication proof');
      }
      authentication.add(proof);
    }
    final welcomeCount = reader.u16();
    if (welcomeCount >= 50) {
      throw const FormatException('invalid Welcome count');
    }
    for (var index = 0; index < welcomeCount; index += 1) {
      welcomes.add(reader.frame());
    }
    groupInfo = reader.frame();
  }
  final transcriptCount = reader.u16();
  if (transcriptCount > 512 || (commit == null && transcriptCount != 0)) {
    throw const FormatException('invalid control transcript count');
  }
  final precedingTranscript = <_EncodedControlTranscriptEntry>[
    for (var index = 0; index < transcriptCount; index += 1)
      _readEncodedTranscriptEntry(reader),
  ];
  final controlMessage = reader.frame();
  final signedPayload = reader.frame();
  final signerAuthenticationProof = _readAuthenticationProof(reader);
  if (!reader.finished ||
      event.operation.changesMembership != (commit != null) ||
      (precedingTranscript.isNotEmpty && welcomes.isEmpty) ||
      signedPayload.isEmpty) {
    throw const FormatException('invalid control transport');
  }
  return _IncomingControlTransport(
    event: event,
    commit: commit,
    authenticationBundleRequests: authentication,
    welcomes: welcomes,
    groupInfo: groupInfo,
    precedingTranscript: precedingTranscript,
    controlMessage: controlMessage,
    signedPayload: signedPayload,
    signerAuthenticationProof: signerAuthenticationProof,
  );
}

_IncomingWelcomeTransport _parseIncomingWelcomeTransport(Uint8List value) {
  final reader = _TransportReader(value)..expect(ascii.encode('CPGTO001'));
  if (reader.u16() != 3) {
    throw const FormatException('unsupported Welcome transport');
  }
  final kind = reader.u8();
  if (kind == 2) {
    final control = _parseIncomingControlTransport(value);
    if (control.commit == null ||
        control.groupInfo == null ||
        control.welcomes.isEmpty) {
      throw const FormatException('control is not join capable');
    }
    return _IncomingWelcomeTransport(
      event: control.event,
      commit: control.commit!,
      authenticationBundleRequests: control.authenticationBundleRequests,
      welcomes: control.welcomes,
      groupInfo: control.groupInfo!,
      precedingTranscript: control.precedingTranscript,
      controlMessage: control.controlMessage,
      signedPayload: control.signedPayload,
      signerAuthenticationProof: control.signerAuthenticationProof,
    );
  }
  if (kind != 1) throw const FormatException('unsupported Welcome kind');
  final event = _groupControlEvent(jsonDecode(utf8.decode(reader.frame())));
  final commit = reader.frame();
  final proofCount = reader.u16();
  if (proofCount == 0 || proofCount > 50) {
    throw const FormatException('invalid proof count');
  }
  final authentication = <Uint8List>[];
  for (var index = 0; index < proofCount; index += 1) {
    final proof = reader.frame();
    if (proof.length < 8 ||
        proof.length > 16 * 1024 ||
        !_startsWith(proof, ascii.encode('CPBRV001'))) {
      throw const FormatException('invalid authentication proof');
    }
    authentication.add(proof);
  }
  final welcomeCount = reader.u16();
  if (welcomeCount == 0 || welcomeCount >= 50) {
    throw const FormatException('invalid Welcome count');
  }
  final welcomes = <Uint8List>[
    for (var index = 0; index < welcomeCount; index += 1) reader.frame(),
  ];
  final groupInfo = reader.frame();
  final controlMessage = reader.frame();
  final signedPayload = reader.frame();
  final signerAuthenticationProof = _readAuthenticationProof(reader);
  if (!reader.finished || signedPayload.isEmpty) {
    throw const FormatException('invalid Welcome transport');
  }
  return _IncomingWelcomeTransport(
    event: event,
    commit: commit,
    authenticationBundleRequests: authentication,
    welcomes: welcomes,
    groupInfo: groupInfo,
    precedingTranscript: const [],
    controlMessage: controlMessage,
    signedPayload: signedPayload,
    signerAuthenticationProof: signerAuthenticationProof,
  );
}

GroupControlEvent _groupControlEvent(Object? projection) {
  final fields = _list(projection, 11);
  return GroupControlEvent(
    protocolVersion: _integer(fields[0]),
    eventId: _string(fields[1]),
    groupId: _string(fields[2]),
    revision: _integer(fields[3]),
    previousControlStateHash: _optionalString(fields[4]),
    mlsEpoch: _integer(fields[5]),
    mlsCommitHash: _optionalString(fields[6]),
    signerUserId: _string(fields[7]),
    signerDeviceId: _string(fields[8]),
    createdMs: _integer(fields[9]),
    operation: _groupControlOperation(fields[10]),
  );
}

GroupControlOperation _groupControlOperation(Object? value) {
  final fields = _list(value);
  if (fields.isEmpty) throw const FormatException('missing operation');
  return switch (_integer(fields[0])) {
    1 => CreateGroupOperation(
      metadata: _groupMetadata(fields, 1),
      invitationPolicy: _enumValue(GroupInvitationPolicy.values, fields[4]),
      historySharingPolicy: _enumValue(
        GroupHistorySharingPolicy.values,
        fields[5],
      ),
      initialMembers: _members(fields[6]),
    ),
    2 => UpdateGroupMetadataOperation(_groupMetadata(fields, 1)),
    3 => UpdateGroupPoliciesOperation(
      invitationPolicy: _enumValue(GroupInvitationPolicy.values, fields[1]),
      historySharingPolicy: _enumValue(
        GroupHistorySharingPolicy.values,
        fields[2],
      ),
    ),
    4 => InviteGroupMembersOperation(_members(fields[1])),
    5 => RemoveGroupMemberOperation(_string(fields[1])),
    6 => const LeaveGroupOperation(),
    7 => ChangeGroupRoleOperation(
      targetUserId: _string(fields[1]),
      role: _enumValue(GroupRole.values, fields[2]),
    ),
    8 => TransferGroupOwnershipOperation(_string(fields[1])),
    _ => throw const FormatException('unsupported group operation'),
  };
}

GroupMetadata _groupMetadata(List<Object?> fields, int offset) => GroupMetadata(
  name: _string(fields[offset]),
  description: _string(fields[offset + 1]),
  photoCapability: _optionalString(fields[offset + 2]),
);

List<GroupMember> _members(Object? value) => [
  for (final raw in _list(value)) _groupMember(raw),
];

GroupMember _groupMember(Object? value) {
  final fields = _list(value, 6);
  return GroupMember(
    userId: _string(fields[0]),
    displayName: _string(fields[1]),
    role: _enumValue(GroupRole.values, fields[2]),
    membership: _enumValue(GroupMembershipState.values, fields[3]),
    verified: fields[4] is bool
        ? fields[4]! as bool
        : throw const FormatException('invalid verified flag'),
    deviceIds: [for (final value in _list(fields[5])) _string(value)],
  );
}

List<Object?> _list(Object? value, [int? exactLength]) {
  if (value is! List<Object?> ||
      (exactLength != null && value.length != exactLength)) {
    throw const FormatException('invalid list');
  }
  return value;
}

int _integer(Object? value) {
  if (value is! int) throw const FormatException('invalid integer');
  return value;
}

String _string(Object? value) {
  if (value is! String) throw const FormatException('invalid string');
  return value;
}

String? _optionalString(Object? value) => value == null ? null : _string(value);

T _enumValue<T>(List<T> values, Object? value) {
  final index = _integer(value);
  if (index < 0 || index >= values.length) {
    throw const FormatException('invalid enum');
  }
  return values[index];
}

bool _operationAuthorized(
  GroupState current,
  GroupControlOperation operation,
  String actorUserId,
) {
  if (current.lifecycle != GroupLifecycle.active) return false;
  return switch (operation) {
    CreateGroupOperation() => false,
    RemoveGroupMemberOperation(:final targetUserId) =>
      GroupAuthorization.canRemove(
        current,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
      ),
    LeaveGroupOperation() => GroupAuthorization.canLeave(current, actorUserId),
    ChangeGroupRoleOperation(:final targetUserId, :final role) =>
      GroupAuthorization.canChangeRole(
        current,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
        role: role,
      ),
    _ =>
      operation.requiredPermission != null &&
          GroupAuthorization.allows(
            current,
            actorUserId,
            operation.requiredPermission!,
          ),
  };
}

Uint8List _uuidBytes(String value) {
  final hex = value.replaceAll('-', '').toLowerCase();
  if (hex.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(hex)) {
    throw const FormatException('invalid UUID');
  }
  return Uint8List.fromList([
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
}

String _hex(Uint8List value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String value) {
  if (value.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
    throw const FormatException('invalid hexadecimal value');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _sameTranscriptEntry(
  GroupControlTranscriptEntry left,
  GroupControlTranscriptEntry right,
) =>
    left.signedControl.event.deterministicProjection ==
        right.signedControl.event.deterministicProjection &&
    left.signedControl.controlStateHash ==
        right.signedControl.controlStateHash &&
    _bytesEqual(
      left.signedControl.canonicalBytes,
      right.signedControl.canonicalBytes,
    ) &&
    _bytesEqual(left.signedControl.signature, right.signedControl.signature) &&
    _bytesEqual(left.signedPayload, right.signedPayload) &&
    _bytesEqual(
      left.signerAuthenticationProof,
      right.signerAuthenticationProof,
    );

bool _sameGroupState(GroupState left, GroupState right) =>
    left.groupId == right.groupId &&
    left.metadata.name == right.metadata.name &&
    left.metadata.description == right.metadata.description &&
    left.metadata.photoCapability == right.metadata.photoCapability &&
    left.invitationPolicy == right.invitationPolicy &&
    left.historySharingPolicy == right.historySharingPolicy &&
    left.controlRevision == right.controlRevision &&
    left.controlStateHash == right.controlStateHash &&
    left.acceptedEpoch == right.acceptedEpoch &&
    left.lifecycle == right.lifecycle &&
    left.quarantineReason == right.quarantineReason &&
    jsonEncode([for (final member in left.members) member.canonicalFields]) ==
        jsonEncode([
          for (final member in right.members) member.canonicalFields,
        ]);

bool _rosterMatches(GroupState state, List<BetaMlsRosterDevice> roster) {
  final expected = <String>{
    for (final member in state.activeMembers)
      for (final deviceId in member.deviceIds)
        '${_hex(_uuidBytes(member.userId))}:${_hex(_uuidBytes(deviceId))}',
  };
  final actual = <String>{
    for (final member in roster)
      '${_hex(member.userId)}:${_hex(member.deviceId)}',
  };
  return expected.length == roster.length &&
      actual.length == roster.length &&
      expected.length == actual.length &&
      expected.containsAll(actual);
}

bool _startsWith(Uint8List value, List<int> prefix) {
  if (value.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index += 1) {
    if (value[index] != prefix[index]) return false;
  }
  return true;
}

Uint8List _readAuthenticationProof(_TransportReader reader) {
  final proof = reader.frame();
  if (proof.length < 8 ||
      proof.length > 16 * 1024 ||
      !_startsWith(proof, ascii.encode('CPBRV001'))) {
    throw const FormatException('invalid authentication proof');
  }
  return proof;
}

_EncodedControlTranscriptEntry _readEncodedTranscriptEntry(
  _TransportReader reader,
) {
  final event = GroupControlEvent.fromDeterministicProjection(
    utf8.decode(reader.frame(), allowMalformed: false),
  );
  final signedPayload = reader.frame();
  if (signedPayload.length < 8 || signedPayload.length > 64 * 1024) {
    throw const FormatException('invalid signed control payload');
  }
  return _EncodedControlTranscriptEntry(
    event: event,
    signedPayload: signedPayload,
    signerAuthenticationProof: _readAuthenticationProof(reader),
  );
}

GroupMlsTransportProbe _controlProbe(_IncomingControlTransport transport) =>
    GroupMlsTransportProbe(
      kind: GroupMlsTransportKind.control,
      groupId: transport.event.groupId,
      joinCapable: transport.commit != null && transport.welcomes.isNotEmpty,
    );

final class _IncomingControlTransport {
  const _IncomingControlTransport({
    required this.event,
    required this.commit,
    required this.authenticationBundleRequests,
    required this.welcomes,
    required this.groupInfo,
    required this.precedingTranscript,
    required this.controlMessage,
    required this.signedPayload,
    required this.signerAuthenticationProof,
  });

  final GroupControlEvent event;
  final Uint8List? commit;
  final List<Uint8List> authenticationBundleRequests;
  final List<Uint8List> welcomes;
  final Uint8List? groupInfo;
  final List<_EncodedControlTranscriptEntry> precedingTranscript;
  final Uint8List controlMessage;
  final Uint8List signedPayload;
  final Uint8List signerAuthenticationProof;
}

final class _IncomingApplicationTransport {
  const _IncomingApplicationTransport({
    required this.groupId,
    required this.message,
  });

  final Uint8List groupId;
  final Uint8List message;
}

final class _IncomingWelcomeTransport {
  const _IncomingWelcomeTransport({
    required this.event,
    required this.commit,
    required this.authenticationBundleRequests,
    required this.welcomes,
    required this.groupInfo,
    required this.precedingTranscript,
    required this.controlMessage,
    required this.signedPayload,
    required this.signerAuthenticationProof,
  });

  final GroupControlEvent event;
  final Uint8List commit;
  final List<Uint8List> authenticationBundleRequests;
  final List<Uint8List> welcomes;
  final Uint8List groupInfo;
  final List<_EncodedControlTranscriptEntry> precedingTranscript;
  final Uint8List controlMessage;
  final Uint8List signedPayload;
  final Uint8List signerAuthenticationProof;
}

final class _EncodedControlTranscriptEntry {
  const _EncodedControlTranscriptEntry({
    required this.event,
    required this.signedPayload,
    required this.signerAuthenticationProof,
  });

  final GroupControlEvent event;
  final Uint8List signedPayload;
  final Uint8List signerAuthenticationProof;
}

final class _TransportReader {
  _TransportReader(this.value) {
    if (value.isEmpty || value.length > 1024 * 1024) {
      throw const FormatException('invalid transport size');
    }
  }

  final Uint8List value;
  int _offset = 0;

  bool get finished => _offset == value.length;

  void expect(List<int> expected) {
    final actual = _take(expected.length);
    for (var index = 0; index < expected.length; index += 1) {
      if (actual[index] != expected[index]) {
        throw const FormatException('invalid transport magic');
      }
    }
  }

  int u8() => _take(1)[0];

  int u16() {
    final bytes = _take(2);
    return (bytes[0] << 8) | bytes[1];
  }

  Uint8List frame() {
    final lengthBytes = _take(4);
    final length =
        (lengthBytes[0] << 24) |
        (lengthBytes[1] << 16) |
        (lengthBytes[2] << 8) |
        lengthBytes[3];
    if (length <= 0 || length > 1024 * 1024) {
      throw const FormatException('invalid frame');
    }
    return Uint8List.fromList(_take(length));
  }

  Uint8List _take(int length) {
    final end = _offset + length;
    if (length < 0 || end < _offset || end > value.length) {
      throw const FormatException('truncated transport');
    }
    final result = Uint8List.sublistView(value, _offset, end);
    _offset = end;
    return result;
  }
}

final class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);
  void u8(int value) => _builder.addByte(value);
  void u16(int value) => _builder.add([(value >>> 8) & 0xff, value & 0xff]);
  void frame(Uint8List value) {
    final length = value.length;
    _builder.add([
      (length >>> 24) & 0xff,
      (length >>> 16) & 0xff,
      (length >>> 8) & 0xff,
      length & 0xff,
    ]);
    _builder.add(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
