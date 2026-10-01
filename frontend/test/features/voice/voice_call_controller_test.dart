import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/call_fakes.dart';

/// The join, in the order `backend/CLIENT_CONTRACT.md` §N rule 11 sets: the
/// microphone, then the call's service, then the call.
void main() {
  late List<String> log;
  late _Microphone microphone;
  late _Service service;
  late _Call call;
  late _Availability availability;
  late VoiceCallController controller;

  setUp(() {
    log = [];
    microphone = _Microphone(log);
    service = _Service(log);
    call = _Call(log);
    availability = _Availability();
    controller = VoiceCallController(
      call: call,
      microphone: microphone,
      service: service,
      availability: availability,
    );
  });

  tearDown(() => controller.dispose());

  test(
    'a grant starts the service, and only then does the call join',
    () async {
      final steps = <VoiceJoinStep>[];
      final subscription = controller.statuses.listen(
        (status) => steps.add(status.step),
      );

      final outcome = await controller.join(callRoomId);
      await pumpEventQueue();
      await subscription.cancel();

      expect(log, ['microphone', 'start', 'join $callRoomId']);
      expect(
        outcome,
        isA<VoiceJoinStarted>().having(
          (started) => started.notificationVisible,
          'notificationVisible',
          isTrue,
        ),
      );
      expect(steps, [
        VoiceJoinStep.idle,
        VoiceJoinStep.askingForMicrophone,
        VoiceJoinStep.startingService,
        VoiceJoinStep.joining,
        VoiceJoinStep.idle,
      ]);
      expect(controller.status.roomId, callRoomId);
      expect(controller.status.outcome, same(outcome));
    },
  );

  test('a denial starts nothing and joins nothing', () async {
    for (final (answer, permanently) in const [
      (MicrophonePermission.denied, false),
      (MicrophonePermission.deniedPermanently, true),
    ]) {
      log.clear();
      microphone.answer = answer;

      final outcome = await controller.join(callRoomId);

      expect(log, ['microphone'], reason: answer.name);
      expect(
        outcome,
        isA<VoiceJoinMicrophoneRefused>().having(
          (refused) => refused.permanently,
          'permanently',
          permanently,
        ),
      );
      expect(controller.status.outcome, same(outcome));
      expect(controller.status.isJoining, isFalse);
    }
  });

  test('a service that does not start keeps the call from joining', () async {
    service.answer = const VoiceCallServiceRefused(
      VoiceCallServiceRefusal.notInForeground,
    );

    final outcome = await controller.join(callRoomId);

    expect(log, ['microphone', 'start']);
    expect(
      outcome,
      isA<VoiceJoinServiceRefused>().having(
        (refused) => refused.reason,
        'reason',
        VoiceCallServiceRefusal.notInForeground,
      ),
    );
  });

  test('a server with no voice is refused before the microphone is asked '
      'for', () async {
    availability.available = false;

    final outcome = await controller.join(callRoomId);

    expect(log, isEmpty);
    expect(
      outcome,
      isA<VoiceJoinCallRefused>().having(
        (refused) => refused.reason,
        'reason',
        VoiceCallEndReason.voiceUnavailable,
      ),
    );
    expect(controller.isVoiceAvailable, isFalse);
  });

  test('a join the call refuses stops the service again', () async {
    final retryAt = DateTime.utc(2026, 10, 1, 12, 1);
    call.answer = VoiceJoinRefused(
      VoiceCallEndReason.throttled,
      retryAt: retryAt,
    );

    final outcome = await controller.join(callRoomId);

    expect(log, ['microphone', 'start', 'join $callRoomId', 'stop']);
    expect(
      outcome,
      isA<VoiceJoinCallRefused>()
          .having(
            (refused) => refused.reason,
            'reason',
            VoiceCallEndReason.throttled,
          )
          .having((refused) => refused.retryAt, 'retryAt', retryAt),
    );
  });

  test('a leave closes the call and stops the service', () async {
    await controller.join(callRoomId);
    log.clear();

    await controller.leave();

    expect(log, ['leave', 'stop']);
    expect(controller.status.outcome, isNull);
    expect(controller.status.isJoining, isFalse);
  });

  test('a leave while the microphone is asked for abandons the join', () async {
    final answer = Completer<MicrophonePermission>();
    microphone.pending = answer;

    final joining = controller.join(callRoomId);
    await pumpEventQueue();
    expect(controller.status.step, VoiceJoinStep.askingForMicrophone);
    await controller.leave();
    answer.complete(MicrophonePermission.granted);

    expect(await joining, isA<VoiceJoinAbandoned>());
    expect(log, ['microphone', 'leave', 'stop']);
    expect(controller.status.outcome, isNull);
  });

  test('a join while a call runs, or while one is asking, asks for '
      'nothing', () async {
    final answer = Completer<MicrophonePermission>();
    microphone.pending = answer;
    final first = controller.join(callRoomId);
    await pumpEventQueue();

    expect(
      await controller.join(callRoomId),
      isA<VoiceJoinCallRefused>().having(
        (refused) => refused.reason,
        'reason',
        VoiceCallEndReason.alreadyInCall,
      ),
    );
    answer.complete(MicrophonePermission.granted);
    await first;
    log.clear();
    call.active = true;

    expect(await controller.join(callRoomId), isA<VoiceJoinCallRefused>());
    expect(log, isEmpty, reason: 'the running call keeps its service');
  });

  test('the controller passes mute, room text and trying again to the '
      'call', () async {
    await controller.setMuted(true);
    await controller.sendRoomText('hello');
    await controller.tryAgain('device');

    expect(log, ['mute true', 'text', 'try again']);
  });

  test('an eleventh device is refused with the reason, and its service '
      'stops', () async {
    final mesh = CallMesh(accounts: 11);
    addTearDown(mesh.dispose);
    final ten = [
      for (var index = 0; index < 10; index += 1) mesh.device(index),
    ];
    await mesh.joinAll(ten);
    final eleventh = mesh.device(10);
    final eleventhLog = <String>[];
    final eleventhController = VoiceCallController(
      call: eleventh.engine,
      microphone: _Microphone(eleventhLog),
      service: _Service(eleventhLog),
      availability: _Availability(),
    );
    addTearDown(eleventhController.dispose);

    final joining = eleventhController.join(callRoomId);
    await mesh.clock.elapse(const Duration(seconds: 3));
    final outcome = await joining;

    expect(
      outcome,
      isA<VoiceJoinCallRefused>().having(
        (refused) => refused.reason,
        'reason',
        VoiceCallEndReason.callFull,
      ),
    );
    expect(eleventhLog, ['microphone', 'start', 'stop']);
    expect(eleventh.state.endReason, VoiceCallEndReason.callFull);
    expect(
      mesh.network.framesOf(VoiceSignalKind.join, from: eleventh.deviceId),
      isEmpty,
      reason: 'a full call is refused before this device announces itself',
    );
  });
}

