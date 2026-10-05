import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:communication_platform/features/voice/infrastructure/flutter_webrtc_local_audio.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The platform configuration of a call's connection: the relay servers of
/// [configuration] and nothing else, under the `relay` transport policy
/// (§N rule 2).
///
/// **Secret-bearing**, because every server carries the credential. It goes to
/// the platform and nowhere else.
///
/// It is the whole configuration every time, for the connection and for each
/// ICE restart alike, because `flutter_webrtc`'s `setConfiguration` builds a
/// fresh `RTCConfiguration` from what it is given: a field left out returns to
/// libwebrtc's default, and that default is `IceTransportsType.ALL` (read from
/// `PeerConnection$RTCConfiguration` in libwebrtc 150.7871.01).
///
/// - `max-bundle` and `rtcp-mux` put the one audio section on one transport,
///   so ICE gathers one relay candidate for each `turn:` URL — the shape the
///   offer's size was measured in (`voice-signalling-v1.md`, Sizes).
/// - `gather_once` is libwebrtc's default, stated because the candidate
///   batching waits for gathering to complete.
Map<String, Object> voiceRtcConfiguration(
  RelayIceConfiguration configuration,
) => <String, Object>{
  'iceServers': <Map<String, Object>>[
    for (final server in configuration.servers)
      <String, Object>{
        'urls': <String>[server.url],
        'username': server.username,
        'credential': server.credential,
      },
  ],
  'iceTransportPolicy': switch (configuration.transportPolicy) {
    IceTransportPolicy.relay => 'relay',
  },
  'bundlePolicy': 'max-bundle',
  'rtcpMuxPolicy': 'require',
  'sdpSemantics': 'unified-plan',
  'continualGatheringPolicy': 'gather_once',
};

/// What an offer and an answer are created with: audio, and no video.
///
/// `flutter_webrtc`'s own default asks to receive video, and libwebrtc meets
/// that legacy option under Unified Plan by adding a receive-only video
/// transceiver to the offer. Answers ignore both options; they are passed
/// there too so that no call of this adapter asks for video.
const voiceSdpConstraints = <String, Object>{
  'mandatory': <String, Object>{
    'OfferToReceiveAudio': true,
    'OfferToReceiveVideo': false,
  },
  'optional': <Object>[],
};

/// The call's connections on `flutter_webrtc` 1.6.2+hotfix.3 (ADR-078).
///
/// Each connection has the one audio track of its hold, added with
/// `addTrack`, and nothing else: no transceiver is added and no data channel
/// is created, and one the peer opened would be closed on arrival — though
/// none can open, because a description with an application section is never
/// applied.
///
/// Every refusal is a typed failure with no text. `flutter_webrtc` rethrows a
/// platform refusal as a string carrying the platform's message, and libwebrtc
/// quotes the description line it could not parse, so the text is an SDP
/// fragment and is dropped where it is caught.
final class FlutterWebrtcPeerMedia implements VoicePeerMediaPort {
  const FlutterWebrtcPeerMedia();

  @override
  Future<Result<VoicePeerMedia>> open({
    required RelayIceConfiguration configuration,
    required VoiceLocalAudio audio,
  }) async {
    if (audio is! FlutterWebrtcLocalAudio || audio.isReleased) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    RTCPeerConnection? connection;
    try {
      connection = await createPeerConnection(
        voiceRtcConfiguration(configuration),
      );
      await connection.addTrack(audio.track, audio.stream);
      return Result.success(_FlutterWebrtcPeerSession(connection));
    } on Object {
      if (connection != null) {
        await _FlutterWebrtcPeerSession._dispose(connection);
      }
      return const Result.failure(_platformUnable);
    }
  }
}

/// The platform could not take a step of this device's own negotiation.
const _platformUnable = UnsupportedProtocolFailure(
  UnsupportedProtocolFailureKind.capability,
);

/// The platform refused what the peer sent.
const _peerRefused = ValidationFailure(ValidationFailureKind.invalidInput);

final class _FlutterWebrtcPeerSession implements VoicePeerMedia {
  _FlutterWebrtcPeerSession(this._connection) {
    _connection
      ..onIceCandidate = _onCandidate
      ..onIceGatheringState = _onGathering
      ..onConnectionState = _onConnectionState
      ..onDataChannel = _closeDataChannel;
  }

  final RTCPeerConnection _connection;
  final _events = StreamController<VoicePeerMediaEvent>.broadcast();
  var _closed = false;

  @override
  Stream<VoicePeerMediaEvent> get events => _events.stream;

  @override
  Future<Result<VoiceSessionDescription>> createOffer() => _describe(
    () => _connection.createOffer(voiceSdpConstraints),
    VoiceDescriptionType.offer,
  );

