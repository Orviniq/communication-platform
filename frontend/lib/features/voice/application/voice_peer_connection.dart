import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/voice_candidate_batcher.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// This device's join of one call, as each of its connections needs it: the
/// room, the join id this device minted, and the `counter` every message of
/// the join carries.
///
/// One for each join, shared by every connection of it, because the counter is
/// monotonic within a join across all of its messages, whichever device they
/// go to (`voice-signalling-v1.md`, The common body header). The call makes it
/// when it joins and drops it when it leaves.
final class VoiceLocalJoin {
  VoiceLocalJoin({
    required Uint8List roomId,
    required Uint8List joinId,
    required this.deviceId,
  }) : roomId = Uint8List.fromList(roomId),
       joinId = Uint8List.fromList(joinId) {
    if (this.roomId.length != VoiceSignalLimits.roomIdBytes ||
        this.joinId.length != VoiceSignalLimits.joinIdBytes) {
      throw const FormatException('invalid room or join id length');
    }
    protocolUuidBytes(deviceId);
  }

  final Uint8List roomId;
  final Uint8List joinId;

  /// This device.
  final String deviceId;

  var _counter = 0;

  /// The counter of the join's next message: 1 for the first, then one more
  /// each time. A retry carries the counter of the message it retries and
  /// takes none of its own.
  int nextCounter() => _counter += 1;

  @override
  String toString() => 'VoiceLocalJoin(<redacted>)';
}

/// What one connection reports upward.
enum VoicePeerState {
  /// Created, and not yet connected.
  connecting,
  connected,

  /// Lost its path for now. The platform may find it again on its own.
  disconnected,

  /// The path failed, or the platform refused a step of this device's own
  /// negotiation. Nothing here tries again; the call decides.
  failed,

  /// Closed on request, or by the platform. Nothing more happens on it.
  closed,
}

sealed class VoicePeerEvent {
  const VoicePeerEvent();
}

final class VoicePeerStateChanged extends VoicePeerEvent {
  const VoicePeerStateChanged(this.state);

  final VoicePeerState state;
}

/// The offer this device sent has been answered, so sending it again would be
/// a duplicate.
final class VoicePeerAnswered extends VoicePeerEvent {
  const VoicePeerAnswered();
}

/// An ICE restart this device asked for has begun, or has been answered.
final class VoicePeerIceRestart extends VoicePeerEvent {
  const VoicePeerIceRestart({required this.inProgress});

  final bool inProgress;
}

/// A frame this connection sent reached no socket, and why. Nothing is sent
/// again from here: the call decides whether to, and what to tell the user.
final class VoicePeerSignalNotSent extends VoicePeerEvent {
  const VoicePeerSignalNotSent(this.kind, this.reason);

  final VoiceSignalKind kind;
  final VoiceSignalRefusal reason;
}

/// What handing a received message to a connection came to.
enum VoicePeerIntake {
  /// Applied: a description was set, or candidates were taken.
  applied,

  /// A frame already taken: a retry carries its original counter.
  duplicate,

  /// An offer older than one already applied, or an answer to an offer that
  /// is no longer outstanding.
  superseded,

  /// An offer that collided with this device's own, ignored because this
  /// device is the impolite peer. The peer rolls its offer back and answers
  /// this device's instead.
  collisionIgnored,

  /// Not from the device this connection is for (§N rule 6).
  wrongSender,

  /// For another room, another join of the peer, or another join of this
  /// device.
  wrongJoin,

  /// Neither a description nor candidates. The call's, not the connection's.
  notForConnection,

  /// A description that is not one audio section (§N rule 1).
  refusedMedia,

  /// The platform refused it, or could not answer it.
  rejected,

  closed,
}

