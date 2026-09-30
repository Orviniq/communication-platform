import 'dart:typed_data';

import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

const lowDevice = '00000000-0000-4000-8000-00000000000a';
const highDevice = '00000000-0000-4000-8000-00000000000b';
const user = '00000000-0000-4000-8000-000000001001';

String sdpWith(List<String> mediaLines) =>
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'a=group:BUNDLE 0\r\n'
    '${[for (final line in mediaLines) '$line\r\na=ice-ufrag:Zx1c\r\n'].join()}';

void main() {
  group('the polite peer', () {
    test('is the device whose id string sorts lower', () {
      expect(
        isPoliteVoicePeer(localDeviceId: lowDevice, remoteDeviceId: highDevice),
        isTrue,
      );
      expect(
        isPoliteVoicePeer(localDeviceId: highDevice, remoteDeviceId: lowDevice),
        isFalse,
      );
    });

    test('is the same device however an id is spelled', () {
      expect(
        isPoliteVoicePeer(
          localDeviceId: lowDevice.toUpperCase(),
          remoteDeviceId: highDevice,
        ),
        isTrue,
      );
      expect(
        isPoliteVoicePeer(
          localDeviceId: highDevice,
          remoteDeviceId: lowDevice.toUpperCase(),
        ),
        isFalse,
      );
    });

    test('does not exist between a device and itself', () {
      expect(
        () => isPoliteVoicePeer(
          localDeviceId: lowDevice,
          remoteDeviceId: lowDevice.toUpperCase(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('a description', () {
    VoiceSessionDescription offer(List<String> mediaLines) =>
        VoiceSessionDescription(
          type: VoiceDescriptionType.offer,
          sdp: sdpWith(mediaLines),
        );

    test('is audio-only with exactly one audio section', () {
      expect(offer(['m=audio 9 UDP/TLS/RTP/SAVPF 111']).isAudioOnly, isTrue);
    });

    test('is not with a video, an application or a second audio section', () {
      for (final lines in [
        ['m=audio 9 UDP/TLS/RTP/SAVPF 111', 'm=video 9 UDP/TLS/RTP/SAVPF 96'],
        ['m=video 9 UDP/TLS/RTP/SAVPF 96'],
        [
          'm=audio 9 UDP/TLS/RTP/SAVPF 111',
          'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
        ],
        ['m=audio 9 UDP/TLS/RTP/SAVPF 111', 'm=audio 9 UDP/TLS/RTP/SAVPF 111'],
        <String>[],
      ]) {
        expect(offer(lines).isAudioOnly, isFalse, reason: lines.join(', '));
      }
    });

    test('reads the same with bare line feeds', () {
      final description = VoiceSessionDescription(
        type: VoiceDescriptionType.answer,
        sdp: sdpWith(['m=audio 9 UDP/TLS/RTP/SAVPF 111']).replaceAll('\r', ''),
      );

      expect(description.isAudioOnly, isTrue);
      expect(description.iceUfrag, 'Zx1c');
    });

    test('names the ICE generation it carries', () {
      expect(offer(['m=audio 9 UDP/TLS/RTP/SAVPF 111']).iceUfrag, 'Zx1c');
      expect(
        const VoiceSessionDescription(
          type: VoiceDescriptionType.offer,
          sdp: 'v=0\r\n',
        ).iceUfrag,
        isNull,
      );
    });

    test('has no string form that shows its text', () {
      final description = offer(['m=audio 9 UDP/TLS/RTP/SAVPF 111']);

      expect(description.toString(), isNot(contains('ice-ufrag')));
      expect(description.toString(), isNot(contains('m=audio')));
    });
  });

  test('a candidate names the ICE generation that gathered it', () {
    expect(
      iceUfragOfCandidate(
        'candidate:1 1 udp 41885439 198.51.100.7 50000 typ relay raddr 0.0.0.0 '
        'rport 0 generation 0 ufrag Zx1c network-id 1 network-cost 10',
      ),
      'Zx1c',
    );
    expect(
      iceUfragOfCandidate(
        'candidate:1 1 udp 41885439 198.51.100.7 50000 typ relay',
      ),
      isNull,
    );
  });

  test('a peer address holds two UUIDs and a join id of 16 bytes', () {
    final address = VoicePeerAddress(
      userId: user,
      deviceId: lowDevice,
      joinId: Uint8List(16),
    );

    expect(address.toString(), isNot(contains(lowDevice)));
    expect(
      () => VoicePeerAddress(
        userId: 'not-a-uuid',
        deviceId: lowDevice,
        joinId: Uint8List(16),
      ),
      throwsFormatException,
    );
    expect(
      () => VoicePeerAddress(
        userId: user,
        deviceId: lowDevice,
        joinId: Uint8List(15),
      ),
      throwsFormatException,
    );
  });
}
