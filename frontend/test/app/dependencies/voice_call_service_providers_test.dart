import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_providers.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/voice/support/call_fakes.dart';
import '../../features/voice/support/relay_fakes.dart';

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

  test('a call ends with the session it belongs to, and gives the '
      'microphone back', () async {
    final mesh = CallMesh(accounts: 2);
    addTearDown(mesh.dispose);
    final own = mesh.device(0);
    final peer = mesh.device(1);
    await mesh.joinAll([peer]);
    final log = <String>[];
    final scope = (userId: own.userId, deviceId: own.deviceId);
    final container = ProviderContainer(
      overrides: [
        voiceCallEngineProvider.overrideWith((ref, scope) => own.engine),
        voiceCallServicePlatformProvider.overrideWithValue(_Service(log)),
        microphonePermissionProvider.overrideWithValue(_Microphone(log)),
        relayCredentialServiceProvider.overrideWithValue(
          RelayCredentialService(
            remote: MintingRelayPort(mesh.clock),
            deployment: const FixedVoiceDeployment(voiceConfigured: true),
            clock: mesh.clock,
          ),
        ),
        voiceSessionActiveProvider.overrideWith(
          (ref, scope) => ref.watch(_session),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = await container.read(
      voiceCallControllerProvider(scope).future,
    );

    final joining = controller.join(callRoomId);
    await mesh.clock.elapse(const Duration(seconds: 25));
    expect(await joining, isA<VoiceJoinStarted>());
    expect(own.state.phase, VoiceCallPhase.inCall);
    expect(own.audio.live, 1, reason: 'the call holds the microphone');
    expect(log, ['microphone', 'start']);

    container.read(_session.notifier).end();
    await mesh.clock.elapse(const Duration(seconds: 1));

    expect(own.state.phase, VoiceCallPhase.ended);
    expect(own.state.endReason, VoiceCallEndReason.left);
    expect(own.audio.live, 0, reason: 'the capture is given back');
    expect(log.last, 'stop');
    expect(peer.statusOf(own), isNull, reason: 'the peer drops the device');
  });

  test('the entry says a call is in progress and names nobody', () async {
    final strings = await resolveVoiceCallServiceStrings();

    expect(strings.title, 'Call in progress');
    expect(strings.channelName, isNotEmpty);
    expect(strings.channelDescription, contains('never names anyone'));
  });
}

/// Whether the session is still running, as a test turns it off.
final _session = NotifierProvider<_SessionNotifier, bool>(_SessionNotifier.new);

final class _SessionNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void end() => state = false;
}

final class _Microphone implements MicrophonePermissionPort {
  _Microphone(this.log);

  final List<String> log;

  @override
  Future<MicrophonePermission> request() async {
    log.add('microphone');
    return MicrophonePermission.granted;
  }

  @override
  Future<bool> isGranted() async => true;

  @override
  Future<void> openSettings() async => log.add('settings');
}

final class _Service implements VoiceCallServicePort {
  _Service(this.log);

  final List<String> log;

  @override
  Future<VoiceCallServiceStart> start() async {
    log.add('start');
    return const VoiceCallServiceRunning(notificationVisible: true);
  }

  @override
  Future<void> stop() async => log.add('stop');
}
