import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// A description shaped the way libwebrtc shapes one, with one section of
/// each of [sections]: audio alone unless a test asks for more.
String fakeSdp({
  required VoiceDescriptionType type,
  required String ufrag,
  List<String> sections = const ['audio'],
}) {
  final buffer = StringBuffer()
    ..write('v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n')
    ..write('s=-\r\nt=0 0\r\n')
    ..write(
      'a=group:BUNDLE '
      '${[for (var index = 0; index < sections.length; index += 1) index].join(' ')}'
      '\r\n',
    );
  for (var index = 0; index < sections.length; index += 1) {
    final media = sections[index];
    buffer
      ..write(
        media == 'application'
            ? 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
            : 'm=$media 9 UDP/TLS/RTP/SAVPF 111\r\n',
      )
      ..write('c=IN IP4 0.0.0.0\r\n')
      ..write('a=ice-ufrag:$ufrag\r\n')
      ..write('a=ice-pwd:${ufrag}IcePasswordIcePassword\r\n')
      ..write(
        'a=fingerprint:sha-256 4E:5B:27:32:9A:2C:84:0B:67:AF:1B:2B:4B:5F:D4:77:'
        '3D:4F:08:6A:37:B1:9C:E5:9E:22:6F:05:4A:1C:0B:7E\r\n',
      )
      ..write(
        'a=setup:${type == VoiceDescriptionType.offer ? 'actpass' : 'active'}'
        '\r\n',
      )
      ..write('a=mid:$index\r\na=sendrecv\r\na=rtcp-mux\r\n');
    if (media != 'application') {
      buffer.write('a=rtpmap:111 opus/48000/2\r\n');
    }
  }
  return buffer.toString();
}

/// The ICE user fragment a description names.
String? ufragOf(String sdp) =>
    RegExp(r'a=ice-ufrag:([^\r\n]+)').firstMatch(sdp)?.group(1);

/// A relay candidate for the ICE generation [ufrag] names, on a documentation
/// address.
VoiceIceCandidate fakeRelayCandidate(String ufrag) => VoiceIceCandidate(
  candidate:
      'candidate:1 1 udp 41885439 198.51.100.7 50000 typ relay raddr 0.0.0.0 '
      'rport 0 generation 0 ufrag $ufrag network-cost 999',
  mid: '0',
  mline: 0,
);

enum FakeSignalingState { stable, haveLocalOffer, haveRemoteOffer, closed }

/// The platform connection, modelled on libwebrtc's signalling state machine.
///
/// It refuses a step out of order exactly where libwebrtc does, and it does
/// no implicit rollback: a remote offer while a local one is pending is
/// refused, as it is when `enableImplicitRollback` is false. Setting a local
/// description that starts a new ICE generation gathers one relay candidate
/// and completes, and the connection reports `connected` once it holds a
/// remote candidate of the generation the peer's description names.
final class FakePeerMedia implements VoicePeerMedia {
  FakePeerMedia({required this.name, required this.audio});

  final String name;
  final VoiceLocalAudio audio;

  /// Every configuration the connection was given: the first at open.
  final configurations = <RelayIceConfiguration>[];

  /// Every step asked of it, by name, in order.
  final calls = <String>[];

  final remoteDescriptionsApplied = <VoiceSessionDescription>[];
  final remoteCandidates = <VoiceIceCandidate>[];
  final _events = StreamController<VoicePeerMediaEvent>.broadcast();

  var signalingState = FakeSignalingState.stable;
  VoiceSessionDescription? currentLocal;
  VoiceSessionDescription? currentRemote;
  VoiceSessionDescription? pendingLocal;
  VoiceSessionDescription? pendingRemote;

  /// Steps that fail, by name.
  final failing = <String>{};

  /// Whether a new ICE generation gathers on its own.
  var autoGather = true;

