import 'dart:async';

import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/voice_call_service_guard.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The call service never outlives the call (§N rule 11).
///
/// The guard is driven here by a call-state stream shaped like the engine's -
/// the current state first, then every change - and stops the real adapter, so
/// what is asserted is that the stop reaches the platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(VoiceCallChannel.name);
  late List<String> native;
  late StreamController<VoiceCallState> calls;

  setUp(() {
    native = [];
    calls = StreamController<VoiceCallState>.broadcast();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          native.add(call.method);
          return switch (call.method) {
            'microphoneGranted' => true,
            'start' => <String, Object?>{
              'outcome': 'started',
              'notificationVisible': true,
            },
            _ => null,
          };
        });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await calls.close();
  });

  VoiceCallServiceGuard guardOver(
    Stream<VoiceCallState> states, {
    VoiceCallServicePort? service,
  }) {
    final guard = VoiceCallServiceGuard(
      service:
          service ??
          PlatformVoiceCallService(
            microphone: const PlatformMicrophonePermission(),
            strings: () async => const VoiceCallServiceStrings(
              title: 'Call in progress',
              channelName: 'Voice calls',
              channelDescription: 'Shown while you are in a call.',
            ),
          ),
      calls: states,
    );
    addTearDown(guard.dispose);
    return guard;
  }

  Future<void> publish(VoiceCallState state) async {
    calls.add(state);
    await pumpEventQueue();
  }

  test('the stop reaches the native side when the call ends', () async {
    final guard = guardOver(calls.stream);

    expect(await guard.start(), isA<VoiceCallServiceRunning>());
    await publish(_state(VoiceCallPhase.preparing));
    await publish(_state(VoiceCallPhase.announcing));
    await publish(_state(VoiceCallPhase.inCall));

    expect(native, ['microphoneGranted', 'start'], reason: 'still in a call');

    await publish(_ended(VoiceCallEndReason.left));

    expect(native, ['microphoneGranted', 'start', 'stop']);
  });

  test(
    'the stop reaches the native side when the Dart side detaches',
    () async {
      final guard = guardOver(calls.stream);
      await guard.start();
      await publish(_state(VoiceCallPhase.inCall));

      await guard.dispose();

      expect(native, ['microphoneGranted', 'start', 'stop']);

      // Detached for good: the call it held can end without it, and nothing
      // starts again through it.
      await publish(_ended(VoiceCallEndReason.left));
      expect(
        await guard.start(),
        isA<VoiceCallServiceRefused>().having(
          (refused) => refused.reason,
          'reason',
          VoiceCallServiceRefusal.unavailable,
        ),
      );
      expect(native, ['microphoneGranted', 'start', 'stop']);
    },
  );

  test('every way a call ends stops it, not only a leave', () async {
    for (final reason in VoiceCallEndReason.values) {
      native.clear();
      final states = StreamController<VoiceCallState>.broadcast();
      addTearDown(states.close);
      final guard = guardOver(states.stream);

      await guard.start();
      states.add(_state(VoiceCallPhase.preparing));
      states.add(_ended(reason));
      await pumpEventQueue();

      expect(native.last, 'stop', reason: reason.name);
    }
  });

  test('a join refused as it began stops it too', () async {
    // The engine publishes `preparing` before it checks the room and mints
    // the credential, so a refusal there is an end like any other.
    final guard = guardOver(calls.stream);
    await guard.start();

    await publish(_state(VoiceCallPhase.preparing));
    await publish(_ended(VoiceCallEndReason.callFull));

    expect(native, ['microphoneGranted', 'start', 'stop']);
  });

  test('the end of the previous call does not stop a new one', () async {
    // The engine's stream opens with its current state. Heard after a start,
    // the end a past call left there must not undo the service a new join
    // has just started.
    final states = _Replaying(_ended(VoiceCallEndReason.left));
    addTearDown(states.close);
    final guard = guardOver(states.stream);

    await guard.start();
    await pumpEventQueue();

    expect(native, ['microphoneGranted', 'start']);

    states.add(_state(VoiceCallPhase.preparing));
    states.add(_state(VoiceCallPhase.inCall));
    await pumpEventQueue();
    expect(native, ['microphoneGranted', 'start']);

    states.add(_ended(VoiceCallEndReason.left));
    await pumpEventQueue();
    expect(native, ['microphoneGranted', 'start', 'stop']);
  });

  test('a call already running when it attaches is held to its end', () async {
    final states = _Replaying(_state(VoiceCallPhase.inCall));
    addTearDown(states.close);
    guardOver(states.stream);
    await pumpEventQueue();

    states.add(_ended(VoiceCallEndReason.removedFromRoom));
    await pumpEventQueue();

    expect(native, ['stop']);
  });

  test('the engine going away mid-call stops it', () async {
    final guard = guardOver(calls.stream);
    await guard.start();
    await publish(_state(VoiceCallPhase.inCall));

    await calls.close();
    await pumpEventQueue();

    expect(native, ['microphoneGranted', 'start', 'stop']);
  });

  test('changes inside a call stop nothing', () async {
    final service = _Service();
    guardOver(calls.stream, service: service);

    await publish(_state(VoiceCallPhase.announcing));
    await publish(_state(VoiceCallPhase.inCall));
    await publish(_state(VoiceCallPhase.inCall));
    await publish(_state(VoiceCallPhase.inCall));

    expect(service.stops, 0);

    await publish(_ended(VoiceCallEndReason.leftRoom));
    await publish(VoiceCallState.idle());

    expect(service.stops, 1, reason: 'one end, one stop');
  });
}

VoiceCallState _state(VoiceCallPhase phase) =>
    VoiceCallState(phase: phase, roomId: 'ab' * 32);

VoiceCallState _ended(VoiceCallEndReason reason) => VoiceCallState(
  phase: VoiceCallPhase.ended,
  roomId: 'ab' * 32,
  endReason: reason,
);

/// A stream shaped like `VoiceCallEngine.states`: the current state to each
/// new listener first, then every change.
final class _Replaying {
  _Replaying(this._current);

  VoiceCallState _current;
  final _changes = StreamController<VoiceCallState>.broadcast();

  Stream<VoiceCallState> get stream =>
      Stream<VoiceCallState>.multi((controller) {
        controller.add(_current);
        final subscription = _changes.stream.listen(
          controller.add,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  void add(VoiceCallState state) {
    _current = state;
    _changes.add(state);
  }

  Future<void> close() => _changes.close();
}

final class _Service implements VoiceCallServicePort {
  var stops = 0;

  @override
  Future<VoiceCallServiceStart> start() async =>
      const VoiceCallServiceRunning(notificationVisible: true);

  @override
  Future<void> stop() async {
    stops += 1;
  }
}
