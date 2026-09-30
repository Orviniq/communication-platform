import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/infrastructure/flutter_webrtc_local_audio.dart';
import 'package:communication_platform/features/voice/infrastructure/flutter_webrtc_peer_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_fakes.dart';
import 'support/relay_fakes.dart';

/// `flutter_webrtc` 1.6.2+hotfix.3 over a faked platform.
///
/// The plugin's own Dart half runs unchanged; only the Android side is faked,
/// at its channels. Every method call the plugin makes is recorded and
/// answered the way `MethodCallHandlerImpl` answers it, and events are pushed
/// on a connection's own event channel as `PeerConnectionObserver` pushes
/// them. No device is available, so this is the half that decides what the
/// platform is asked for.
final class FakeWebrtcPlatform {
  FakeWebrtcPlatform() {
    _messenger
      ..setMockMethodCallHandler(_method, _handle)
      ..setMockMethodCallHandler(_globalEvents, (_) async => null);
  }

  static const _method = MethodChannel('FlutterWebRTC.Method');
  static const _globalEvents = MethodChannel('FlutterWebRTC.Event');

  final calls = <MethodCall>[];

  /// Methods that fail, with the message the platform would give.
  final failing = <String, String>{};
  final _channels = <MethodChannel>[];
  var _connections = 0;

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<String> get methods => [for (final call in calls) call.method];

  Iterable<Map<Object?, Object?>> argumentsOf(String method) => [
    for (final call in calls)
      if (call.method == method) call.arguments as Map<Object?, Object?>,
  ];

  /// Pushes [event] on connection [id]'s event channel.
  Future<void> push(String id, Map<String, Object?> event) =>
      _messenger.handlePlatformMessage(
        'FlutterWebRTC/peerConnectionEvent$id',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );

  void uninstall() {
    _messenger
      ..setMockMethodCallHandler(_method, null)
      ..setMockMethodCallHandler(_globalEvents, null);
    for (final channel in _channels) {
      _messenger.setMockMethodCallHandler(channel, null);
    }
  }

  void _listenOn(String name) {
    final channel = MethodChannel(name);
    _channels.add(channel);
    _messenger.setMockMethodCallHandler(channel, (_) async => null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final failure = failing[call.method];
    if (failure != null) {
      throw PlatformException(code: call.method, message: failure);
    }
    switch (call.method) {
      case 'createPeerConnection':
        _connections += 1;
        final id = 'pc$_connections';
        _listenOn('FlutterWebRTC/peerConnectionEvent$id');
        return <String, Object?>{'peerConnectionId': id};
      case 'getUserMedia':
        return <String, Object?>{
          'streamId': 'stream-1',
          'audioTracks': [_audioTrack],
          'videoTracks': <Object?>[],
        };
      case 'addTrack':
        return <String, Object?>{
          'senderId': 'sender-1',
          'ownsTrack': false,
          'track': _audioTrack,
          'rtpParameters': <String, Object?>{
            'encodings': <Object?>[],
            'headerExtensions': <Object?>[],
            'codecs': <Object?>[],
            'rtcp': <String, Object?>{'cname': 'cname', 'reducedSize': true},
          },
        };
      case 'createOffer':
        return <String, Object?>{
          'sdp': fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'native1'),
          'type': 'offer',
        };
      case 'createAnswer':
        return <String, Object?>{
          'sdp': fakeSdp(type: VoiceDescriptionType.answer, ufrag: 'native2'),
          'type': 'answer',
        };
      default:
        return null;
    }
  }

  static const _audioTrack = <String, Object?>{
    'id': 'track-1',
    'label': 'track-1',
    'kind': 'audio',
    'enabled': true,
    'settings': <String, Object?>{},
  };
}