  /// The ICE credentials the next description carries, unless it restarts.
  var generation = 1;
  var restarts = 0;
  var rollbacks = 0;
  var closed = false;
  var _lastGeneration = 1;
  int? _pendingLocalGeneration;
  int? _currentLocalGeneration;
  var _restartRequested = false;
  String? _gatheredUfrag;
  String? _connectedUfrag;

  String get ufrag => '${name}g$generation';

  /// New ICE credentials, never used before, as libwebrtc draws them.
  void _freshCredentials() => generation = _lastGeneration += 1;

  @override
  Stream<VoicePeerMediaEvent> get events => _events.stream;

  void emit(VoicePeerMediaEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  /// Gathers [candidates] for the current generation and completes.
  void gather([List<VoiceIceCandidate>? candidates]) {
    for (final candidate in candidates ?? [fakeRelayCandidate(ufrag)]) {
      emit(VoiceLocalCandidateGathered(candidate));
    }
    emit(const VoiceCandidateGatheringComplete());
  }

  @override
  Future<Result<VoiceSessionDescription>> createOffer() async {
    if (_refused('createOffer') ||
        signalingState == FakeSignalingState.haveRemoteOffer) {
      return const Result.failure(_unable);
    }
    if (_restartRequested) {
      _restartRequested = false;
      _freshCredentials();
    }
    return Result.success(
      VoiceSessionDescription(
        type: VoiceDescriptionType.offer,
        sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: ufrag),
      ),
    );
  }

  @override
  Future<Result<VoiceSessionDescription>> createAnswer() async {
    final remote = pendingRemote;
    if (_refused('createAnswer') ||
        signalingState != FakeSignalingState.haveRemoteOffer ||
        remote == null) {
      return const Result.failure(_unable);
    }
    final previous = currentRemote;
    if (previous != null && ufragOf(previous.sdp) != ufragOf(remote.sdp)) {
      // The peer restarted ICE, so this side answers with new credentials,
      // and a restart it still owed is done.
      _freshCredentials();
      _restartRequested = false;
    }
    return Result.success(
      VoiceSessionDescription(
        type: VoiceDescriptionType.answer,
        sdp: fakeSdp(type: VoiceDescriptionType.answer, ufrag: ufrag),
      ),
    );
  }

  @override
  Future<Result<void>> setLocalDescription(
    VoiceSessionDescription description,
  ) async {
    if (_refused('setLocalDescription')) {
      return const Result.failure(_unable);
    }
    switch ((description.type, signalingState)) {
      case (VoiceDescriptionType.offer, FakeSignalingState.stable):
      case (VoiceDescriptionType.offer, FakeSignalingState.haveLocalOffer):
        pendingLocal = description;
        _pendingLocalGeneration = generation;
        signalingState = FakeSignalingState.haveLocalOffer;
      case (VoiceDescriptionType.answer, FakeSignalingState.haveRemoteOffer):
        currentLocal = description;
        _currentLocalGeneration = generation;
        currentRemote = pendingRemote;
        pendingRemote = null;
        signalingState = FakeSignalingState.stable;
      default:
        return const Result.failure(_unable);
    }
    _gatherIfNew(description);
    _connectIfReady();
    return const Result.success(null);
  }

  @override
  Future<Result<void>> rollbackLocalOffer() async {
    if (_refused('rollbackLocalOffer') ||
        signalingState != FakeSignalingState.haveLocalOffer) {
      return const Result.failure(_unable);
    }
    rollbacks += 1;
    pendingLocal = null;
    signalingState = FakeSignalingState.stable;
    final current = _currentLocalGeneration;
    if (current == null) {
      // The initial offer's transport goes with it, and the answer gathers
      // on a new one with new credentials.
      _freshCredentials();
    } else if (_pendingLocalGeneration != current) {
      // A restart offer rolled back: the credentials in use are the current
      // ones again, and the restart is still owed.
      generation = current;
      _restartRequested = true;
    }
    return const Result.success(null);
  }

