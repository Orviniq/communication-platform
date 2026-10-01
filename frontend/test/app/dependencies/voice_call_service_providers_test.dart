import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Composing the microphone and the call service asks the platform for
/// nothing: the join asks, and nothing else does (§N rule 11).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('composing them asks for no permission and starts nothing', () {
    final calls = <MethodCall>[];
    const channel = MethodChannel(VoiceCallChannel.name);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(microphonePermissionProvider),
      isA<PlatformMicrophonePermission>(),
    );
    expect(
      container.read(voiceCallServicePlatformProvider),
      isA<PlatformVoiceCallService>(),
    );
    expect(calls, isEmpty);
  });

  test('the entry says a call is in progress and names nobody', () async {
    final strings = await resolveVoiceCallServiceStrings();

    expect(strings.title, 'Call in progress');
    expect(strings.channelName, isNotEmpty);
    expect(strings.channelDescription, contains('never names anyone'));
  });
}
