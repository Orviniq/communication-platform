import 'dart:async';

import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two adapters in front of `VoiceCall.kt`: the microphone permission and
/// the call's foreground service.
///
/// The Kotlin half cannot run in a host test. What is proved here is the Dart
/// half's reading of every answer it can be given, and the rules it keeps on
/// its own: it starts the service only after a granted permission, and a start
/// it was refused - or could not read - is a typed refusal, never a running
/// service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(VoiceCallChannel.name);
  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall call)> replies;

  setUp(() {
    calls = [];
    replies = {};
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final reply = replies[call.method];
          return reply == null ? null : reply(call);
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> methods() => [for (final call in calls) call.method];

  group('the permission adapter', () {
    const permission = PlatformMicrophonePermission();

    test('maps each native answer', () async {
      const answers = {
        'granted': MicrophonePermission.granted,
        'denied': MicrophonePermission.denied,
        'deniedPermanently': MicrophonePermission.deniedPermanently,
      };
      for (final MapEntry(key: native, value: expected) in answers.entries) {
        replies['requestMicrophone'] = (_) => native;

        expect(await permission.request(), expected, reason: native);
      }
      expect(methods(), List.filled(3, 'requestMicrophone'));
      expect(
        calls.map((call) => call.arguments),
        everyElement(isNull),
        reason: 'the request carries nothing',
      );
    });

    test('reads anything it does not understand as a refusal', () async {
      for (final reply in <Object? Function(MethodCall)>[
        (_) => 'allowed',
        (_) => 'GRANTED',
        (_) => true,
        (_) => <String, Object?>{'answer': 'granted'},
        (_) => null,
        (_) => throw PlatformException(code: 'boom'),
        (_) => throw MissingPluginException(),
      ]) {
        replies['requestMicrophone'] = reply;

        expect(await permission.request(), MicrophonePermission.denied);
      }
    });

    test('asks nothing on a target that is not Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      replies['requestMicrophone'] = (_) => 'granted';
      replies['microphoneGranted'] = (_) => true;

      expect(await permission.request(), MicrophonePermission.denied);
      expect(await permission.isGranted(), isFalse);
      expect(calls, isEmpty);
    });

    test('checks without asking, and only a true is a grant', () async {
      replies['microphoneGranted'] = (_) => true;
      expect(await permission.isGranted(), isTrue);

      for (final reply in <Object? Function(MethodCall)>[
        (_) => false,
        (_) => 'true',
        (_) => 1,
        (_) => null,
        (_) => throw PlatformException(code: 'boom'),
      ]) {
        replies['microphoneGranted'] = reply;
        expect(await permission.isGranted(), isFalse);
      }
      expect(
        methods(),
        everyElement('microphoneGranted'),
        reason: 'a check is never a request',
      );
    });

    test('opens the settings when asked, carries nothing, and reads nothing '
        'back', () async {
      await permission.openSettings();
      expect(methods(), ['openMicrophoneSettings']);
      expect(calls.single.arguments, isNull);

      for (final reply in <Object? Function(MethodCall)>[
        (_) => throw PlatformException(code: 'boom'),
        (_) => throw MissingPluginException(),
      ]) {
        replies['openMicrophoneSettings'] = reply;
        await expectLater(permission.openSettings(), completes);
      }
      expect(
        methods(),
        isNot(contains('requestMicrophone')),
        reason: 'opening the settings is not a request for the microphone',
      );

      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await permission.openSettings();
      expect(calls, isEmpty);
    });
  });

  group('the service adapter', () {
    PlatformVoiceCallService service({MicrophonePermissionPort? microphone}) =>
        PlatformVoiceCallService(
          microphone: microphone ?? const PlatformMicrophonePermission(),
          strings: () async => _strings,
        );

    test('starts only after a granted permission', () async {
      replies['microphoneGranted'] = (_) => false;
      replies['start'] = (_) => _started();

      final refused = await service().start();

      expect(
        refused,
        isA<VoiceCallServiceRefused>().having(
          (outcome) => outcome.reason,
          'reason',
          VoiceCallServiceRefusal.microphoneNotGranted,
        ),
      );
      expect(methods(), [
        'microphoneGranted',
      ], reason: 'nothing is started without the permission');

      calls.clear();
      replies['microphoneGranted'] = (_) => true;

      final started = await service().start();

      expect(started, isA<VoiceCallServiceRunning>());
      expect(methods(), ['microphoneGranted', 'start']);
    });

    test(
      'asks the permission port, and never asks for the permission',
      () async {
        final microphone = _Microphone(granted: false);

        await service(microphone: microphone).start();
        microphone.granted = true;
        await service(microphone: microphone).start();

        expect(microphone.checks, 2);
        expect(
          microphone.requests,
          0,
          reason: 'only the join asks for the microphone (§N rule 11)',
        );
        expect(methods(), ['start']);
      },
    );

    test('carries the entry text and nothing else', () async {
      replies['microphoneGranted'] = (_) => true;
      replies['start'] = (_) => _started(notificationVisible: false);

      final outcome = await service().start();

      expect(
        outcome,
        isA<VoiceCallServiceRunning>().having(
          (running) => running.notificationVisible,
          'notificationVisible',
          isFalse,
        ),
      );
      final start = calls.singleWhere((call) => call.method == 'start');
      final arguments = (start.arguments as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key! as String, value),
      );
      expect(arguments, {
        'title': 'Call in progress',
        'channelName': 'Voice calls',
        'channelDescription': 'Shown while you are in a call.',
      });
    });

    test('a refused start is a typed failure, not a silent success', () async {
      replies['microphoneGranted'] = (_) => true;
      const refusals = {
        'microphoneNotGranted': VoiceCallServiceRefusal.microphoneNotGranted,
        'notInForeground': VoiceCallServiceRefusal.notInForeground,
        'refused': VoiceCallServiceRefusal.platformRefused,
      };
      for (final MapEntry(key: native, value: expected) in refusals.entries) {
        replies['start'] = (_) => <String, Object?>{'outcome': native};

        final outcome = await service().start();

        expect(
          outcome,
          isA<VoiceCallServiceRefused>().having(
            (refused) => refused.reason,
            'reason',
            expected,
          ),
          reason: native,
        );
      }
    });

    test('an answer it cannot read is a refusal too', () async {
      replies['microphoneGranted'] = (_) => true;
      for (final reply in <Object? Function(MethodCall)>[
        (_) => null,
        (_) => 'started',
        (_) => <String, Object?>{'outcome': 'running'},
        (_) => <String, Object?>{},
        (_) => throw PlatformException(code: 'boom'),
      ]) {
        replies['start'] = reply;

        expect(
          await service().start(),
          isA<VoiceCallServiceRefused>().having(
            (refused) => refused.reason,
            'reason',
            VoiceCallServiceRefusal.platformRefused,
          ),
        );
      }
      expect(methods(), isNot(contains('stop')));
    });

    test('a start it could not read is stopped on the platform', () async {
      // The native side said it started, but not in a form this code reads.
      // Reporting a refusal while the service ran would leave a microphone
      // notice for a call that was never joined.
      replies['microphoneGranted'] = (_) => true;
      replies['start'] = (_) => <String, Object?>{
        'outcome': 'started',
        'notificationVisible': 'yes',
      };

      final outcome = await service().start();

      expect(outcome, isA<VoiceCallServiceRefused>());
      expect(methods(), ['microphoneGranted', 'start', 'stop']);
    });

    test('a start that never lands is refused and stopped', () async {
      // The native side answers within its own bound, so this is a reply
      // lost on the way. Waiting on it forever would hold every stop queued
      // behind it, and the service it may still bring up must go when it does.
      replies['microphoneGranted'] = (_) => true;
      replies['start'] = (_) => Completer<Object?>().future;
      final adapter = PlatformVoiceCallService(
        microphone: const PlatformMicrophonePermission(),
        strings: () async => _strings,
        transitionDeadline: const Duration(milliseconds: 20),
      );

      final outcome = await adapter.start();

      expect(
        outcome,
        isA<VoiceCallServiceRefused>().having(
          (refused) => refused.reason,
          'reason',
          VoiceCallServiceRefusal.platformRefused,
        ),
      );
      expect(methods(), ['microphoneGranted', 'start', 'stop']);
      expect(
        PlatformVoiceCallService.defaultTransitionDeadline,
        greaterThan(const Duration(seconds: 10)),
        reason: 'longer than the native bound, so its answer comes first',
      );
    });

    test('no implementation is unavailable, and asks for nothing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(
        await service().start(),
        isA<VoiceCallServiceRefused>().having(
          (refused) => refused.reason,
          'reason',
          VoiceCallServiceRefusal.unavailable,
        ),
      );
      await service().stop();
      expect(calls, isEmpty);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      replies['microphoneGranted'] = (_) => true;
      replies['start'] = (_) => throw MissingPluginException();

      expect(
        await service().start(),
        isA<VoiceCallServiceRefused>().having(
          (refused) => refused.reason,
          'reason',
          VoiceCallServiceRefusal.unavailable,
        ),
      );
    });

    test(
      'a stop reaches the platform, and a failed one is not a crash',
      () async {
        await service().stop();
        replies['stop'] = (_) => throw PlatformException(code: 'boom');
        await service().stop();
        replies['stop'] = (_) => throw MissingPluginException();
        await service().stop();

        expect(methods(), ['stop', 'stop', 'stop']);
        expect(
          calls.map((call) => call.arguments),
          everyElement(isNull),
          reason: 'a stop carries nothing',
        );
      },
    );

    test(
      'starts and stops reach the platform one at a time, in order',
      () async {
        replies['microphoneGranted'] = (_) => true;
        final landing = Completer<Object?>();
        replies['start'] = (_) => landing.future;
        final adapter = service();

        final started = adapter.start();
        final stopped = adapter.stop();
        await pumpEventQueue();

        expect(methods(), [
          'microphoneGranted',
          'start',
        ], reason: 'the stop waits for the start it follows to land');

        landing.complete(_started());
        await started;
        await stopped;

        expect(methods(), ['microphoneGranted', 'start', 'stop']);
      },
    );
  });
}

const _strings = VoiceCallServiceStrings(
  title: 'Call in progress',
  channelName: 'Voice calls',
  channelDescription: 'Shown while you are in a call.',
);

Map<String, Object?> _started({bool notificationVisible = true}) => {
  'outcome': 'started',
  'notificationVisible': notificationVisible,
};

final class _Microphone implements MicrophonePermissionPort {
  _Microphone({required this.granted});

  bool granted;
  var checks = 0;
  var requests = 0;

  @override
  Future<bool> isGranted() async {
    checks += 1;
    return granted;
  }

  @override
  Future<MicrophonePermission> request() async {
    requests += 1;
    return MicrophonePermission.denied;
  }

  @override
  Future<void> openSettings() async {}
}
