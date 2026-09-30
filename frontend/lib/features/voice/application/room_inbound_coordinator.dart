import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// What one inbound room payload means for this device.
sealed class RoomInboundPreparation {
  const RoomInboundPreparation();

  String get opaqueEventId;
}

/// A change that commits with the pairwise receive that carried it.
final class RoomInboundChange extends RoomInboundPreparation {
  const RoomInboundChange(this.commit);

  final PreparedRoomInboxCommit commit;

  @override
  String get opaqueEventId => commit.opaqueEventId;
}

/// Nothing to change: the payload is acknowledged with its receive alone.
final class RoomInboundNoChange extends RoomInboundPreparation {
  const RoomInboundNoChange(this.opaqueEventId);

  @override
  final String opaqueEventId;
}

/// Decides what an ordinary pairwise envelope carrying a room payload means
/// (`voice-signalling-v1.md`, Applying an event and The payload).
///
/// The server checks nothing about a room, so everything is checked here,
/// before anything commits: every control event's signature under the key the
/// device list authenticates for the device it names, every chain link, and
/// every signer's authority over the roster the event was built on. The
/// pairwise session already authenticated the device that sent the envelope,
/// which is what lets a member answer a state request from that device alone.
///
/// It is the group's coordinator, with two receiving rules of the room's own
/// (*Starting the sessions a call needs*): a state request for a room this
/// device does not hold, or naming a later revision than it holds, opens a
/// state request back to its sender.
final class RoomInboundCoordinator {
  const RoomInboundCoordinator({
    required this.repository,
    required this.crypto,
    required this.liveDevices,
    required this.clock,
    required this.localUserId,
    this.stateMachine = const RoomControlStateMachine(),
  });

  final RoomRepositoryPort repository;
  final RoomControlCryptoPort crypto;
  final RoomLiveDeviceResolverPort liveDevices;
  final TimeSource clock;
  final String localUserId;
  final RoomControlStateMachine stateMachine;

  Future<Result<RoomInboundPreparation>> prepare({
    required String envelopeId,
    required String senderUserId,
    required String senderDeviceId,
    required Uint8List payload,
  }) async {
    final RoomSyncPayload decoded;
    try {
      decoded = RoomSyncPayloadCodec.decode(payload);
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
      RoomControlDelivery(:final control) => _control(sender, control),
      RoomStateRequestPayload() => _stateRequest(envelopeId, sender, decoded),
      RoomTranscriptPayload() => _transcript(envelopeId, sender, decoded),
    };
  }

  Future<Result<RoomInboundPreparation>> _control(
    _Sender sender,
    RoomSignedControlBytes control,
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
    final signed = (openedResult as Success<SignedRoomControlEvent>).value;
    final event = signed.event;
    final opaqueEventId = 'room-control:${event.eventId}';
    final storedResult = await repository.readStoredRoom(event.roomId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<RoomState?>).value;
    if (stored != null && _isQuarantined(stored)) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    final applied = stateMachine.apply(
      previous: stored,
      signedControl: signed,
      localUserId: localUserId,
    );
    switch (applied) {
      case RoomControlAccepted(:final state):
        if (stored == null && !state.isActiveMember(localUserId)) {
          // A room this device is not in is none of its business.
          return Result.success(RoomInboundNoChange(opaqueEventId));
        }
        return _change(
          PreparedRoomInboxTransition(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            expectedPrevious: stored,
            next: state,
            prepared: PreparedRoomTransition(controls: [signed]),
          ),
        );
      case RoomControlDuplicate():
        return Result.success(RoomInboundNoChange(opaqueEventId));
      case RoomControlStale():
        return _stale(opaqueEventId, sender, signed);
      case RoomControlAhead():
        // Something before this event never arrived. The event itself will
        // come back inside the transcript the sender is asked for.
        return _change(
          PreparedRoomInboxStateRequest(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            roomId: event.roomId,
            peerUserId: sender.userId,
          ),
        );
      case RoomControlQuarantined(:final state, :final reason):
        return _change(
          PreparedRoomInboxQuarantine(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            record: _record(event.roomId, reason, signed),
            retainLifecycle:
                state == null || reason != RoomQuarantineReason.siblingControl,
          ),
        );
    }
  }

