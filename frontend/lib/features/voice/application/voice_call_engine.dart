import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/application/voice_peer_connection.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// This device's call: one at a time, in one room, as a full mesh of the
/// connections of `VoicePeerConnection` (`backend/CLIENT_CONTRACT.md` §N,
/// `voice-signalling-v1.md` Part 2).
///
/// **Joining.** A join is refused before anything is sent unless this device
/// may act in the room ([RoomAuthorization.mayAct]). Then the relay credential
/// is minted (§N rule 9), the room starts the pairwise sessions the call will
/// need on the durable path, and a 16-byte join id is drawn from the native
/// CSPRNG. This device asks every live device of every active member who is in
/// the call (§N rule 5), and after the first answer window it fans its `join`
/// out to the same devices — unless the answers already name ten, in which
/// case no `join` goes out and the call is full (§N rule 10).
///
/// **The mesh.** A participant that receives a `join` offers, and the device
/// that joined answers (§N rule 4). One connection per device pair: a peer is
/// keyed on its device and its join id, and a frame from a join id this
/// device has not seen means that device left and joined again, so its old
/// connection is torn down. A `leave` of the current join, or a connection that
/// closes or fails, drops the device.
///
/// **Retries** (§N rule 7). The `join`, the `participants_query` and each
/// offer and answer are sent again at 2, 4 and 8 seconds, each within 25 %,
/// until something comes back. A participant that has answered nothing six
/// seconds after the fourth attempt is not reachable, and nothing more is sent
/// to it until it announces itself again or the user asks to try again.
/// Nothing else pauses.
///
/// **The ceiling** (§N rule 10, ADR-077 D2). When more than ten devices would
/// be in the call, every participant keeps the ten whose ids sort lowest and
/// offers nothing to the rest, so they converge without asking anybody.
///
/// **The roster** (§N rule 8). Every frame is applied only from a device whose
/// account is an active member of the room, as the room state holds it when
/// the frame arrives, and only while this device may act in that room. When
/// the room state removes a member, each connection to that member's devices
/// is closed at once; when it removes this device's account, or the room can
/// no longer hold a call, this device's own connections close and the call
/// ends.
///
/// **Mute** silences this device's one capture, so every connection sends
/// silence; the capture keeps running and nothing is renegotiated. Each call
/// starts unmuted.
///
/// A call writes no row and logs nothing: who is connected, the room text and
/// the credential live here for the life of the call.
final class VoiceCallEngine implements VoiceCallPort {
  VoiceCallEngine({
    required String currentUserId,
    required String currentDeviceId,
    required this.rooms,
    required this.liveDevices,
    required this.sessions,
    required this.credentials,
    required this.signalling,
    required this.media,
    required this.localAudio,
    required this.identity,
    required this.clock,
    required this.timer,
    required this.jitter,
  }) : currentUserId = currentUserId.toLowerCase(),
       currentDeviceId = currentDeviceId.toLowerCase();

  /// Lines of room text one call keeps; the oldest go first.
  static const roomTextLimit = 200;

  /// The least a credential refresh waits, so that a clock that has not moved
  /// cannot spin it.
  static const _refreshFloor = Duration(seconds: 1);

  /// How long a refresh that failed waits before it asks again. The held
  /// credential stays in force meanwhile.
  static const _refreshRetry = Duration(minutes: 1);

  final String currentUserId;
  final String currentDeviceId;
  final RoomStateReadPort rooms;
  final RoomLiveDeviceResolverPort liveDevices;
  final VoiceCallSessionsPort sessions;
  final RelayCredentialService credentials;
  final VoiceSignallingPort signalling;
  final VoicePeerMediaPort media;
  final VoiceLocalAudioPort localAudio;
  final RoomIdentityPort identity;
  final TimeSource clock;
  final VoiceSignalTimerPort timer;
  final VoiceRetryJitterPort jitter;

  final _states = StreamController<VoiceCallState>.broadcast();
  var _state = VoiceCallState.idle();
  StreamSubscription<InboundVoiceSignal>? _inbound;
  _Call? _call;
  var _joining = false;
  var _abandonJoin = false;
  var _disposed = false;
  Future<void> _turn = Future<void>.value();

  @override
  VoiceCallState get state => _state;

