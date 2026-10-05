import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The call's microphone through `flutter_webrtc`: one `getUserMedia` capture
/// of audio alone, shared by every hold on it and stopped when the last hold
/// is given back.
///
/// **It must follow the join's own permission request.** `getUserMedia` asks
/// for `RECORD_AUDIO` by itself when it is missing (ADR-078,
/// `GetUserMediaImpl.getUserMedia` in `flutter_webrtc` 1.6.2+hotfix.3), and
/// nothing here checks first: the join asks through `MicrophonePermissionPort`
/// before any hold is taken, and a check here would be a second place that
/// decides when the microphone may be asked for (§N rule 11).
///
/// It asks for audio and nothing else. [constraints] sets `video` to false,
/// so no camera is opened and no video track exists; the platform's default
/// audio constraints — echo cancellation, noise suppression and gain control
/// — apply unchanged.
///
/// Mute is the track's `enabled` flag, which libwebrtc reads at its source:
/// a disabled local audio track sends silence on every sender that carries
/// it, so one flag mutes every connection of the call and none renegotiates
/// (`MethodCallHandlerImpl.mediaStreamTrackSetEnabled` finds a local track by
/// its id and calls `MediaStreamTrack.setEnabled`).
final class FlutterWebrtcLocalAudioSource implements VoiceLocalAudioPort {
  FlutterWebrtcLocalAudioSource();

  static const constraints = <String, Object>{'audio': true, 'video': false};

  MediaStream? _stream;
  MediaStreamTrack? _track;
  var _holds = 0;
  var _muted = false;
  Future<void> _turn = Future<void>.value();

  @override
  Future<Result<VoiceLocalAudio>> acquire() => _serially(() async {
    var stream = _stream;
    var track = _track;
    if (stream == null || track == null) {
      final MediaStream captured;
      try {
        captured = await navigator.mediaDevices.getUserMedia(constraints);
      } on Object {
        // A denied permission, a busy microphone or a missing plugin: the
        // platform's text says which, and is not kept.
        return const Result.failure(
          UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
        );
      }
      final audio = captured.getAudioTracks();
      if (audio.length != 1 || captured.getVideoTracks().isNotEmpty) {
        await _stop(captured, audio);
        return const Result.failure(
          UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
        );
      }
      stream = _stream = captured;
      track = _track = audio.single;
      if (_muted) {
        // A capture that starts during a muted call starts silent.
        _setEnabled(track, enabled: false);
      }
    }
    _holds += 1;
    return Result.success(FlutterWebrtcLocalAudio._(this, stream, track));
  });

  @override
  Future<void> setMuted(bool muted) => _serially(() async {
    _muted = muted;
    final track = _track;
    if (track != null) {
      _setEnabled(track, enabled: !muted);
    }
  });

  /// The plugin's setter sends the change and does not wait for it, so a
  /// platform that refuses it is caught here rather than left unhandled.
  static void _setEnabled(MediaStreamTrack track, {required bool enabled}) {
    runZonedGuarded(() => track.enabled = enabled, (_, _) {
      // The track is gone on the platform side, and so is its sound.
    });
  }

  Future<void> _release() => _serially(() async {
    _holds -= 1;
    final stream = _stream;
    if (_holds > 0 || stream == null) {
      return;
    }
    final track = _track;
    _stream = null;
    _track = null;
    await _stop(stream, [?track]);
  });

  static Future<void> _stop(
    MediaStream stream,
    List<MediaStreamTrack> tracks,
  ) async {
    for (final track in tracks) {
      try {
        await track.stop();
      } on Object {
        // Already gone on the platform side.
      }
    }
    try {
      await stream.dispose();
    } on Object {
      // Already gone on the platform side.
    }
  }

  Future<T> _serially<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// One hold on the shared capture, and the platform objects a connection adds
/// to itself.
final class FlutterWebrtcLocalAudio implements VoiceLocalAudio {
  FlutterWebrtcLocalAudio._(this._source, this.stream, this.track);

  final FlutterWebrtcLocalAudioSource _source;

  /// The capture's stream, which names the track in a description's `msid`.
  final MediaStream stream;

  /// The one audio track.
  final MediaStreamTrack track;

  var _released = false;

  /// Whether this hold has been given back, after which no connection may
  /// add its track.
  bool get isReleased => _released;

  @override
  Future<void> release() {
    if (_released) {
      return Future<void>.value();
    }
    _released = true;
    return _source._release();
  }
}
