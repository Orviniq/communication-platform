import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// libwebrtc is reached through two adapters and nowhere else (ADR-078), so
/// the domain and application layers of voice hold no platform type and the
/// call can be tested on fakes.
void main() {
  List<File> dartSources() => [
    for (final entry in Directory('lib').listSync(recursive: true))
      if (entry is File && entry.path.endsWith('.dart')) entry,
  ];

  String relative(File file) => file.path.replaceAll(r'\', '/');

  test('only the voice infrastructure imports the WebRTC packages', () {
    const packages = [
      'package:flutter_webrtc/',
      'package:webrtc_interface/',
      'package:dart_webrtc/',
    ];
    final importers = {
      for (final file in dartSources())
        if (packages.any(file.readAsStringSync().contains)) relative(file),
    };

    expect(importers, {
      'lib/features/voice/infrastructure/flutter_webrtc_local_audio.dart',
      'lib/features/voice/infrastructure/flutter_webrtc_peer_media.dart',
    });
  });

  test('nothing asks the platform for video, a screen or a data channel', () {
    // §N rule 1: one audio track, no video track and no data channel.
    const forbidden = [
      'createDataChannel(',
      'addTransceiver(',
      'getDisplayMedia(',
      'RTCVideoRenderer',
      'RTCVideoView',
      "'video': true",
    ];
    final violations = [
      for (final file in dartSources())
        for (final call in forbidden)
          if (file.readAsStringSync().contains(call))
            '${relative(file)} contains $call',
    ];

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