RelayCredential relayCredential({
  String username = relayUsername,
  String password = relayPassword,
}) => RelayCredential(
  urls: relayUrls,
  username: username,
  credential: password,
  lifetime: const Duration(hours: 6),
  expiresAt: DateTime.utc(2026, 9, 30, 18),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebrtcPlatform platform;

  setUp(() => platform = FakeWebrtcPlatform());
  tearDown(() => platform.uninstall());

  Future<(FlutterWebrtcLocalAudioSource, VoiceLocalAudio, VoicePeerMedia)>
  openOne([RelayIceConfiguration? configuration]) async {
    final source = FlutterWebrtcLocalAudioSource();
    final hold = (await source.acquire() as Success<VoiceLocalAudio>).value;
    final opened = await const FlutterWebrtcPeerMedia().open(
      configuration: configuration ?? relayCredential().iceConfiguration,
      audio: hold,
    );
    return (source, hold, (opened as Success<VoicePeerMedia>).value);
  }

  group('the configuration', () {
    test('holds the relay servers and no STUN server', () {
      final configuration = voiceRtcConfiguration(
        relayCredential().iceConfiguration,
      );

      expect(configuration, {
        'iceServers': [
          for (final url in relayUrls)
            {
              'urls': [url],
              'username': relayUsername,
              'credential': relayPassword,
            },
        ],
        'iceTransportPolicy': 'relay',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
        'continualGatheringPolicy': 'gather_once',
      });
      expect(configuration.toString(), isNot(contains('stun')));
    });

    test('is what the platform is given, at open and at a restart', () async {
      final (_, _, media) = await openOne();
      final next = relayCredential(username: 'next', password: 'next');

      await media.setConfiguration(next.iceConfiguration);
      await media.restartIce();

      final given = [
        for (final arguments in platform.argumentsOf('createPeerConnection'))
          arguments['configuration'],
        for (final arguments in platform.argumentsOf('setConfiguration'))
          arguments['configuration'],
      ];
      expect(given, [
        voiceRtcConfiguration(relayCredential().iceConfiguration),
        voiceRtcConfiguration(next.iceConfiguration),
      ]);
      for (final configuration in given) {
        final map = configuration! as Map<Object?, Object?>;
        expect(map['iceTransportPolicy'], 'relay');
        for (final server in map['iceServers']! as List<Object?>) {
          final urls = (server! as Map<Object?, Object?>)['urls']!;
          expect(urls as List<Object?>, everyElement(startsWith('turn:')));
        }
        expect(map.toString(), isNot(contains('stun')));
      }
      expect(platform.methods, contains('restartIce'));
    });
  });

  test('no video track and no data channel is ever created', () async {
    final (source, hold, media) = await openOne();

    // One negotiation of each kind, a restart, a rollback and a close.
    await media.createOffer();
    await media.setLocalDescription(
      VoiceSessionDescription(
        type: VoiceDescriptionType.offer,
        sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'native1'),
      ),
    );
    await media.setRemoteDescription(
      VoiceSessionDescription(
        type: VoiceDescriptionType.answer,
        sdp: fakeSdp(type: VoiceDescriptionType.answer, ufrag: 'peer1'),
      ),
    );
    await media.addRemoteCandidate(fakeRelayCandidate('peer1'));
    await media.restartIce();
    await media.createOffer();
    await media.rollbackLocalOffer();
    await media.setRemoteDescription(
      VoiceSessionDescription(
        type: VoiceDescriptionType.offer,
        sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'peer2'),
      ),
    );
    await media.createAnswer();
    await media.close();
    await hold.release();

    expect(platform.argumentsOf('getUserMedia').single['constraints'], {
      'audio': true,
      'video': false,
    });
    expect(platform.methods, isNot(contains('createDataChannel')));
    expect(platform.methods, isNot(contains('addTransceiver')));
    expect(platform.methods, isNot(contains('addStream')));
    final added = platform.argumentsOf('addTrack').single;
    expect(added['trackId'], 'track-1');
    expect(added['streamIds'], ['stream-1']);
    final asked = [
      ...platform.argumentsOf('createOffer'),
      ...platform.argumentsOf('createAnswer'),
    ];
    expect(asked, hasLength(3));
    for (final arguments in asked) {
      expect(arguments['constraints'], voiceSdpConstraints);
    }
    // The rollback carries an empty description, never a missing one.
    expect(platform.argumentsOf('setLocalDescription').last['description'], {
      'sdp': '',
      'type': 'rollback',
    });
    expect(
      platform.methods.where(
        (method) => {
          'peerConnectionClose',
          'peerConnectionDispose',
          'trackDispose',
          'streamDispose',
        }.contains(method),
      ),
      [
        'peerConnectionClose',
        'peerConnectionDispose',
        'trackDispose',
        'streamDispose',
      ],
    );
    // The hold was the capture's last, so the microphone is off again.
    expect(await source.acquire(), isA<Success<VoiceLocalAudio>>());
    expect(
      platform.methods.where((method) => method == 'getUserMedia'),
      hasLength(2),
    );
  });

  test('the platform\'s events arrive as the port\'s', () async {
    final (_, _, media) = await openOne();
    final events = <VoicePeerMediaEvent>[];
    final subscription = media.events.listen(events.add);
    addTearDown(subscription.cancel);

    for (final event in <Map<String, Object?>>[
      // Gathering's start marks no generation, so it is not passed on.
      {'event': 'iceGatheringState', 'state': 'gathering'},
      {
        'event': 'onCandidate',
        'candidate': {
          'candidate': fakeRelayCandidate('native1').candidate,
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      },
      // A candidate the signalling payload cannot carry is dropped.
      {
        'event': 'onCandidate',
        'candidate': {
          'candidate': fakeRelayCandidate('native1').candidate,
          'sdpMid': null,
          'sdpMLineIndex': 0,
        },
      },
      {'event': 'iceGatheringState', 'state': 'complete'},
      {'event': 'peerConnectionState', 'state': 'connecting'},
      {'event': 'peerConnectionState', 'state': 'connected'},
      {'event': 'peerConnectionState', 'state': 'disconnected'},
      {'event': 'peerConnectionState', 'state': 'failed'},
    ]) {
      await platform.push('pc1', event);
    }
    await settle();

    expect(events, hasLength(6));
    final candidate = (events[0] as VoiceLocalCandidateGathered).candidate;
    expect(candidate.candidate, fakeRelayCandidate('native1').candidate);
    expect(candidate.mid, '0');
    expect(candidate.mline, 0);
    expect(events[1], isA<VoiceCandidateGatheringComplete>());
    expect(
      events.skip(2).map((event) => (event as VoiceMediaStateChanged).state),
      [
        VoiceMediaState.connecting,
        VoiceMediaState.connected,
        VoiceMediaState.disconnected,
        VoiceMediaState.failed,
      ],
    );
  });

  test('a data channel the peer opened is closed on arrival', () async {
    await openOne();
    final channel = const MethodChannel(
      'FlutterWebRTC/dataChannelEventpc1flutter-1',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await platform.push('pc1', {
      'event': 'didOpenDataChannel',
      'id': 1,
      'label': 'unasked',
      'flutterId': 'flutter-1',
    });
    await settle();

    expect(platform.methods, contains('dataChannelClose'));
  });

  test('a refusal carries none of the platform\'s text', () async {
    const quoted =
        'WEBRTC_SET_REMOTE_DESCRIPTION_ERROR: Failed to parse '
        'SessionDescription. a=fingerprint:sha-256 4E:5B:27:32 Invalid value';
    platform.failing['setRemoteDescription'] = quoted;
    platform.failing['addCandidate'] = quoted;
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        printed.add(message);
      }
    };
    final outcomes = <Result<void>>[];
    try {
      await runZoned(
        () async {
          final (_, _, media) = await openOne();
          outcomes
            ..add(
              await media.setRemoteDescription(
                VoiceSessionDescription(
                  type: VoiceDescriptionType.offer,
                  sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'x'),
                ),
              ),
            )
            ..add(await media.addRemoteCandidate(fakeRelayCandidate('x')));
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
    } finally {
      debugPrint = original;
    }

    expect(outcomes, everyElement(isA<FailureResult<void>>()));
    for (final text in [
      ...printed,
      for (final outcome in outcomes) outcome.toString(),
      for (final outcome in outcomes)
        (outcome as FailureResult<void>).failure.toString(),
    ]) {
      expect(text, isNot(contains('fingerprint')));
      expect(text, isNot(contains('SessionDescription')));
    }
  });

  group('the local audio', () {
    test(
      'one capture is shared by every hold, and stops with the last',
      () async {
        final source = FlutterWebrtcLocalAudioSource();

        final first =
            (await source.acquire() as Success<VoiceLocalAudio>).value;
        final second =
            (await source.acquire() as Success<VoiceLocalAudio>).value;
        expect(
          platform.methods.where((method) => method == 'getUserMedia'),
          hasLength(1),
        );

        await first.release();
        await first.release();
        expect(platform.methods, isNot(contains('trackDispose')));

        await second.release();
        expect(
          platform.argumentsOf('trackDispose').single['trackId'],
          'track-1',
        );
        expect(
          platform.argumentsOf('streamDispose').single['streamId'],
          'stream-1',
        );

        final third =
            (await source.acquire() as Success<VoiceLocalAudio>).value;
        expect(
          platform.methods.where((method) => method == 'getUserMedia'),
          hasLength(2),
        );
        await third.release();
      },
    );

    test('a released hold is never added to a connection', () async {
      final source = FlutterWebrtcLocalAudioSource();
      final hold = (await source.acquire() as Success<VoiceLocalAudio>).value;
      await hold.release();

      final opened = await const FlutterWebrtcPeerMedia().open(
        configuration: relayCredential().iceConfiguration,
        audio: hold,
      );

      expect(opened, isA<FailureResult<VoicePeerMedia>>());
      expect(platform.methods, isNot(contains('createPeerConnection')));
    });

    test('a capture the platform refuses is a failure with no text', () async {
      platform.failing['getUserMedia'] = 'DOMException, NotAllowedError';

      final held = await FlutterWebrtcLocalAudioSource().acquire();

      expect(held, isA<FailureResult<VoiceLocalAudio>>());
      expect(
        (held as FailureResult<VoiceLocalAudio>).failure.toString(),
        isNot(contains('NotAllowedError')),
      );
    });

    test('a connection that cannot add its track is closed again', () async {
      platform.failing['addTrack'] = 'track not found';
      final source = FlutterWebrtcLocalAudioSource();
      final hold = (await source.acquire() as Success<VoiceLocalAudio>).value;

      final opened = await const FlutterWebrtcPeerMedia().open(
        configuration: relayCredential().iceConfiguration,
        audio: hold,
      );

      expect(opened, isA<FailureResult<VoicePeerMedia>>());
      expect(
        platform.methods,
        containsAllInOrder([
          'createPeerConnection',
          'addTrack',
          'peerConnectionClose',
          'peerConnectionDispose',
        ]),
      );
      await hold.release();
    });
  });
}