/// One WebRTC connection between this device and one device of the call.
///
/// **One connection, one audio track.** It takes a hold on the call's local
/// audio from [VoiceLocalAudioPort] and opens one platform connection with the
/// relay configuration of the call's credential. There is no video track and
/// no data channel, and a description that would bring either into being is
/// refused from either side (§N rules 1 and 2).
///
/// **Perfect negotiation** (§N rule 3). Of the two devices, the one whose id
/// string sorts lower is polite. When offers collide, the polite device rolls
/// its own back and answers the other's, and the impolite device ignores the
/// polite one's and waits for its answer. Every step runs in one queue, so a
/// collision is exactly a remote offer arriving while this device's own is
/// outstanding. Who offers first is the call's: the device that receives a
/// `join` negotiates, and the joiner answers (§N rule 4).
///
/// **The channel** (§N rule 6). Each offer, answer and candidate batch goes
/// through the signalling transport, sealed to this device pair's pairwise
/// session. A description or candidate is taken only from the device the
/// session authenticated, for this room, from the peer's join this connection
/// is for, and addressed to this device's own join, because the fingerprint in
/// the SDP is what makes the media path end to end and the server
/// authenticates none of it. Candidates follow the description they belong
/// to, never precede it: a device that has not yet seen an offer has no
/// connection to hold them.
///
/// **An ICE restart keeps the connection** (§N rule 9). [restartIce] applies a
/// newer credential's configuration and offers again with new ICE
/// credentials, and the media keeps its old path until the new one is chosen.
///
/// Nothing here holds a room, announces a join or a leave, or retries on a
/// timer: the call decides whom to negotiate with and when to try again, and
/// [resend] is how it tries. Nothing here logs: an SDP, a candidate and a
/// credential name addresses and keys.
final class VoicePeerConnection {
  VoicePeerConnection._(
    this.join,
    this.peer,
    this._media,
    this._audio,
    this._signalling,
    VoiceSignalTimerPort timer,
  ) : isPolite = isPoliteVoicePeer(
        localDeviceId: join.deviceId,
        remoteDeviceId: peer.deviceId,
      ),
      _peerUserId = protocolUuidBytes(peer.userId),
      _peerDeviceId = protocolUuidBytes(peer.deviceId) {
    _batcher = VoiceCandidateBatcher(flush: _sendCandidates, timer: timer);
    _mediaEvents = _media.events.listen(_onMediaEvent);
  }

  /// Takes a hold on the local audio and opens the platform connection.
  ///
  /// Nothing is sent: the connection waits for [negotiate] or for the peer's
  /// offer. The hold is given back if the platform connection cannot open.
  static Future<Result<VoicePeerConnection>> open({
    required VoiceLocalJoin join,
    required VoicePeerAddress peer,
    required RelayIceConfiguration configuration,
    required VoicePeerMediaPort media,
    required VoiceLocalAudioPort localAudio,
    required VoiceSignallingPort signalling,
    required VoiceSignalTimerPort timer,
  }) async {
    if (peer.deviceId.toLowerCase() == join.deviceId.toLowerCase()) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final held = await localAudio.acquire();
    if (held case FailureResult(:final failure)) {
      return Result.failure(failure);
    }
    final audio = (held as Success<VoiceLocalAudio>).value;
    final opened = await media.open(configuration: configuration, audio: audio);
    if (opened case FailureResult(:final failure)) {
      await audio.release();
      return Result.failure(failure);
    }
    return Result.success(
      VoicePeerConnection._(
        join,
        peer,
        (opened as Success<VoicePeerMedia>).value,
        audio,
        signalling,
        timer,
      ),
    );
  }

  /// Candidates held while no remote description has been applied.
  static const heldCandidateLimit = 32;

  /// Received counters remembered to drop a retry's duplicate. A join seals at
  /// most 32 frames to one device, so this holds all of them.
  static const _rememberedCounters = 64;

  final VoiceLocalJoin join;
  final VoicePeerAddress peer;

  /// Whether this device rolls back when offers collide.
  final bool isPolite;

  final VoicePeerMedia _media;
  final VoiceLocalAudio _audio;
  final VoiceSignallingPort _signalling;
  final Uint8List _peerUserId;
  final Uint8List _peerDeviceId;
  late final VoiceCandidateBatcher _batcher;
  late final StreamSubscription<VoicePeerMediaEvent> _mediaEvents;
  final _events = StreamController<VoicePeerEvent>.broadcast();

  var _state = VoicePeerState.connecting;
  var _signaling = _Signaling.stable;
  var _negotiationStarted = false;
  var _hasRemoteDescription = false;
  _SentDescription? _localOffer;
  _SentDescription? _localAnswer;
  int? _lastRemoteOffer;
  final _seenCounters = <int>{};
  final _heldCandidates = ListQueue<VoiceIceCandidate>();

  /// A restart this device still has to offer.
  var _restartWanted = false;

  /// A restart this device asked for and has not yet had answered.
  var _restarting = false;