  @override
  Future<Result<void>> setRemoteDescription(
    VoiceSessionDescription description,
  ) async {
    if (_refused('setRemoteDescription')) {
      return const Result.failure(_peerRefused);
    }
    switch ((description.type, signalingState)) {
      case (VoiceDescriptionType.offer, FakeSignalingState.stable):
        pendingRemote = description;
        signalingState = FakeSignalingState.haveRemoteOffer;
      case (VoiceDescriptionType.answer, FakeSignalingState.haveLocalOffer):
        currentRemote = description;
        currentLocal = pendingLocal;
        _currentLocalGeneration = _pendingLocalGeneration;
        pendingLocal = null;
        signalingState = FakeSignalingState.stable;
      default:
        // Including an offer in have-local-offer: no implicit rollback.
        return const Result.failure(_peerRefused);
    }
    remoteDescriptionsApplied.add(description);
    _connectIfReady();
    return const Result.success(null);
  }

  @override
  Future<Result<void>> addRemoteCandidate(VoiceIceCandidate candidate) async {
    if (_refused('addRemoteCandidate') ||
        (currentRemote == null && pendingRemote == null)) {
      // libwebrtc drops a candidate that arrives before any remote
      // description.
      return const Result.failure(_peerRefused);
    }
    remoteCandidates.add(candidate);
    _connectIfReady();
    return const Result.success(null);
  }

  @override
  Future<Result<void>> setConfiguration(
    RelayIceConfiguration configuration,
  ) async {
    if (_refused('setConfiguration')) {
      return const Result.failure(_unable);
    }
    configurations.add(configuration);
    return const Result.success(null);
  }

  @override
  Future<Result<void>> restartIce() async {
    if (_refused('restartIce')) {
      return const Result.failure(_unable);
    }
    restarts += 1;
    _restartRequested = true;
    return const Result.success(null);
  }

  @override
  Future<void> close() async {
    calls.add('close');
    if (closed) {
      return;
    }
    closed = true;
    signalingState = FakeSignalingState.closed;
    await _events.close();
  }

  bool _refused(String step) {
    calls.add(step);
    return closed || failing.contains(step);
  }

  void _gatherIfNew(VoiceSessionDescription local) {
    final generationUfrag = ufragOf(local.sdp)!;
    if (!autoGather || generationUfrag == _gatheredUfrag) {
      return;
    }
    _gatheredUfrag = generationUfrag;
    gather([fakeRelayCandidate(generationUfrag)]);
  }

  void _connectIfReady() {
    final remote = currentRemote;
    if (signalingState != FakeSignalingState.stable ||
        currentLocal == null ||
        remote == null) {
      return;
    }
    final remoteUfrag = ufragOf(remote.sdp);
    final reachable = remoteCandidates.any(
      (candidate) =>
          candidate.candidate.endsWith('ufrag $remoteUfrag network-cost 999'),
    );
    if (!reachable || remoteUfrag == _connectedUfrag) {
      return;
    }
    // A restart keeps the media on its old path until the new one is chosen,
    // so a connection that is already connected reports nothing new.
    final first = _connectedUfrag == null;
    _connectedUfrag = remoteUfrag;
    if (first) {
      emit(const VoiceMediaStateChanged(VoiceMediaState.connected));
    }
  }
}

const _unable = UnsupportedProtocolFailure(
  UnsupportedProtocolFailureKind.capability,
);
const _peerRefused = ValidationFailure(ValidationFailureKind.invalidInput);

/// Opens [FakePeerMedia], and records every one it opened.
final class FakePeerMediaPort implements VoicePeerMediaPort {
  FakePeerMediaPort(this.name);

  final String name;
  final opened = <FakePeerMedia>[];
  var refuse = false;