  Future<Result<RoomInboundPreparation>> _stale(
    String opaqueEventId,
    _Sender sender,
    SignedRoomControlEvent signed,
  ) async {
    final event = signed.event;
    final transcriptResult = await repository.readTranscript(
      event.roomId,
      afterRevision: event.revision - 1,
    );
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final held = (transcriptResult as Success<List<StoredRoomControl>>).value;
    if (held.isNotEmpty &&
        held.first.revision == event.revision &&
        held.first.controlStateHash == signed.controlStateHash) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    // An authorized event this device never accepted, at a revision it has
    // already passed: the room forked, and no member may choose the branch.
    return _change(
      PreparedRoomInboxQuarantine(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        record: _record(
          event.roomId,
          RoomQuarantineReason.siblingControl,
          signed,
        ),
        retainLifecycle: false,
      ),
    );
  }

  Future<Result<RoomInboundPreparation>> _stateRequest(
    String envelopeId,
    _Sender sender,
    RoomStateRequestPayload request,
  ) async {
    final opaqueEventId = 'room-state-request:$envelopeId';
    final storedResult = await repository.readStoredRoom(request.roomId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<RoomState?>).value;
    PreparedRoomInboxStateRequest askBack() => PreparedRoomInboxStateRequest(
      opaqueEventId: opaqueEventId,
      senderUserId: sender.userId,
      senderDeviceId: sender.deviceId,
      roomId: request.roomId,
      peerUserId: sender.userId,
    );
    // A request is also how a member device starts a session with this one.
    // For a room this device does not hold — the ordinary case for a member's
    // new device — asking back is how it learns the room. The answer comes
    // only if the sender holds this device's account as an active member.
    if (stored == null) {
      return _change(askBack());
    }
    // Only an active member is told the room's current state, and only by a
    // device that holds an unquarantined state as an active member itself. A
    // member who was removed learns nothing that happened after it left, and a
    // removed device asks nobody anything.
    if (_isQuarantined(stored) ||
        !stored.isActiveMember(localUserId) ||
        !stored.isActiveMember(sender.userId)) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    // A member that has seen more of the room than this device has.
    if (request.haveRevision > stored.controlRevision) {
      return _change(askBack());
    }
    final transcriptResult = await repository.readTranscript(request.roomId);
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final transcript =
        (transcriptResult as Success<List<StoredRoomControl>>).value;
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
      payload = RoomSyncPayloadCodec.encode(
        RoomTranscriptPayload(
          roomId: request.roomId,
          baseRevision: base,
          baseStateHash: base == 0
              ? null
              : transcript[base - 1].controlStateHash,
          entries: transcript.skip(base).map(RoomSignedControlBytes.fromStored),
        ),
      );
    } on FormatException {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    return _change(
      PreparedRoomInboxOutbound(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        work: RoomOutboundWork(
          operationId: 'room-state-response:$envelopeId',
          roomId: request.roomId,
          eventId: 'room-state-response:$envelopeId',
          payload: payload,
          recipientUserIds: [sender.userId],
          recipientDeviceId: sender.deviceId,
        ),
      ),
    );
  }