final class _Microphone implements MicrophonePermissionPort {
  _Microphone(this.log);

  final List<String> log;
  var answer = MicrophonePermission.granted;
  Completer<MicrophonePermission>? pending;

  @override
  Future<MicrophonePermission> request() {
    log.add('microphone');
    return pending?.future ?? Future.value(answer);
  }

  @override
  Future<bool> isGranted() async => answer == MicrophonePermission.granted;
}

final class _Service implements VoiceCallServicePort {
  _Service(this.log);

  final List<String> log;
  VoiceCallServiceStart answer = const VoiceCallServiceRunning(
    notificationVisible: true,
  );

  @override
  Future<VoiceCallServiceStart> start() async {
    log.add('start');
    return answer;
  }

  @override
  Future<void> stop() async => log.add('stop');
}

final class _Call implements VoiceCallPort {
  _Call(this.log);

  final List<String> log;
  VoiceJoinOutcome answer = const VoiceJoinAnnounced();
  var active = false;

  @override
  VoiceCallState get state => active
      ? VoiceCallState(phase: VoiceCallPhase.inCall, roomId: callRoomId)
      : VoiceCallState.idle();

  @override
  Stream<VoiceCallState> get states => Stream.value(state);

  @override
  Future<VoiceJoinOutcome> join(String roomId) async {
    log.add('join $roomId');
    return answer;
  }

  @override
  Future<void> leave() async => log.add('leave');

  @override
  Future<Result<void>> sendRoomText(String text) async {
    log.add('text');
    return const Result.failure(
      CancellationFailure(CancellationFailureKind.lifecycleInterrupted),
    );
  }

  @override
  Future<void> setMuted(bool muted) async => log.add('mute $muted');

  @override
  Future<void> tryAgain(String deviceId) async => log.add('try again');
}

final class _Availability implements VoiceAvailabilityPort {
  var available = true;

  @override
  bool get isVoiceAvailable => available;
}