  @override
  Future<Result<VoicePeerMedia>> open({
    required RelayIceConfiguration configuration,
    required VoiceLocalAudio audio,
  }) async {
    if (refuse) {
      return const Result.failure(_unable);
    }
    final media = FakePeerMedia(name: '$name${opened.length}', audio: audio)
      ..configurations.add(configuration);
    opened.add(media);
    return Result.success(media);
  }
}

/// The microphone: every hold it gave, whether each was given back, and every
/// change of mute in order.
final class FakeLocalAudioPort implements VoiceLocalAudioPort {
  final holds = <FakeLocalAudio>[];
  final mutes = <bool>[];
  var refuse = false;

  int get live => holds.where((hold) => !hold.released).length;

  bool get muted => mutes.isNotEmpty && mutes.last;

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);

  @override
  Future<Result<VoiceLocalAudio>> acquire() async {
    if (refuse) {
      return const Result.failure(_unable);
    }
    final hold = FakeLocalAudio();
    holds.add(hold);
    return Result.success(hold);
  }
}

final class FakeLocalAudio implements VoiceLocalAudio {
  var released = false;
  var releases = 0;

  @override
  Future<void> release() async {
    releases += 1;
    released = true;
  }
}

/// One message a connection handed to the transport.
final class SentPeerSignal {
  const SentPeerSignal({required this.message, required this.target});

  final VoiceSignalMessage message;
  final VoiceSignalTarget target;

  VoiceSignalKind get kind => message.kind;
  int get counter => message.header.counter;
}

/// One device's end of the signalling transport between faked devices: every
/// message is recorded as the transport would have sealed it, and held until
/// the test delivers it.
final class FakePeerSignalling implements VoiceSignallingPort {
  FakePeerSignalling({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
  final sent = <SentPeerSignal>[];

  /// When set, every target is refused for this reason.
  VoiceSignalRefusal? refuseWith;

  /// A send of one of these kinds waits until its completer completes.
  final holds = <VoiceSignalKind, Completer<void>>{};
  var _delivered = 0;

  bool get hasUndelivered => _delivered < sent.length;

  /// The messages not yet taken, in the order they were sent.
  List<SentPeerSignal> takeUndelivered() {
    final taken = sent.sublist(_delivered);
    _delivered = sent.length;
    return taken;
  }

  @override
  Stream<InboundVoiceSignal> get inbound => const Stream.empty();

  @override
  void forgetJoin(Uint8List joinId) {}

  @override
  Future<Result<List<VoiceSignalDelivery>>> send({
    required Uint8List roomId,
    required Uint8List joinId,
    required int counter,
    required VoiceSignalBody body,
    required List<VoiceSignalTarget> targets,
  }) async {
    final hold = holds[body.kind];
    if (hold != null) {
      await hold.future;
    }
    final message = VoiceSignalMessage(
      header: VoiceSignalHeader(
        roomId: roomId,
        joinId: joinId,
        senderUserId: protocolUuidBytes(userId),
        senderDeviceId: protocolUuidBytes(deviceId),
        counter: counter,
        createdMs: 0,
      ),
      body: body,
    );
    final refusal = refuseWith;
    final deliveries = <VoiceSignalDelivery>[];
    for (final target in targets) {
      if (refusal != null) {
        deliveries.add(VoiceSignalNotSent(target, refusal));
      } else {
        sent.add(SentPeerSignal(message: message, target: target));
        deliveries.add(VoiceSignalSent(target));
      }
    }
    return Result.success(deliveries);
  }
}

/// A received message as the transport hands it on: its sender is the device
/// the pairwise session authenticated, [userId] and [deviceId].
ReceivedVoiceSignal received(
  VoiceSignalMessage message, {
  required String userId,
  required String deviceId,
}) => ReceivedVoiceSignal(
  senderUserId: userId,
  senderDeviceId: deviceId,
  message: message,
);

Uint8List filled(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));

/// Lets every pending microtask and event run.
Future<void> settle() async {
  for (var turn = 0; turn < 30; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