  Future<Result<RoomInboundPreparation>> _transcript(
    String envelopeId,
    _Sender sender,
    RoomTranscriptPayload transcript,
  ) async {
    final opaqueEventId = 'room-transcript:$envelopeId';
    final keys = <String, List<RoomAuthenticatedLiveDevice>>{};
    final controls = <SignedRoomControlEvent>[];
    for (final entry in transcript.entries) {
      final openedResult = await _open(entry, keys);
      if (openedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      controls.add((openedResult as Success<SignedRoomControlEvent>).value);
    }
    var revision = transcript.baseRevision;
    var hash = transcript.baseStateHash;
    for (final control in controls) {
      if (control.event.roomId != transcript.roomId ||
          control.event.revision != revision + 1 ||
          control.event.previousControlStateHash != hash) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      revision = control.event.revision;
      hash = control.controlStateHash;
    }
    final storedResult = await repository.readStoredRoom(transcript.roomId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored = (storedResult as Success<RoomState?>).value;
    if (stored == null) {
      return _bootstrap(opaqueEventId, sender, transcript, controls);
    }
    if (_isQuarantined(stored) ||
        transcript.baseRevision > stored.controlRevision) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }

    // Whatever this device already holds must be exactly what it holds.
    final heldResult = await repository.readTranscript(
      transcript.roomId,
      afterRevision: transcript.baseRevision == 0
          ? 0
          : transcript.baseRevision - 1,
    );
    if (heldResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final heldHashes = {
      for (final entry
          in (heldResult as Success<List<StoredRoomControl>>).value)
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
        PreparedRoomInboxQuarantine(
          opaqueEventId: opaqueEventId,
          senderUserId: sender.userId,
          senderDeviceId: sender.deviceId,
          record: RoomQuarantineRecord(
            roomId: transcript.roomId,
            reason: RoomQuarantineReason.siblingControl,
            opaqueDigest: _hexBytes(
              evidence?.controlStateHash ?? stored.controlStateHash,
            ),
            receivedAt: clock.now().toUtc(),
          ),
          retainLifecycle: false,
          // A member's answer that reveals a fork is still an answer: waiting
          // for another one cannot un-fork the room.
          completesStateRequest: true,
        ),
      );
    }

    final suffix = controls
        .where((control) => control.event.revision > stored.controlRevision)
        .toList(growable: false);
    if (suffix.isEmpty) {
      // Only a sender that holds exactly this state confirms it. One that is
      // itself behind knows nothing newer, and its copy — an answer that came
      // late, or a new member's transcript that crossed an event — must not
      // retire a request another member still has to answer.
      if (revision != stored.controlRevision ||
          hash != stored.controlStateHash) {
        return Result.success(RoomInboundNoChange(opaqueEventId));
      }
      return _change(
        PreparedRoomInboxStateCurrent(
          opaqueEventId: opaqueEventId,
          senderUserId: sender.userId,
          senderDeviceId: sender.deviceId,
          roomId: transcript.roomId,
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
      if (applied is! RoomControlAccepted) {
        final reason = applied is RoomControlQuarantined
            ? applied.reason
            : RoomQuarantineReason.brokenControlChain;
        return _change(
          PreparedRoomInboxQuarantine(
            opaqueEventId: opaqueEventId,
            senderUserId: sender.userId,
            senderDeviceId: sender.deviceId,
            record: _record(transcript.roomId, reason, control),
            retainLifecycle: true,
          ),
        );
      }
      next = applied.state;
    }
    return _change(
      PreparedRoomInboxTransition(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        expectedPrevious: stored,
        next: next,
        prepared: PreparedRoomTransition(
          controls: suffix,
          completesStateRequest: true,
        ),
      ),
    );
  }

  /// Replays a room this device does not hold from its first event.
  ///
  /// The room is taken only when both this device's account and the sender's
  /// are active members of the state the transcript leads to: nobody hands a
  /// device a room from outside it.
  Future<Result<RoomInboundPreparation>> _bootstrap(
    String opaqueEventId,
    _Sender sender,
    RoomTranscriptPayload transcript,
    List<SignedRoomControlEvent> controls,
  ) async {
    if (transcript.baseRevision != 0 || controls.isEmpty) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    RoomState? next;
    for (final control in controls) {
      final applied = stateMachine.apply(
        previous: next,
        signedControl: control,
        localUserId: localUserId,
      );
      if (applied is! RoomControlAccepted) {
        return applied is RoomControlQuarantined
            ? _change(
                PreparedRoomInboxQuarantine(
                  opaqueEventId: opaqueEventId,
                  senderUserId: sender.userId,
                  senderDeviceId: sender.deviceId,
                  record: _record(transcript.roomId, applied.reason, control),
                  retainLifecycle: true,
                ),
              )
            : Result.success(RoomInboundNoChange(opaqueEventId));
      }
      next = applied.state;
    }
    if (!next!.isActiveMember(localUserId) ||
        !next.isActiveMember(sender.userId)) {
      return Result.success(RoomInboundNoChange(opaqueEventId));
    }
    return _change(
      PreparedRoomInboxTransition(
        opaqueEventId: opaqueEventId,
        senderUserId: sender.userId,
        senderDeviceId: sender.deviceId,
        expectedPrevious: null,
        next: next,
        prepared: PreparedRoomTransition(
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
  Future<Result<SignedRoomControlEvent>> _open(
    RoomSignedControlBytes control,
    Map<String, List<RoomAuthenticatedLiveDevice>> keys,
  ) async {
    var devices = keys[control.signerUserId];
    if (devices == null) {
      final resolved = await liveDevices.resolveAuthenticatedLiveDevices(
        control.signerUserId,
      );
      if (resolved case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      devices = (resolved as Success<List<RoomAuthenticatedLiveDevice>>).value;
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

  RoomQuarantineRecord _record(
    String roomId,
    RoomQuarantineReason reason,
    SignedRoomControlEvent signed,
  ) => RoomQuarantineRecord(
    roomId: roomId,
    reason: reason,
    opaqueDigest: _hexBytes(signed.controlStateHash),
    receivedAt: clock.now().toUtc(),
  );

  Result<RoomInboundPreparation> _change(PreparedRoomInboxCommit commit) =>
      Result.success(RoomInboundChange(commit));
}

final class _Sender {
  const _Sender({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

bool _isQuarantined(RoomState state) =>
    state.lifecycle == RoomLifecycle.forkQuarantined ||
    state.lifecycle == RoomLifecycle.controlQuarantined;

Uint8List _hexBytes(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);