  @override
  Future<Result<VoiceSessionDescription>> createAnswer() => _describe(
    () => _connection.createAnswer(voiceSdpConstraints),
    VoiceDescriptionType.answer,
  );

  @override
  Future<Result<void>> setLocalDescription(
    VoiceSessionDescription description,
  ) => _step(
    () => _connection.setLocalDescription(_platform(description)),
    _platformUnable,
  );

  @override
  Future<Result<void>> rollbackLocalOffer() => _step(
    // An empty description rather than none: libwebrtc's JNI reads the
    // string whatever the type (`JavaToNativeSessionDescription`), and
    // `CreateSessionDescription` builds a rollback without it (m150).
    () =>
        _connection.setLocalDescription(RTCSessionDescription('', 'rollback')),
    _platformUnable,
  );

  @override
  Future<Result<void>> setRemoteDescription(
    VoiceSessionDescription description,
  ) => _step(
    () => _connection.setRemoteDescription(_platform(description)),
    _peerRefused,
  );

  @override
  Future<Result<void>> addRemoteCandidate(VoiceIceCandidate candidate) => _step(
    () => _connection.addCandidate(
      RTCIceCandidate(candidate.candidate, candidate.mid, candidate.mline),
    ),
    _peerRefused,
  );

  @override
  Future<Result<void>> setConfiguration(RelayIceConfiguration configuration) =>
      _step(
        () =>
            _connection.setConfiguration(voiceRtcConfiguration(configuration)),
        _platformUnable,
      );

  @override
  Future<Result<void>> restartIce() =>
      _step(_connection.restartIce, _platformUnable);

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _connection
      ..onIceCandidate = null
      ..onIceGatheringState = null
      ..onConnectionState = null
      ..onDataChannel = null;
    await _dispose(_connection);
    await _events.close();
  }

  static Future<void> _dispose(RTCPeerConnection connection) async {
    try {
      await connection.close();
    } on Object {
      // Already closed on the platform side.
    }
    try {
      await connection.dispose();
    } on Object {
      // Already gone on the platform side.
    }
  }

  Future<Result<VoiceSessionDescription>> _describe(
    Future<RTCSessionDescription> Function() create,
    VoiceDescriptionType type,
  ) async {
    if (_closed) {
      return const Result.failure(_platformUnable);
    }
    try {
      final description = await create();
      final sdp = description.sdp;
      if (sdp == null || description.type != type.name) {
        return const Result.failure(_platformUnable);
      }
      return Result.success(VoiceSessionDescription(type: type, sdp: sdp));
    } on Object {
      return const Result.failure(_platformUnable);
    }
  }

  Future<Result<void>> _step(
    Future<void> Function() action,
    Failure refusal,
  ) async {
    if (_closed) {
      return const Result.failure(_platformUnable);
    }
    try {
      await action();
      return const Result.success(null);
    } on Object {
      return Result.failure(refusal);
    }
  }

  static RTCSessionDescription _platform(VoiceSessionDescription description) =>
      RTCSessionDescription(description.sdp, description.type.name);

  void _onCandidate(RTCIceCandidate candidate) {
    final line = candidate.candidate;
    final mid = candidate.sdpMid;
    final mline = candidate.sdpMLineIndex;
    if (line == null || line.isEmpty || mid == null || mline == null) {
      // An end-of-candidates marker, or a candidate the wire cannot carry.
      return;
    }
    try {
      _add(
        VoiceLocalCandidateGathered(
          VoiceIceCandidate(candidate: line, mid: mid, mline: mline),
        ),
      );
    } on FormatException {
      // Not text the signalling payload can carry.
    }
  }

  void _onGathering(RTCIceGatheringState state) {
    switch (state) {
      case RTCIceGatheringState.RTCIceGatheringStateComplete:
        _add(const VoiceCandidateGatheringComplete());
      case RTCIceGatheringState.RTCIceGatheringStateNew:
      case RTCIceGatheringState.RTCIceGatheringStateGathering:
        break;
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    _add(
      VoiceMediaStateChanged(switch (state) {
        RTCPeerConnectionState.RTCPeerConnectionStateNew =>
          VoiceMediaState.fresh,
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
          VoiceMediaState.connecting,
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          VoiceMediaState.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          VoiceMediaState.disconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          VoiceMediaState.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
          VoiceMediaState.closed,
      }),
    );
  }

  void _closeDataChannel(RTCDataChannel channel) {
    unawaited(_quietly(channel.close));
  }

  void _add(VoicePeerMediaEvent event) {
    if (!_closed) {
      _events.add(event);
    }
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Nothing to report: the channel is being refused.
    }
  }
}
