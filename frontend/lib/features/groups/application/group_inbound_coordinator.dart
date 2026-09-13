import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';

/// What one inbound group payload means for this device.
sealed class GroupInboundPreparation {
  const GroupInboundPreparation();

  String get opaqueEventId;
}

/// A change that commits with the pairwise receive that carried it.
final class GroupInboundChange extends GroupInboundPreparation {
  const GroupInboundChange(this.commit);

  final PreparedGroupInboxCommit commit;

  @override
  String get opaqueEventId => commit.opaqueEventId;
}

/// Nothing to change: the payload is acknowledged with its receive alone.
final class GroupInboundNoChange extends GroupInboundPreparation {
  const GroupInboundNoChange(this.opaqueEventId);

  @override
  final String opaqueEventId;
}

/// Decides what an ordinary pairwise envelope carrying a group payload means.
///
/// The server checks nothing about a group, so everything is checked here,
/// before anything commits: every control event's signature under the key the
/// device list authenticates for the device it names, every chain link, and
/// every signer's authority over the roster the event was built on. The
/// pairwise session already authenticated the device that sent the envelope,
/// which is what lets a member answer a state request from that device alone.
final class GroupInboundCoordinator {
  const GroupInboundCoordinator({
    required this.repository,
    required this.crypto,
    required this.liveDevices,
    required this.clock,
    required this.localUserId,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final GroupControlCryptoPort crypto;
  final GroupLiveDeviceResolverPort liveDevices;
  final TimeSource clock;
  final String localUserId;
  final GroupControlStateMachine stateMachine;

  Future<Result<GroupInboundPreparation>> prepare({
    required String envelopeId,
    required String senderUserId,
    required String senderDeviceId,
    required Uint8List payload,
  }) async {
    final GroupSyncPayload decoded;
    try {
      decoded = GroupSyncPayloadCodec.decode(payload);
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final sender = _Sender(
      userId: senderUserId.toLowerCase(),
      deviceId: senderDeviceId.toLowerCase(),
    );
    return switch (decoded) {
      GroupControlDelivery(:final control) => _control(sender, control),
      GroupStateRequestPayload() => _stateRequest(envelopeId, sender, decoded),
      GroupTranscriptPayload() => _transcript(envelopeId, sender, decoded),
    };
  }

  Future<Result<GroupInboundPreparation>> _control(
    _Sender sender,
    GroupSignedControlBytes control,
  ) async {
    // A delivery comes from the device that signed it. A copy of somebody
    // else's event travels only inside a transcript, where it is replayed from
    // the state it builds on.
    if (control.signerUserId != sender.userId ||
        control.signerDeviceId != sender.deviceId) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final openedResult = await _open(control, {});
    if (openedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final signed = (openedResult as Success<SignedGroupControlEvent>).value;
    final event = signed.event;
    final opaqueEventId = 'group-control:${event.eventId}';
    final storedResult = await repository.readStoredGroup(event.groupId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<GroupState?>).value;
    if (stored != null && _isQuarantined(stored)) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    final applied = stateMachine.apply(
      previous: stored,
      signedControl: signed,
      localUserId: localUserId,
    );
    switch (applied) {
      case GroupControlAccepted(:final state):
        if (stored == null && state.member(localUserId)?.isActive != true) {
          // A group this device is not in is none of its business.
          return Result.success(GroupInboundNoChange(opaqueEventId));
        }
        return _change(
          PreparedGroupInboxTransition(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            expectedPrevious: stored,
            next: state,
            prepared: PreparedGroupTransition(controls: [signed]),
          ),
        );
      case GroupControlDuplicate():
        return Result.success(GroupInboundNoChange(opaqueEventId));
      case GroupControlStale():
        return _stale(opaqueEventId, sender, signed);
      case GroupControlAhead():
        // Something before this event never arrived. The event itself will
        // come back inside the transcript the sender is asked for.
        return _change(
          PreparedGroupInboxStateRequest(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            groupId: event.groupId,
            peerUserId: sender.userId,
          ),
        );
      case GroupControlQuarantined(:final state, :final reason):
        return _change(
          PreparedGroupInboxQuarantine(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            record: _record(event.groupId, reason, signed),
            retainLifecycle:
                state == null || reason != GroupQuarantineReason.siblingControl,
          ),
        );
    }
  }

  Future<Result<GroupInboundPreparation>> _stale(
    String opaqueEventId,
    _Sender sender,
    SignedGroupControlEvent signed,
  ) async {
    final event = signed.event;
    final transcriptResult = await repository.readTranscript(
      event.groupId,
      afterRevision: event.revision - 1,
    );
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final held = (transcriptResult as Success<List<StoredGroupControl>>).value;
    if (held.isNotEmpty &&
        held.first.revision == event.revision &&
        held.first.controlStateHash == signed.controlStateHash) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    // An authorized event this device never accepted, at a revision it has
    // already passed: the group forked, and no member may choose the branch.
    return _change(
      PreparedGroupInboxQuarantine(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        record: _record(
          event.groupId,
          GroupQuarantineReason.siblingControl,
          signed,
        ),
        retainLifecycle: false,
      ),
    );
  }

  Future<Result<GroupInboundPreparation>> _stateRequest(
    String envelopeId,
    _Sender sender,
    GroupStateRequestPayload request,
  ) async {
    final opaqueEventId = 'group-state-request:$envelopeId';
    final storedResult = await repository.readStoredGroup(request.groupId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<GroupState?>).value;
    // Only an active member is told the group's current state, and only by a
    // device that holds an unquarantined state as an active member itself. A
    // member who was removed learns nothing that happened after it left.
    if (stored == null ||
        _isQuarantined(stored) ||
        stored.member(sender.userId)?.isActive != true ||
        stored.member(localUserId)?.isActive != true ||
        request.haveRevision > stored.controlRevision) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    final transcriptResult = await repository.readTranscript(request.groupId);
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final transcript =
        (transcriptResult as Success<List<StoredGroupControl>>).value;
    if (transcript.length != stored.controlRevision ||
        transcript.last.controlStateHash != stored.controlStateHash) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    // A requester whose state this device also passed through gets what came
    // after it. One whose state this device never held gets everything, so
    // that it sees the fork for itself.
    final base =
        request.haveRevision == 0 ||
            transcript[request.haveRevision - 1].controlStateHash ==
                request.haveStateHash
        ? request.haveRevision
        : 0;
    final Uint8List payload;
    try {
      payload = GroupSyncPayloadCodec.encode(
        GroupTranscriptPayload(
          groupId: request.groupId,
          baseRevision: base,
          baseStateHash: base == 0
              ? null
              : transcript[base - 1].controlStateHash,
          entries: transcript
              .skip(base)
              .map(GroupSignedControlBytes.fromStored),
        ),
      );
    } on FormatException {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    return _change(
      PreparedGroupInboxOutbound(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        work: GroupOutboundWork(
          operationId: 'group-state-response:$envelopeId',
          groupId: request.groupId,
          eventId: 'group-state-response:$envelopeId',
          payload: payload,
          recipientUserIds: [sender.userId],
          recipientDeviceId: sender.deviceId,
        ),
      ),
    );
  }

  Future<Result<GroupInboundPreparation>> _transcript(
    String envelopeId,
    _Sender sender,
    GroupTranscriptPayload transcript,
  ) async {
    final opaqueEventId = 'group-transcript:$envelopeId';
    final keys = <String, List<GroupAuthenticatedLiveDevice>>{};
    final controls = <SignedGroupControlEvent>[];
    for (final entry in transcript.entries) {
      final openedResult = await _open(entry, keys);
      if (openedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      controls.add((openedResult as Success<SignedGroupControlEvent>).value);
    }
    var revision = transcript.baseRevision;
    var hash = transcript.baseStateHash;
    for (final control in controls) {
      if (control.event.groupId != transcript.groupId ||
          control.event.revision != revision + 1 ||
          control.event.previousControlStateHash != hash) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      revision = control.event.revision;
      hash = control.controlStateHash;
    }
    final storedResult = await repository.readStoredGroup(transcript.groupId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<GroupState?>).value;
    if (stored == null) {
      return _bootstrap(opaqueEventId, sender, transcript, controls);
    }
    if (_isQuarantined(stored) ||
        transcript.baseRevision > stored.controlRevision) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }

    // Whatever this device already holds must be exactly what it holds.
    final heldResult = await repository.readTranscript(
      transcript.groupId,
      afterRevision: transcript.baseRevision == 0
          ? 0
          : transcript.baseRevision - 1,
    );
    if (heldResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final heldHashes = {
      for (final entry
          in (heldResult as Success<List<StoredGroupControl>>).value)
        entry.revision: entry.controlStateHash,
    };
    final forked =
        (transcript.baseRevision > 0 &&
            heldHashes[transcript.baseRevision] != transcript.baseStateHash) ||
        controls.any(
          (control) =>
              control.event.revision <= stored.controlRevision &&
              heldHashes[control.event.revision] != control.controlStateHash,
        );
    if (forked) {
      final evidence = controls.isEmpty ? null : controls.first;
      return _change(
        PreparedGroupInboxQuarantine(
          opaqueEventId: opaqueEventId,
          senderUserId: sender.userId,
          senderDeviceId: sender.deviceId,
          record: GroupQuarantineRecord(
            groupId: transcript.groupId,
            reason: GroupQuarantineReason.siblingControl,
            opaqueDigest: _hexBytes(
              evidence?.controlStateHash ?? stored.controlStateHash,
            ),
            receivedAt: clock.now().toUtc(),
          ),
          retainLifecycle: false,
          // A member's answer that reveals a fork is still an answer: waiting
          // for another one cannot un-fork the group.
          completesStateRequest: true,
        ),
      );
    }

    final suffix = controls
        .where((control) => control.event.revision > stored.controlRevision)
        .toList(growable: false);
    if (suffix.isEmpty) {
      return _change(
        PreparedGroupInboxStateCurrent(
          opaqueEventId: opaqueEventId,
          senderUserId: sender.userId,
          senderDeviceId: sender.deviceId,
          groupId: transcript.groupId,
          controlRevision: stored.controlRevision,
          controlStateHash: stored.controlStateHash,
        ),
      );
    }
    var next = stored;
    for (final control in suffix) {
      final applied = stateMachine.apply(
        previous: next,
        signedControl: control,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) {
        final reason = applied is GroupControlQuarantined
            ? applied.reason
            : GroupQuarantineReason.brokenControlChain;
        return _change(
          PreparedGroupInboxQuarantine(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            record: _record(transcript.groupId, reason, control),
            retainLifecycle: true,
          ),
        );
      }
      next = applied.state;
    }
    return _change(
      PreparedGroupInboxTransition(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        expectedPrevious: stored,
        next: next,
        prepared: PreparedGroupTransition(
          controls: suffix,
          completesStateRequest: true,
        ),
      ),
    );
  }

  /// Replays a group this device does not hold from its first event.
  Future<Result<GroupInboundPreparation>> _bootstrap(
    String opaqueEventId,
    _Sender sender,
    GroupTranscriptPayload transcript,
    List<SignedGroupControlEvent> controls,
  ) async {
    if (transcript.baseRevision != 0 || controls.isEmpty) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    GroupState? next;
    for (final control in controls) {
      final applied = stateMachine.apply(
        previous: next,
        signedControl: control,
        localUserId: localUserId,
      );
      if (applied is! GroupControlAccepted) {
        return applied is GroupControlQuarantined
            ? _change(
                PreparedGroupInboxQuarantine(
                  opaqueEventId: opaqueEventId,
                  senderUserId: sender.userId,
                  senderDeviceId: sender.deviceId,
                  record: _record(transcript.groupId, applied.reason, control),
                  retainLifecycle: true,
                ),
              )
            : Result.success(GroupInboundNoChange(opaqueEventId));
      }
      next = applied.state;
    }
    if (next!.member(localUserId)?.isActive != true) {
      return Result.success(GroupInboundNoChange(opaqueEventId));
    }
    return _change(
      PreparedGroupInboxTransition(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        expectedPrevious: null,
        next: next,
        prepared: PreparedGroupTransition(
          controls: controls,
          completesStateRequest: true,
        ),
      ),
    );
  }

  /// Opens one entry under the key of the live device it names.
  ///
  /// A device that is no longer in its account's authenticated device list
  /// cannot vouch for anything, old events included, so an entry it signed
  /// fails closed here rather than being accepted on the server's word.
  Future<Result<SignedGroupControlEvent>> _open(
    GroupSignedControlBytes control,
    Map<String, List<GroupAuthenticatedLiveDevice>> keys,
  ) async {
    var devices = keys[control.signerUserId];
    if (devices == null) {
      final resolved = await liveDevices.resolveAuthenticatedLiveDevices(
        control.signerUserId,
      );
      if (resolved case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      devices = (resolved as Success<List<GroupAuthenticatedLiveDevice>>).value;
      keys[control.signerUserId] = devices;
    }
    final matches = devices
        .where(
          (device) =>
              device.userId == control.signerUserId &&
              device.deviceId == control.signerDeviceId,
        )
        .toList(growable: false);
    if (matches.length != 1) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return crypto.open(
      control: control,
      signerSigningPublic: matches.single.signingPublic,
    );
  }

  GroupQuarantineRecord _record(
    String groupId,
    GroupQuarantineReason reason,
    SignedGroupControlEvent signed,
  ) => GroupQuarantineRecord(
    groupId: groupId,
    reason: reason,
    opaqueDigest: _hexBytes(signed.controlStateHash),
    receivedAt: clock.now().toUtc(),
  );

  Result<GroupInboundPreparation> _change(PreparedGroupInboxCommit commit) =>
      Result.success(GroupInboundChange(commit));
}

final class _Sender {
  const _Sender({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

bool _isQuarantined(GroupState state) =>
    state.lifecycle == GroupLifecycle.forkQuarantined ||
    state.lifecycle == GroupLifecycle.controlQuarantined;

Uint8List _hexBytes(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);