  /// The ICE generation of the local description applied last, whose
  /// candidates are this negotiation's. Null after a rollback, until the next
  /// local description: whatever the rolled-back offer gathers is no one's.
  ///
  /// Candidates are matched on it rather than on the platform's gathering
  /// events, because libwebrtc does not mark a new generation reliably: a
  /// restart whose predecessor is still gathering emits no new `gathering`,
  /// and a session it stops can still report `complete`.
  String? _localUfrag;

  /// Whether a candidate of [_localUfrag] has arrived, so that a completion
  /// can be this generation's rather than a stopped one's.
  var _gatheredThisGeneration = false;

  /// Completes once the description of the current negotiation has been handed
  /// to the transport, so that no candidate of it goes first.
  var _described = Completer<void>()..complete();

  var _failedLocally = false;
  var _closed = false;
  Future<void> _turn = Future<void>.value();

  /// Every event, in order. Nothing is replayed to a late listener.
  Stream<VoicePeerEvent> get events => _events.stream;

  VoicePeerState get state => _state;

  /// Whether a restart this device asked for is still waiting for its answer.
  bool get isRestartingIce => _restarting;

  /// Sends this device's offer, which is what a participant does when a device
  /// joins (§N rule 4).
  ///
  /// Does nothing once negotiation has begun from either side: an offer this
  /// device already sent, or one it answered, is the connection's one
  /// negotiation, and a second would only renegotiate what is already agreed.
  Future<void> negotiate() {
    if (_closed || _negotiationStarted) {
      return Future<void>.value();
    }
    _negotiationStarted = true;
    return _serially(() => _offer(iceRestart: false));
  }

  /// Sends the unanswered offer, or the answer last sent, once more, with the
  /// counter it first carried, so that a peer that already has it drops the
  /// copy. The frame is sealed afresh on the next message number (§N rule 7).
  ///
  /// Returns what was sent, or null when there is nothing to send again.
  Future<VoiceSignalKind?> resend() => _serially(() async {
    if (_closed || _failedLocally) {
      return null;
    }
    final offer = _localOffer;
    if (_signaling == _Signaling.haveLocalOffer && offer != null) {
      await _send(
        VoiceOffer(targetJoinId: peer.joinId, sdp: offer.description.sdp),
        offer.counter,
      );
      return VoiceSignalKind.offer;
    }
    final answer = _localAnswer;
    if (answer != null) {
      await _send(
        VoiceAnswer(
          targetJoinId: peer.joinId,
          sdp: answer.description.sdp,
          answersCounter: answer.answers!,
        ),
        answer.counter,
      );
      return VoiceSignalKind.answer;
    }
    return null;
  });

  /// Takes one message the signalling transport accepted.
  ///
  /// The call routes to this connection the frames of this peer's join; this
  /// checks them again against what the pairwise session authenticated, and
  /// takes nothing else.
  Future<VoicePeerIntake> receive(ReceivedVoiceSignal signal) {
    if (_closed) {
      return Future.value(VoicePeerIntake.closed);
    }
    final message = signal.message;
    final header = message.header;
    if (!_isPeer(signal.senderUserId, signal.senderDeviceId) ||
        !_same(header.senderUserId, _peerUserId) ||
        !_same(header.senderDeviceId, _peerDeviceId)) {
      return Future.value(VoicePeerIntake.wrongSender);
    }
    if (!_same(header.roomId, join.roomId) ||
        !_same(header.joinId, peer.joinId)) {
      return Future.value(VoicePeerIntake.wrongJoin);
    }
    final body = message.body;
    final targetJoinId = switch (body) {
      VoiceOffer(:final targetJoinId) => targetJoinId,
      VoiceAnswer(:final targetJoinId) => targetJoinId,
      VoiceCandidates(:final targetJoinId) => targetJoinId,
      _ => null,
    };
    if (targetJoinId == null) {
      return Future.value(VoicePeerIntake.notForConnection);
    }
    if (!_same(targetJoinId, join.joinId)) {
      // Addressed to an incarnation of this device that has ended.
      return Future.value(VoicePeerIntake.wrongJoin);
    }
    if (!_remember(header.counter)) {
      return Future.value(VoicePeerIntake.duplicate);
    }
    return _serially(
      () => switch (body) {
        final VoiceOffer offer => _takeOffer(offer, header.counter),
        final VoiceAnswer answer => _takeAnswer(answer),
        final VoiceCandidates batch => _takeCandidates(batch),
        _ => Future.value(VoicePeerIntake.notForConnection),
      },
    );
  }