  /// The state now, then every change.
  @override
  Stream<VoiceCallState> get states =>
      Stream<VoiceCallState>.multi((controller) {
        controller.add(_state);
        final subscription = _states.stream.listen(
          controller.add,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  /// Starts taking signalling frames, so that this device can answer a call
  /// it is in.
  void start() {
    if (_disposed) {
      return;
    }
    _inbound ??= signalling.inbound.listen(
      (signal) => unawaited(_serially(() => _receive(signal))),
    );
  }

  /// Joins a call in the room [roomId], the room state's hex id.
  ///
  /// The microphone permission must already have been asked for: the first
  /// connection takes a hold on the call's capture, which on Android asks for
  /// the permission itself when it is missing (§N rule 11).
  @override
  Future<VoiceJoinOutcome> join(String roomId) async {
    final normalized = roomId.toLowerCase();
    if (_disposed || _joining || _call != null) {
      return const VoiceJoinRefused(VoiceCallEndReason.alreadyInCall);
    }
    final Uint8List roomIdBytes;
    try {
      roomIdBytes = _hexBytes(normalized, RoomState.roomIdBytes);
    } on FormatException {
      return const VoiceJoinRefused(VoiceCallEndReason.roomUnavailable);
    }
    _joining = true;
    _abandonJoin = false;
    _Call call;
    try {
      _emit(
        VoiceCallState(phase: VoiceCallPhase.preparing, roomId: normalized),
      );
      final room = await _readRoom(normalized);
      final refused = _refusalFor(room);
      if (refused != null) {
        return _refuse(normalized, refused);
      }
      if (_abandoned) {
        return _refuse(normalized, VoiceCallEndReason.left);
      }

      // §N rule 9: a credential before anything is announced.
      final RelayCredential credential;
      switch (await credentials.fetchForJoin()) {
        case RelayCredentialMinted(credential: final value) ||
            RelayCredentialHeld(credential: final value):
          credential = value;
        case VoiceUnavailable():
          return _refuse(normalized, VoiceCallEndReason.voiceUnavailable);
        case RelayMintThrottled(:final retryAt):
          return _refuse(
            normalized,
            VoiceCallEndReason.throttled,
            retryAt: retryAt,
          );
        case RelayMintFailed():
          return _refuse(normalized, VoiceCallEndReason.credentialFailed);
      }

      // A volatile frame never starts a session, so the room starts the ones
      // the call needs before its first frame (ADR-077, decided B). A device
      // whose request it has not fetched yet takes a later attempt.
      await sessions.prepareSessionsForCall(normalized);
      final joinId = await _drawJoinId();
      final current = await _readRoom(normalized);
      final refusedNow = joinId == null
          ? VoiceCallEndReason.localFailure
          : _refusalFor(current);
      if (refusedNow != null || _abandoned) {
        credentials.release();
        return _refuse(normalized, refusedNow ?? VoiceCallEndReason.left);
      }
      final targets = await _resolveTargets(current!);
      if (_abandoned) {
        credentials.release();
        return _refuse(normalized, VoiceCallEndReason.left);
      }
      // Each call starts unmuted, whatever the last one ended as. Nothing
      // holds the capture yet: the first connection takes the first hold.
      await localAudio.setMuted(false);
      call = _Call(
        roomId: normalized,
        roomIdBytes: roomIdBytes,
        join: VoiceLocalJoin(
          roomId: roomIdBytes,
          joinId: joinId!,
          deviceId: currentDeviceId,
        ),
        credential: credential,
        targets: targets,
      );
      _call = call;
      final watched = call;
      call.roomWatch = rooms
          .watchRoom(normalized)
          .listen(
            (room) => _onRoomChanged(watched, room),
            // A room that can no longer be read can no longer be checked.
            onError: (Object _) => _onRoomChanged(watched, null),
          );
      _emitCall(call);
      unawaited(_announce(call, _Announcement.query));
      unawaited(_refreshCredential(call));
    } finally {
      _joining = false;
    }

    // The first answer window: a participant that heard the query has
    // answered by now, so this device knows whether the call is full.
    await timer.wait(VoiceRetrySchedule.waitAfter(0, jitter.next()));
    return _serially(() => _announceJoin(call));
  }

  /// Leaves the call: every connection closes, and a `leave` goes to each
  /// device that was in it. Nothing is retried.
  @override
  Future<void> leave() async {
    if (_call == null) {
      if (_joining) {
        _abandonJoin = true;
      }
      return;
    }
    await _serially(() async {
      final call = _call;
      if (call != null) {
        await _end(
          call,
          VoiceCallEndReason.left,
          leave: VoiceLeaveReason.userLeft,
        );
      }
    });
  }

  /// Sends one line of room text to every device in the call. Best effort: it
  /// is not retried, and a device that is not connected at that instant never
  /// gets it.
  @override
  Future<Result<void>> sendRoomText(String text) => _serially(() async {
    final call = _call;
    if (call == null || call.ended || !call.joined) {
      return const Result.failure(
        CancellationFailure(CancellationFailureKind.lifecycleInterrupted),
      );
    }
    if (text.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (text.runes.length > VoiceSignalLimits.maximumRoomTextScalars ||
        utf8.encode(text).length > VoiceSignalLimits.maximumRoomTextBytes) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    final VoiceRoomText body;
    try {
      body = VoiceRoomText(text);
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    // Shown because this device sent it: there is no echo to wait for.
    _addText(call, currentUserId, currentDeviceId, text, isOwn: true);
    _emitCall(call);
    await _send(call, body, call.join.nextCounter(), [
      for (final peer in _inCall(call))
        if (!call.silenced.contains(peer.deviceId)) peer.target,
    ]);
    return const Result.success(null);
  });

  /// Mutes or unmutes this device's microphone for the call in progress. The
  /// capture keeps running and every connection keeps its track, which sends
  /// silence while it is muted, so nothing is renegotiated and no peer is
  /// told: a peer's mute crosses no frame in this version.
  @override
  Future<void> setMuted(bool muted) => _serially(() async {
    final call = _call;
    if (call == null || call.ended || call.muted == muted) {
      return;
    }
    call.muted = muted;
    await localAudio.setMuted(muted);
    _emitCall(call);
  });

  /// Re-arms the four attempts for a peer that is not reachable: this device
  /// announces itself to that device again.
  @override
  Future<void> tryAgain(String deviceId) => _serially(() async {
    final call = _call;
    final key = deviceId.toLowerCase();
    final peer = call?.peers[key];
    if (call == null ||
        call.ended ||
        !call.joined ||
        peer == null ||
        peer.status != VoiceParticipantStatus.notReachable) {
      return;
    }
    call.targets[key] ??= peer.target;
    call.silenced.remove(key);
    peer.status = VoiceParticipantStatus.connecting;
    _emitCall(call);
    unawaited(_announce(call, _Announcement.join, onlyDeviceId: key));
  });

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _abandonJoin = true;
    await leave();
    await _inbound?.cancel();
    _inbound = null;
    await _states.close();
  }

  bool get _abandoned => _abandonJoin || _disposed;

  Future<VoiceJoinOutcome> _announceJoin(_Call call) async {
    if (call.ended) {
      return VoiceJoinRefused(call.endReason ?? VoiceCallEndReason.left);
    }
    // At ten it does not send one (`voice-signalling-v1.md`, The ceiling).
    if (call.peers.values.where(_isSeated).length >=
        VoiceCallCeiling.maximumJoinedDevices) {
      await _end(call, VoiceCallEndReason.callFull);
      return const VoiceJoinRefused(VoiceCallEndReason.callFull);
    }
    call.joined = true;
    _emitCall(call);
    unawaited(_announce(call, _Announcement.join));
    return const VoiceJoinAnnounced();
  }

  /// Sends a `join` or a `participants_query` to each target that has not
  /// answered it, four times at most, all under the counter of the first.
  ///
  /// After the last `join` and its answer window, a participant this device
  /// knows of only from another's answer, and that never negotiated, is not
  /// reachable.
  Future<void> _announce(
    _Call call,
    _Announcement kind, {
    String? onlyDeviceId,
  }) async {
    final int counter;
    final VoiceSignalBody body;
    switch (kind) {
      case _Announcement.join:
        counter = call.joinCounter ??= call.join.nextCounter();
        body = const VoiceJoin();
      case _Announcement.query:
        counter = call.queryCounter ??= call.join.nextCounter();
        body = const VoiceParticipantsQuery();
    }
    var sentLast = false;
    for (var attempt = 0; attempt < VoiceRetrySchedule.attempts; attempt += 1) {
      sentLast = await _serially(() async {
        if (call.ended) {
          return false;
        }
        final due = [
          for (final target in call.targets.values)
            if ((onlyDeviceId == null || target.deviceId == onlyDeviceId) &&
                _awaitsReply(call, kind, target.deviceId))
              target,
        ];
        await _send(call, body, counter, due);
        return due.isNotEmpty;
      });
      if (!sentLast) {
        break;
      }
      if (attempt < VoiceRetrySchedule.attempts - 1) {
        await timer.wait(VoiceRetrySchedule.waitAfter(attempt, jitter.next()));
      }
    }
    if (kind != _Announcement.join || call.ended) {
      return;
    }
    if (sentLast) {
      await timer.wait(VoiceRetrySchedule.answerWindow);
    }
    await _serially(() async {
      if (call.ended) {
        return;
      }
      for (final peer in call.peers.values) {
        if ((onlyDeviceId == null || peer.deviceId == onlyDeviceId) &&
            peer.connection == null &&
            peer.status == VoiceParticipantStatus.connecting) {
          peer.status = VoiceParticipantStatus.notReachable;
        }
      }
      if (onlyDeviceId == null) {
        call.announcing = false;
      }
      _emitCall(call);
    });
  }

  /// Whether [deviceId] still owes this device a reply to [kind]: an offer to
  /// a `join`, an answer to a query. A device negotiating with this one is in
  /// the call, and owes neither.
  bool _awaitsReply(_Call call, _Announcement kind, String deviceId) {
    if (call.silenced.contains(deviceId)) {
      return false;
    }
    final peer = call.peers[deviceId];
    if (peer != null &&
        (peer.connection != null ||
            peer.status != VoiceParticipantStatus.connecting)) {
      return false;
    }
    return kind == _Announcement.join || !call.answered.contains(deviceId);
  }

  Future<void> _receive(InboundVoiceSignal signal) async {
    final call = _call;
    if (call == null || call.ended) {
      return;
    }
    final senderUser = signal.senderUserId.toLowerCase();
    final senderDevice = signal.senderDeviceId.toLowerCase();
    if (senderDevice == currentDeviceId) {
      return;
    }
    switch (signal) {
      case UnsupportedVoiceSignal():
        // Its frame names no room this build can read, so it only speaks for
        // a peer this device already knows to be in the call.
        final peer = call.peers[senderDevice];
        if (peer != null && peer.userId == senderUser && _isSeated(peer)) {
          _closeNow(
            call,
            peer,
            keepAs: VoiceParticipantStatus.incompatibleVersion,
          );
          _emitCall(call);
        }
      case ReceivedVoiceSignal(:final message):
        await _receiveMessage(call, signal, senderUser, senderDevice, message);
    }
  }

  Future<void> _receiveMessage(
    _Call call,
    ReceivedVoiceSignal signal,
    String senderUser,
    String senderDevice,
    VoiceSignalMessage message,
  ) async {
    final header = message.header;
    if (!_same(header.roomId, call.roomIdBytes)) {
      return;
    }
    // §N rule 8: a frame is applied only from a device whose account is an
    // active member of the room as it is committed when the frame arrives,
    // and only while this device may act in it. The pairwise session has
    // already authenticated the device; the roster decides whether it counts.
    final room = await _readRoom(call.roomId);
    if (call.ended ||
        room == null ||
        !RoomAuthorization.mayAct(room, currentUserId) ||
        !room.isActiveMember(senderUser)) {
      return;
    }
    final joinKey = protocolBytesToHex(header.joinId);
    if (call.endedJoins[senderDevice]?.contains(joinKey) ?? false) {
      // A late frame of a join that has ended here.
      return;
    }
    var peer = call.peers[senderDevice];
    if (peer != null && peer.userId != senderUser) {
      return;
    }
    if (peer != null && peer.joinKey != joinKey) {
      if (message.body is VoiceLeave) {
        // Names a join that is not current: a late retry of an old leave.
        return;
      }
      // A join this device has not seen: the device left and joined again,
      // and its old connection is torn down.
      _closeNow(call, peer);
      peer = null;
    }
    switch (message.body) {
      case VoiceJoin():
        await _onJoin(call, peer, senderUser, senderDevice, header.joinId);
      case VoiceOffer(:final targetJoinId):
        await _onOffer(
          call,
          peer,
          signal,
          senderUser,
          senderDevice,
          header.joinId,
          targetJoinId,
        );
      case VoiceAnswer() || VoiceCandidates():
        final connection = peer?.connection;
        if (connection != null) {
          await connection.receive(signal);
        }
      case VoiceLeave():
        if (peer != null) {
          _closeNow(call, peer);
        }
      case VoiceParticipantsQuery():
        await _answerQuery(call, peer, senderUser, senderDevice);
      case VoiceParticipants(:final members):
        await _takeHints(
          call,
          room,
          senderUser,
          senderDevice,
          joinKey,
          members,
        );
      case VoiceRoomText(:final text):
        if (call.joined && peer?.connection != null) {
          _addText(call, senderUser, senderDevice, text, isOwn: false);
        }
    }
    _emitCall(call);
  }

  Future<void> _onJoin(
    _Call call,
    _Peer? peer,
    String userId,
    String deviceId,
    Uint8List joinId,
  ) async {
    if (!call.joined) {
      // This device has not announced itself yet. The device is joining, which
      // the ceiling counts, and this device's own join will reach it.
      if (peer == null) {
        call.peers[deviceId] = _Peer(
          userId: userId,
          deviceId: deviceId,
          joinId: joinId,
        );
      }
      return;
    }
    if (peer != null && (peer.connection != null || _isBarred(peer.status))) {
      // A retry of a join already being answered, or a peer nothing more is
      // sealed to until the user acts.
      return;
    }
    // Known from another's answer, or not reachable: a join from it now is the
    // announcement that brings it in.
    if (!await _admit(call, deviceId)) {
      return;
    }
    final admitted =
        peer ?? _Peer(userId: userId, deviceId: deviceId, joinId: joinId);
    call.peers[deviceId] = admitted;
    admitted.status = VoiceParticipantStatus.connecting;
    final connection = await _open(call, admitted);
    if (connection == null) {
      return;
    }
    // §N rule 4: a participant that receives a join sends an offer.
    await connection.negotiate();
    if (_isCurrent(call, admitted, connection)) {
      unawaited(_retryNegotiation(call, admitted));
    }
  }

  Future<void> _onOffer(
    _Call call,
    _Peer? peer,
    ReceivedVoiceSignal signal,
    String userId,
    String deviceId,
    Uint8List joinId,
    Uint8List targetJoinId,
  ) async {
    // An offer answers this device's join, so it comes only once the join has
    // gone out, and only for the join that is current.
    if (!call.joined || !_same(targetJoinId, call.join.joinId)) {
      return;
    }
    final existing = peer?.connection;
    if (existing != null) {
      final intake = await existing.receive(signal);
      if (intake == VoicePeerIntake.duplicate &&
          _isCurrent(call, peer!, existing)) {
        // The offer came again, so the answer to it was lost.
        await existing.resend();
      }
      return;
    }
    if (peer != null && _isBarred(peer.status)) {
      return;
    }
    if (!await _admit(call, deviceId)) {
      return;
    }
    final admitted =
        peer ?? _Peer(userId: userId, deviceId: deviceId, joinId: joinId);
    call.peers[deviceId] = admitted;
    admitted.status = VoiceParticipantStatus.connecting;
    final connection = await _open(call, admitted);
    if (connection == null) {
      return;
    }
    final intake = await connection.receive(signal);
    if (!_isCurrent(call, admitted, connection)) {
      return;
    }
    switch (intake) {
      case VoicePeerIntake.applied:
        unawaited(_retryNegotiation(call, admitted));
      case VoicePeerIntake.refusedMedia:
        // Not one audio section: not a peer of this version (§N rule 1).
        _closeNow(
          call,
          admitted,
          keepAs: VoiceParticipantStatus.incompatibleVersion,
        );
      case _:
        _closeNow(call, admitted, keepAs: VoiceParticipantStatus.notReachable);
    }
  }

  /// Answers a `participants_query` with the devices this one believes are
  /// in the call, itself included (§N rule 5). Only a participant answers, and
  /// it answers each copy, because a query sent again means the answer was
  /// lost. Not retried, and nothing is sent to a join this device has given
  /// up on: not reachable, blocked or of another version.
  Future<void> _answerQuery(
    _Call call,
    _Peer? peer,
    String userId,
    String deviceId,
  ) async {
    if (!call.joined ||
        call.silenced.contains(deviceId) ||
        (peer != null && !_isSeated(peer))) {
      return;
    }
    final members = <VoiceParticipant>[
      VoiceParticipant(
        userId: protocolUuidBytes(currentUserId),
        deviceId: protocolUuidBytes(currentDeviceId),
        joinId: call.join.joinId,
      ),
      for (final other in _inCall(call))
        VoiceParticipant(
          userId: protocolUuidBytes(other.userId),
          deviceId: protocolUuidBytes(other.deviceId),
          joinId: other.joinId,
        ),
    ];
    await _send(
      call,
      VoiceParticipants(
        members.take(VoiceSignalLimits.maximumParticipants).toList(),
      ),
      call.join.nextCounter(),
      [VoiceSignalTarget(userId: userId, deviceId: deviceId)],
    );
  }

  /// Takes a `participants` answer as the hint it is: each device it names
  /// that this device does not know becomes a participant it expects an offer
  /// from, and none of it changes a connection.
  ///
  /// A device another member names is taken only when it is a live device of
  /// an active member, as this device resolved them; the sender's own entry
  /// must name the account the session authenticated and the join its header
  /// does.
  Future<void> _takeHints(
    _Call call,
    RoomState room,
    String senderUser,
    String senderDevice,
    String senderJoinKey,
    List<VoiceParticipant> members,
  ) async {
    call.answered.add(senderDevice);
    for (final member in members) {
      final String userId;
      final String deviceId;
      try {
        userId = protocolUuidString(member.userId);
        deviceId = protocolUuidString(member.deviceId);
      } on FormatException {
        continue;
      }
      final joinKey = protocolBytesToHex(member.joinId);
      final target = call.targets[deviceId];
      final named = deviceId == senderDevice
          ? userId == senderUser && joinKey == senderJoinKey
          : target != null && target.userId == userId;
      if (deviceId == currentDeviceId ||
          !named ||
          !room.isActiveMember(userId) ||
          call.peers.containsKey(deviceId) ||
          call.silenced.contains(deviceId) ||
          (call.endedJoins[deviceId]?.contains(joinKey) ?? false)) {
        continue;
      }
      call.peers[deviceId] = _Peer(
        userId: userId,
        deviceId: deviceId,
        joinId: member.joinId,
      );
    }
    if (call.joined && !_fits(call, const {})) {
      await _end(call, VoiceCallEndReason.callFull);
    }
  }

  /// Whether [deviceId] takes a seat in the call (ADR-077 D2).
  ///
  /// When more than ten devices would be in the call, every participant keeps
  /// the ten whose ids sort lowest. Against every device this one knows of —
  /// another participant's answer included — this device outside them ends
  /// its call, and a newcomer outside them is offered and answered nothing.
  /// Against the devices this one is connected or negotiating with, a
  /// connection to a device outside them is closed: an answer is a hint, and
  /// closes nothing.
  Future<bool> _admit(_Call call, String deviceId) async {
    final known = <String>{
      currentDeviceId,
      deviceId,
      for (final peer in call.peers.values)
        if (_isSeated(peer)) peer.deviceId,
    };
    if (known.length > VoiceCallCeiling.maximumJoinedDevices) {
      final kept = VoiceCallCeiling.kept(known);
      if (!kept.contains(currentDeviceId)) {
        await _end(call, VoiceCallEndReason.callFull);
        return false;
      }
      if (!kept.contains(deviceId)) {
        return false;
      }
    }
    final seated = <String>{
      currentDeviceId,
      deviceId,
      for (final peer in call.peers.values)
        if (peer.connection != null && _isSeated(peer)) peer.deviceId,
    };
    if (seated.length > VoiceCallCeiling.maximumJoinedDevices) {
      // The newcomer is among the ten lowest of every device this one knows
      // of, so it is among the ten lowest of these.
      final kept = VoiceCallCeiling.kept(seated);
      for (final peer in call.peers.values.toList()) {
        if (peer.connection != null && !kept.contains(peer.deviceId)) {
          _closeNow(call, peer);
        }
      }
    }
    return true;
  }

  /// Whether this device is among the ten lowest of every device it knows to
  /// be in the call, with [joining] added.
  bool _fits(_Call call, Set<String> joining) {
    final known = <String>{
      currentDeviceId,
      ...joining,
      for (final peer in call.peers.values)
        if (_isSeated(peer)) peer.deviceId,
    };
    return known.length <= VoiceCallCeiling.maximumJoinedDevices ||
        VoiceCallCeiling.kept(known).contains(currentDeviceId);
  }

  Future<VoicePeerConnection?> _open(_Call call, _Peer peer) async {
    final VoicePeerAddress address;
    try {
      address = VoicePeerAddress(
        userId: peer.userId,
        deviceId: peer.deviceId,
        joinId: peer.joinId,
      );
    } on FormatException {
      return null;
    }
    final opened = await VoicePeerConnection.open(
      join: call.join,
      peer: address,
      configuration: call.credential.iceConfiguration,
      media: media,
      localAudio: localAudio,
      signalling: signalling,
      timer: timer,
    );
    if (opened case FailureResult()) {
      if (!call.ended && call.peers[peer.deviceId] == peer) {
        // The microphone or the platform connection could not open, which no
        // peer can fix.
        await _end(
          call,
          VoiceCallEndReason.localFailure,
          leave: VoiceLeaveReason.localFailure,
        );
      }
      return null;
    }
    final connection = (opened as Success<VoicePeerConnection>).value;
    if (call.ended ||
        call.peers[peer.deviceId] != peer ||
        peer.connection != null) {
      await connection.close();
      return null;
    }
    peer
      ..connection = connection
      ..everConnected = false
      ..events = connection.events.listen(
        (event) => _onPeerEvent(call, peer, connection, event),
      );
    return connection;
  }

  void _onPeerEvent(
    _Call call,
    _Peer peer,
    VoicePeerConnection connection,
    VoicePeerEvent event,
  ) => unawaited(
    _serially(() async {
      if (!_isCurrent(call, peer, connection)) {
        return;
      }
      switch (event) {
        case VoicePeerStateChanged(:final state):
          switch (state) {
            case VoicePeerState.connecting || VoicePeerState.disconnected:
              peer.status = peer.everConnected
                  ? VoiceParticipantStatus.reconnecting
                  : VoiceParticipantStatus.connecting;
            case VoicePeerState.connected:
              peer
                ..status = VoiceParticipantStatus.connected
                ..everConnected = true;
            case VoicePeerState.failed:
              // §N rule 4: a connection that fails is closed and the device
              // dropped. One that never connected says so on its tile.
              _closeNow(
                call,
                peer,
                keepAs: peer.everConnected
                    ? null
                    : VoiceParticipantStatus.notReachable,
              );
            case VoicePeerState.closed:
              _closeNow(call, peer);
          }
        case VoicePeerIceRestart(:final inProgress):
          peer.restartingIce = inProgress;
        case VoicePeerSignalNotSent(:final reason):
          _notSent(call, peer.deviceId, reason);
        case VoicePeerAnswered():
          break;
      }
      _emitCall(call);
    }),
  );

  /// Sends the outstanding offer, or the answer, again at each wait of the
  /// schedule until the connection has connected. A peer that has not, six
  /// seconds after the fourth attempt, is not reachable — unless it connected
  /// once already, when only a restart was waiting and the old path carries
  /// on.
  Future<void> _retryNegotiation(_Call call, _Peer peer) async {
    final token = ++peer.negotiation;
    bool stale() =>
        call.ended ||
        peer.negotiation != token ||
        peer.connection == null ||
        call.peers[peer.deviceId] != peer;
    bool negotiated() =>
        peer.everConnected && !(peer.connection?.isRestartingIce ?? false);

    for (
      var attempt = 0;
      attempt < VoiceRetrySchedule.attempts - 1;
      attempt += 1
    ) {
      await timer.wait(VoiceRetrySchedule.waitAfter(attempt, jitter.next()));
      final carryOn = await _serially(() async {
        if (stale() || negotiated()) {
          return false;
        }
        await peer.connection!.resend();
        return true;
      });
      if (!carryOn) {
        return;
      }
    }
    await timer.wait(VoiceRetrySchedule.answerWindow);
    await _serially(() async {
      if (stale() || negotiated() || peer.everConnected) {
        return;
      }
      _closeNow(call, peer, keepAs: VoiceParticipantStatus.notReachable);
      _emitCall(call);
    });
  }

  /// Refreshes the credential once less than an hour of it remains (§N rule
  /// 9), and restarts ICE on every connection with the new one rather than
  /// tearing the call down.
  Future<void> _refreshCredential(_Call call) async {
    var due = call.credential.refreshDueAt;
    while (!call.ended) {
      final wait = due.difference(clock.now());
      await timer.wait(wait < _refreshFloor ? _refreshFloor : wait);
      if (call.ended) {
        return;
      }
      final outcome = await credentials.refreshIfDue();
      if (call.ended) {
        return;
      }
      switch (outcome) {
        case RelayCredentialMinted(:final credential):
          await _serially(() => _restartIce(call, credential));
          due = credential.refreshDueAt;
        case RelayCredentialHeld(:final credential):
          due = credential.refreshDueAt;
        case RelayMintThrottled(:final retryAt):
          due = retryAt;
        case RelayMintFailed():
          due = clock.now().add(_refreshRetry);
        case VoiceUnavailable():
          return;
      }
    }
  }

  Future<void> _restartIce(_Call call, RelayCredential credential) async {
    if (call.ended) {
      return;
    }
    // New connections take the new credential from now on.
    call.credential = credential;
    for (final peer in _inCall(call).toList()) {
      final connection = peer.connection!;
      final restarted = await connection.restartIce(
        credential.iceConfiguration,
      );
      if (restarted is Success<void> &&
          _isCurrent(call, peer, connection) &&
          peer.everConnected &&
          connection.isRestartingIce) {
        unawaited(_retryNegotiation(call, peer));
      }
    }
    _emitCall(call);
  }

  /// A room change: a removed member's connections close at once, before
  /// anything else is done with it (§N rule 8). When this device may no
  /// longer call in the room — its account removed or gone, the room waiting
  /// for its state or forked — its own connections close and the call ends.
  ///
  /// The closing happens here, as the change arrives, and not behind whatever
  /// the call is busy with.
  void _onRoomChanged(_Call call, RoomState? room) {
    if (call.ended || _call != call) {
      return;
    }
    if (room == null || !RoomAuthorization.mayAct(room, currentUserId)) {
      final leaveTargets = _leaveTargets(call);
      for (final peer in call.peers.values.toList()) {
        _closeNow(call, peer);
      }
      unawaited(
        _serially(
          () => _end(
            call,
            _endReasonFor(room),
            leave: VoiceLeaveReason.roomStateChanged,
            leaveTargets: leaveTargets,
          ),
        ),
      );
      return;
    }
    var changed = false;
    for (final peer in call.peers.values.toList()) {
      if (!room.isActiveMember(peer.userId)) {
        _closeNow(call, peer);
        changed = true;
      }
    }
    call.targets.removeWhere(
      (_, target) => !room.isActiveMember(target.userId),
    );
    if (changed) {
      unawaited(_serially(() async => _emitCall(call)));
    }
  }

  /// Closes [peer]'s connection at once. With [keepAs] its tile stays and
  /// says why; without, the device leaves the call, and frames of the join it
  /// was in are refused from then on.
  void _closeNow(_Call call, _Peer peer, {VoiceParticipantStatus? keepAs}) {
    final connection = peer.detach();
    peer
      ..negotiation += 1
      ..restartingIce = false;
    if (keepAs == null) {
      if (call.peers[peer.deviceId] == peer) {
        call.peers.remove(peer.deviceId);
      }
      (call.endedJoins[peer.deviceId] ??= <String>{}).add(peer.joinKey);
    } else {
      peer.status = keepAs;
    }
    // Marked closed before its first await, so nothing more is taken on it.
    if (connection != null) {
      unawaited(connection.close());
    }
  }

  Future<void> _end(
    _Call call,
    VoiceCallEndReason reason, {
    VoiceLeaveReason? leave,
    List<VoiceSignalTarget>? leaveTargets,
  }) async {
    if (call.ended) {
      return;
    }
    final targets = leaveTargets ?? _leaveTargets(call);
    call
      ..ended = true
      ..endReason = reason;
    if (_call == call) {
      _call = null;
    }
    for (final peer in call.peers.values.toList()) {
      _closeNow(call, peer);
    }
    call
      ..peers.clear()
      ..text.clear();
    credentials.release();
    _emit(
      VoiceCallState(
        phase: VoiceCallPhase.ended,
        roomId: call.roomId,
        endReason: reason,
      ),
    );
    await call.stopWatching();
    if (leave != null) {
      // Advisory: the closing connection is the authoritative signal.
      await _send(
        call,
        VoiceLeave(leave),
        call.join.nextCounter(),
        targets,
        afterEnd: true,
      );
    }
    signalling.forgetJoin(call.join.joinId);
  }

  Future<void> _send(
    _Call call,
    VoiceSignalBody body,
    int counter,
    List<VoiceSignalTarget> targets, {
    bool afterEnd = false,
  }) async {
    if (targets.isEmpty) {
      return;
    }
    final result = await signalling.send(
      roomId: call.roomIdBytes,
      joinId: call.join.joinId,
      counter: counter,
      body: body,
      targets: targets,
    );
    if (afterEnd || call.ended) {
      return;
    }
    if (result case Success(:final value)) {
      for (final delivery in value) {
        if (delivery case VoiceSignalNotSent(:final target, :final reason)) {
          _notSent(call, target.deviceId.toLowerCase(), reason);
        }
      }
    }
  }

  /// What a refused frame says about its target. A device that is not live,
  /// or whose budget this join has spent, is sent nothing more; one whose
  /// safety number changed is closed and says so. Anything else is tried
  /// again by the next attempt.
  void _notSent(_Call call, String deviceId, VoiceSignalRefusal reason) {
    switch (reason) {
      case VoiceSignalRefusal.notLive || VoiceSignalRefusal.budgetExhausted:
        call.silenced.add(deviceId);
      case VoiceSignalRefusal.identityBlocked:
        call.silenced.add(deviceId);
        final peer = call.peers[deviceId];
        if (peer != null) {
          _closeNow(call, peer, keepAs: VoiceParticipantStatus.identityBlocked);
          _emitCall(call);
        }
      case _:
        break;
    }
  }

  void _addText(
    _Call call,
    String userId,
    String deviceId,
    String text, {
    required bool isOwn,
  }) {
    call.text.add(
      VoiceRoomTextEntry(
        senderUserId: userId,
        senderDeviceId: deviceId,
        text: text,
        at: clock.now(),
        isOwn: isOwn,
      ),
    );
    if (call.text.length > roomTextLimit) {
      call.text.removeRange(0, call.text.length - roomTextLimit);
    }
  }

  /// The devices this one is negotiating or connected with, in id order.
  List<_Peer> _inCall(_Call call) => [
    for (final peer in call.peers.values)
      if (peer.connection != null && _isSeated(peer)) peer,
  ]..sort((left, right) => left.deviceId.compareTo(right.deviceId));

  List<VoiceSignalTarget> _leaveTargets(_Call call) => [
    for (final peer in _inCall(call))
      if (!call.silenced.contains(peer.deviceId)) peer.target,
  ];

  Future<Uint8List?> _drawJoinId() async {
    final drawn = await identity.randomIdentifier();
    return switch (drawn) {
      Success(:final value)
          when value.length == VoiceSignalLimits.joinIdBytes =>
        value,
      _ => null,
    };
  }

  Future<RoomState?> _readRoom(String roomId) async {
    final read = await rooms.readRoom(roomId);
    // A room that cannot be read is a room nobody may call in.
    return switch (read) {
      Success(:final value) => value,
      FailureResult() => null,
    };
  }

  /// Every live device of every active member, this account's other devices
  /// included. A member whose devices cannot be authenticated just now is not
  /// announced to.
  Future<Map<String, VoiceSignalTarget>> _resolveTargets(RoomState room) async {
    final targets = <String, VoiceSignalTarget>{};
    for (final member in room.activeMembers) {
      final resolved = await liveDevices.resolveAuthenticatedLiveDevices(
        member.userId,
      );
      if (resolved case Success(:final value)) {
        for (final device in value) {
          if (device.userId == member.userId &&
              device.deviceId != currentDeviceId) {
            targets[device.deviceId] = VoiceSignalTarget(
              userId: device.userId,
              deviceId: device.deviceId,
            );
          }
        }
      }
    }
    return targets;
  }

  VoiceCallEndReason? _refusalFor(RoomState? room) =>
      room != null && RoomAuthorization.mayAct(room, currentUserId)
      ? null
      : _endReasonFor(room);

  VoiceCallEndReason _endReasonFor(RoomState? room) => switch (room) {
    null => VoiceCallEndReason.roomUnavailable,
    RoomState(lifecycle: RoomLifecycle.removed) =>
      VoiceCallEndReason.removedFromRoom,
    RoomState(lifecycle: RoomLifecycle.left) => VoiceCallEndReason.leftRoom,
    RoomState(lifecycle: RoomLifecycle.stateRecoveryRequired) =>
      VoiceCallEndReason.roomWaitingForState,
    RoomState(
      lifecycle: RoomLifecycle.forkQuarantined ||
          RoomLifecycle.controlQuarantined,
    ) =>
      VoiceCallEndReason.roomQuarantined,
    RoomState() => VoiceCallEndReason.removedFromRoom,
  };

  VoiceJoinOutcome _refuse(
    String roomId,
    VoiceCallEndReason reason, {
    DateTime? retryAt,
  }) {
    _emit(
      VoiceCallState(
        phase: VoiceCallPhase.ended,
        roomId: roomId,
        endReason: reason,
        retryAt: retryAt,
      ),
    );
    return VoiceJoinRefused(reason, retryAt: retryAt);
  }

  void _emitCall(_Call call) {
    if (call.ended || _call != call) {
      return;
    }
    _emit(
      VoiceCallState(
        phase: call.joined ? VoiceCallPhase.inCall : VoiceCallPhase.announcing,
        roomId: call.roomId,
        participants: [
          for (final peer in call.peers.values)
            VoiceCallParticipant(
              userId: peer.userId,
              deviceId: peer.deviceId,
              status: peer.status,
              restartingIce: peer.restartingIce,
            ),
        ]..sort((left, right) => left.deviceId.compareTo(right.deviceId)),
        roomText: call.text,
        announcing: call.announcing,
        muted: call.muted,
      ),
    );
  }

  void _emit(VoiceCallState state) {
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  static bool _isCurrent(
    _Call call,
    _Peer peer,
    VoicePeerConnection connection,
  ) =>
      !call.ended &&
      call.peers[peer.deviceId] == peer &&
      identical(peer.connection, connection);

  /// Counts toward the ceiling, and is told what the call says.
  static bool _isSeated(_Peer peer) =>
      peer.status == VoiceParticipantStatus.connecting ||
      peer.status == VoiceParticipantStatus.connected ||
      peer.status == VoiceParticipantStatus.reconnecting;

  /// Sealed nothing further until the user acts: a changed safety number, or
  /// a version this build does not speak.
  static bool _isBarred(VoiceParticipantStatus status) =>
      status == VoiceParticipantStatus.identityBlocked ||
      status == VoiceParticipantStatus.incompatibleVersion;

  Future<T> _serially<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

enum _Announcement { join, query }

/// One call, from the join id to its end.
final class _Call {
  _Call({
    required this.roomId,
    required this.roomIdBytes,
    required this.join,
    required this.credential,
    required Map<String, VoiceSignalTarget> targets,
  }) : targets = Map.of(targets);

  final String roomId;
  final Uint8List roomIdBytes;
  final VoiceLocalJoin join;
  RelayCredential credential;

  /// Every live device of every active member, by device id: whom the
  /// announcements go to.
  final Map<String, VoiceSignalTarget> targets;

  /// This device's peers, by device id: one join of each.
  final peers = <String, _Peer>{};

  /// Joins that ended here, by device id, whose late frames are refused.
  final endedJoins = <String, Set<String>>{};

  /// Devices that answered the query.
  final answered = <String>{};

  /// Devices sent nothing more: not live, blocked, or out of budget.
  final silenced = <String>{};

  final text = <VoiceRoomTextEntry>[];
  int? joinCounter;
  int? queryCounter;
  var joined = false;
  var announcing = true;
  var muted = false;
  var ended = false;
  VoiceCallEndReason? endReason;
  StreamSubscription<RoomState?>? roomWatch;

  Future<void> stopWatching() async {
    await roomWatch?.cancel();
    roomWatch = null;
  }
}

/// One join of one other device.
final class _Peer {
  _Peer({
    required this.userId,
    required this.deviceId,
    required Uint8List joinId,
  }) : joinId = Uint8List.fromList(joinId),
       joinKey = protocolBytesToHex(joinId);

  final String userId;
  final String deviceId;
  final Uint8List joinId;
  final String joinKey;
  var status = VoiceParticipantStatus.connecting;
  VoicePeerConnection? connection;
  StreamSubscription<VoicePeerEvent>? events;

  /// Moves on every new negotiation and every close, so that a retry of an
  /// older one stops.
  var negotiation = 0;
  var everConnected = false;
  var restartingIce = false;

  VoiceSignalTarget get target =>
      VoiceSignalTarget(userId: userId, deviceId: deviceId);

  /// Stops hearing the connection and lets go of it. The caller closes what
  /// comes back.
  VoicePeerConnection? detach() {
    final current = connection;
    connection = null;
    unawaited(events?.cancel());
    events = null;
    return current;
  }
}

Uint8List _hexBytes(String value, int length) {
  if (value.length != length * 2 || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    throw const FormatException('invalid identifier');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
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