  /// Applies [configuration], a newer credential's, and restarts ICE, without
  /// closing the connection (§N rule 9).
  ///
  /// The restart is offered at once when the connection is stable, and after
  /// the answer when an offer is outstanding. Before anything has been
  /// negotiated there is nothing to restart: the first gathering uses the new
  /// configuration.
  Future<Result<void>> restartIce(RelayIceConfiguration configuration) =>
      _serially(() async {
        if (_closed || _failedLocally) {
          return const Result.failure(
            CancellationFailure(CancellationFailureKind.lifecycleInterrupted),
          );
        }
        final applied = await _media.setConfiguration(configuration);
        if (applied case FailureResult(:final failure)) {
          return Result.failure(failure);
        }
        if (_closed) {
          return const Result.success(null);
        }
        if (!_hasRemoteDescription && _signaling == _Signaling.stable) {
          return const Result.success(null);
        }
        _restartWanted = true;
        _setRestarting(true);
        if (_signaling == _Signaling.stable) {
          await _offer(iceRestart: true);
        }
        return const Result.success(null);
      });

  /// Closes the connection at once and gives back its hold on the local
  /// audio. Safe to call more than once.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _heldCandidates.clear();
    _batcher.restart();
    if (!_described.isCompleted) {
      _described.complete();
    }
    _state = VoicePeerState.closed;
    _events.add(const VoicePeerStateChanged(VoicePeerState.closed));
    await _mediaEvents.cancel();
    await _media.close();
    await _audio.release();
    await _events.close();
  }

  Future<void> _offer({required bool iceRestart}) async {
    if (_closed || _failedLocally || _signaling != _Signaling.stable) {
      return;
    }
    if (!iceRestart && _hasRemoteDescription) {
      // The peer's offer was taken while this one waited its turn, so the
      // connection's one negotiation already happened.
      return;
    }
    if (iceRestart) {
      _restartWanted = false;
      if (await _media.restartIce() case FailureResult()) {
        _failLocally();
        return;
      }
    }
    final created = await _media.createOffer();
    if (_closed) {
      return;
    }
    if (created case FailureResult()) {
      _failLocally();
      return;
    }
    final offer = (created as Success<VoiceSessionDescription>).value;
    if (offer.type != VoiceDescriptionType.offer || !offer.isAudioOnly) {
      _failLocally();
      return;
    }
    _beginDescription(offer);
    try {
      if (await _media.setLocalDescription(offer) case FailureResult()) {
        _failLocally();
        return;
      }
      if (_closed) {
        return;
      }
      _signaling = _Signaling.haveLocalOffer;
      final sent = _SentDescription(
        offer,
        counter: join.nextCounter(),
        isRestart: iceRestart,
      );
      _localOffer = sent;
      _localAnswer = null;
      await _send(
        VoiceOffer(targetJoinId: peer.joinId, sdp: offer.sdp),
        sent.counter,
      );
    } finally {
      _endDescription();
    }
  }

  Future<VoicePeerIntake> _takeOffer(VoiceOffer offer, int counter) async {
    if (_closed) {
      return VoicePeerIntake.closed;
    }
    if (_failedLocally) {
      return VoicePeerIntake.rejected;
    }
    final last = _lastRemoteOffer;
    if (last != null && counter < last) {
      return VoicePeerIntake.superseded;
    }
    final description = VoiceSessionDescription(
      type: VoiceDescriptionType.offer,
      sdp: offer.sdp,
    );
    if (!description.isAudioOnly) {
      return VoicePeerIntake.refusedMedia;
    }
    if (_signaling == _Signaling.haveLocalOffer) {
      if (!isPolite) {
        return VoicePeerIntake.collisionIgnored;
      }
      if (await _media.rollbackLocalOffer() case FailureResult()) {
        _failLocally();
        return VoicePeerIntake.rejected;
      }
      if (_closed) {
        return VoicePeerIntake.closed;
      }
      _signaling = _Signaling.stable;
      if (_localOffer?.isRestart ?? false) {
        // Rolled back, so still owed; offered again once this is answered.
        _restartWanted = true;
      }
      _localOffer = null;
      // Whatever the rolled-back offer gathered belongs to no negotiation.
      _batcher.restart();
      _localUfrag = null;
      _gatheredThisGeneration = false;
    }
    final applied = await _media.setRemoteDescription(description);
    if (_closed) {
      return VoicePeerIntake.closed;
    }
    if (applied case FailureResult()) {
      return VoicePeerIntake.rejected;
    }
    _signaling = _Signaling.haveRemoteOffer;
    _hasRemoteDescription = true;
    _negotiationStarted = true;
    _lastRemoteOffer = counter;
    await _applyHeldCandidates();
    if (!await _answer(counter)) {
      return _closed ? VoicePeerIntake.closed : VoicePeerIntake.rejected;
    }
    if (_restartWanted) {
      unawaited(_serially(() => _offer(iceRestart: true)));
    }
    return VoicePeerIntake.applied;
  }

  Future<bool> _answer(int offerCounter) async {
    final created = await _media.createAnswer();
    if (_closed) {
      return false;
    }
    if (created case FailureResult()) {
      _failLocally();
      return false;
    }
    final answer = (created as Success<VoiceSessionDescription>).value;
    if (answer.type != VoiceDescriptionType.answer || !answer.isAudioOnly) {
      _failLocally();
      return false;
    }
    _beginDescription(answer);
    try {
      if (await _media.setLocalDescription(answer) case FailureResult()) {
        _failLocally();
        return false;
      }
      if (_closed) {
        return false;
      }
      _signaling = _Signaling.stable;
      final sent = _SentDescription(
        answer,
        counter: join.nextCounter(),
        answers: offerCounter,
      );
      _localAnswer = sent;
      await _send(
        VoiceAnswer(
          targetJoinId: peer.joinId,
          sdp: answer.sdp,
          answersCounter: offerCounter,
        ),
        sent.counter,
      );
      return true;
    } finally {
      _endDescription();
    }
  }

  Future<VoicePeerIntake> _takeAnswer(VoiceAnswer answer) async {
    if (_closed) {
      return VoicePeerIntake.closed;
    }
    final outstanding = _localOffer;
    if (_signaling != _Signaling.haveLocalOffer ||
        outstanding == null ||
        answer.answersCounter != outstanding.counter) {
      return VoicePeerIntake.superseded;
    }
    final description = VoiceSessionDescription(
      type: VoiceDescriptionType.answer,
      sdp: answer.sdp,
    );
    if (!description.isAudioOnly) {
      return VoicePeerIntake.refusedMedia;
    }
    final applied = await _media.setRemoteDescription(description);
    if (_closed) {
      return VoicePeerIntake.closed;
    }
    if (applied case FailureResult()) {
      return VoicePeerIntake.rejected;
    }
    _signaling = _Signaling.stable;
    _hasRemoteDescription = true;
    _localOffer = null;
    await _applyHeldCandidates();
    _emit(const VoicePeerAnswered());
    if (_restartWanted) {
      unawaited(_serially(() => _offer(iceRestart: true)));
    } else if (outstanding.isRestart) {
      _setRestarting(false);
    }
    return VoicePeerIntake.applied;
  }

  Future<VoicePeerIntake> _takeCandidates(VoiceCandidates batch) async {
    if (_closed) {
      return VoicePeerIntake.closed;
    }
    if (!_hasRemoteDescription) {
      // Before any remote description the platform drops a candidate.
      for (final candidate in batch.candidates) {
        if (_heldCandidates.length == heldCandidateLimit) {
          _heldCandidates.removeFirst();
        }
        _heldCandidates.addLast(candidate);
      }
      return VoicePeerIntake.applied;
    }
    for (final candidate in batch.candidates) {
      // A refusal is one candidate the path does without: a stale one from a
      // negotiation that was rolled back or restarted.
      await _media.addRemoteCandidate(candidate);
      if (_closed) {
        return VoicePeerIntake.closed;
      }
    }
    return VoicePeerIntake.applied;
  }

  Future<void> _applyHeldCandidates() async {
    while (_heldCandidates.isNotEmpty && !_closed) {
      await _media.addRemoteCandidate(_heldCandidates.removeFirst());
    }
  }

  Future<void> _sendCandidates(
    List<VoiceIceCandidate> candidates, {
    required bool end,
  }) async {
    await _described.future;
    if (_closed) {
      return;
    }
    await _send(
      VoiceCandidates(
        targetJoinId: peer.joinId,
        candidates: candidates,
        end: end,
      ),
      join.nextCounter(),
    );
  }

  Future<void> _send(VoiceSignalBody body, int counter) async {
    final result = await _signalling.send(
      roomId: join.roomId,
      joinId: join.joinId,
      counter: counter,
      body: body,
      targets: [
        VoiceSignalTarget(userId: peer.userId, deviceId: peer.deviceId),
      ],
    );
    final refusal = switch (result) {
      // Nothing could be sealed: a message that fits no frame.
      FailureResult() => VoiceSignalRefusal.sealFailed,
      Success(:final value) when value.length != 1 =>
        VoiceSignalRefusal.sealFailed,
      Success(:final value) => switch (value.single) {
        VoiceSignalSent() => null,
        VoiceSignalNotSent(:final reason) => reason,
      },
    };
    if (refusal != null) {
      _emit(VoicePeerSignalNotSent(body.kind, refusal));
    }
  }

  /// [description] is about to be applied locally: its candidates start a
  /// batch of their own, and wait until it has been sent.
  void _beginDescription(VoiceSessionDescription description) {
    _batcher.restart();
    _localUfrag = description.iceUfrag;
    _gatheredThisGeneration = false;
    if (!_described.isCompleted) {
      _described.complete();
    }
    _described = Completer<void>();
  }

  void _endDescription() {
    if (!_described.isCompleted) {
      _described.complete();
    }
  }

  void _onMediaEvent(VoicePeerMediaEvent event) {
    if (_closed) {
      return;
    }
    switch (event) {
      case VoiceLocalCandidateGathered(:final candidate):
        final current = _localUfrag;
        final ufrag = iceUfragOfCandidate(candidate.candidate);
        if (current == null || (ufrag != null && ufrag != current)) {
          // Gathered for a description that was rolled back or restarted.
          return;
        }
        _gatheredThisGeneration = true;
        _batcher.add(candidate);
      case VoiceCandidateGatheringComplete():
        if (_gatheredThisGeneration) {
          _gatheredThisGeneration = false;
          unawaited(_batcher.complete());
        }
      case VoiceMediaStateChanged(:final state):
        _onMediaState(state);
    }
  }

  void _onMediaState(VoiceMediaState state) {
    if (state == VoiceMediaState.closed) {
      unawaited(close());
      return;
    }
    if (_failedLocally) {
      return;
    }
    _setState(switch (state) {
      VoiceMediaState.fresh ||
      VoiceMediaState.connecting => VoicePeerState.connecting,
      VoiceMediaState.connected => VoicePeerState.connected,
      VoiceMediaState.disconnected => VoicePeerState.disconnected,
      VoiceMediaState.failed => VoicePeerState.failed,
      VoiceMediaState.closed => VoicePeerState.closed,
    });
  }

  /// The platform refused a step of this device's own negotiation. The
  /// connection cannot go on, and says so; the call closes it.
  void _failLocally() {
    if (_closed) {
      return;
    }
    _failedLocally = true;
    _restartWanted = false;
    _setRestarting(false);
    _setState(VoicePeerState.failed);
  }

  void _setState(VoicePeerState next) {
    if (_closed || next == _state) {
      return;
    }
    _state = next;
    _emit(VoicePeerStateChanged(next));
  }

  void _setRestarting(bool restarting) {
    if (restarting == _restarting) {
      return;
    }
    _restarting = restarting;
    _emit(VoicePeerIceRestart(inProgress: restarting));
  }

  void _emit(VoicePeerEvent event) {
    if (!_closed) {
      _events.add(event);
    }
  }

  bool _remember(int counter) {
    if (!_seenCounters.add(counter)) {
      return false;
    }
    if (_seenCounters.length > _rememberedCounters) {
      _seenCounters.remove(_seenCounters.first);
    }
    return true;
  }

  bool _isPeer(String userId, String deviceId) {
    try {
      return _same(protocolUuidBytes(userId), _peerUserId) &&
          _same(protocolUuidBytes(deviceId), _peerDeviceId);
    } on FormatException {
      return false;
    }
  }

  Future<T> _serially<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

enum _Signaling { stable, haveLocalOffer, haveRemoteOffer }

/// An offer or answer this device sent, kept so that it can be sent again
/// under its original counter.
final class _SentDescription {
  const _SentDescription(
    this.description, {
    required this.counter,
    this.isRestart = false,
    this.answers,
  });

  final VoiceSessionDescription description;
  final int counter;
  final bool isRestart;

  /// For an answer, the counter of the offer it answers.
  final int? answers;
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
