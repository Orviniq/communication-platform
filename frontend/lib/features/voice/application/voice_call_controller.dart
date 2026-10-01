import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';

/// Where a join stands before the call's own phases take over.
enum VoiceJoinStep {
  /// Nothing is being asked.
  idle,

  /// Android's microphone dialog is up, or about to be.
  askingForMicrophone,

  /// The microphone is granted, and the call's service is starting.
  startingService,

  /// The service runs and the call is joining; the call's own state says
  /// how that goes.
  joining,
}

/// What one join came to, from the microphone to the call.
sealed class VoiceJoinAttempt {
  const VoiceJoinAttempt();
}

/// The call's `join` went out.
final class VoiceJoinStarted extends VoiceJoinAttempt {
  const VoiceJoinStarted({required this.notificationVisible});

  /// Whether the call's notice shows in the notification shade. With
  /// notifications off Android shows it only in the Task Manager, and the
  /// screen is the one place left that says a call is running.
  final bool notificationVisible;
}

/// The microphone was refused, so nothing started and nothing was sent.
final class VoiceJoinMicrophoneRefused extends VoiceJoinAttempt {
  const VoiceJoinMicrophoneRefused({required this.permanently});

  /// Android shows no dialog for it any more: only the system settings can
  /// allow it now.
  final bool permanently;
}

/// The microphone was granted but the call's service did not start, so the
/// call did not either: without the service Android takes the microphone
/// away the moment the user looks at another application, and the others
/// would hear silence with nothing to tell them why.
final class VoiceJoinServiceRefused extends VoiceJoinAttempt {
  const VoiceJoinServiceRefused(this.reason);

  final VoiceCallServiceRefusal reason;
}

/// The call refused the join, or ended before the join went out.
final class VoiceJoinCallRefused extends VoiceJoinAttempt {
  const VoiceJoinCallRefused(this.reason, {this.retryAt});

  final VoiceCallEndReason reason;

  /// For [VoiceCallEndReason.throttled]: when a join may ask again.
  final DateTime? retryAt;
}

/// The user left before the join finished. Whatever it had started has
/// stopped.
final class VoiceJoinAbandoned extends VoiceJoinAttempt {
  const VoiceJoinAbandoned();
}

/// The join as the screens see it: the step it is at, and how the last one
/// came out, for one room.
final class VoiceJoinStatus {
  const VoiceJoinStatus({
    this.step = VoiceJoinStep.idle,
    this.roomId,
    this.outcome,
  });

  final VoiceJoinStep step;

  /// The room the step, or the outcome, is about: the room state's hex id.
  final String? roomId;

  /// How the last join came out, until another one starts or the user leaves.
  final VoiceJoinAttempt? outcome;

  bool get isJoining => step != VoiceJoinStep.idle;

  @override
  String toString() =>
      'VoiceJoinStatus(${step.name}, outcome: ${outcome.runtimeType})';
}

/// Joins a call in the order `backend/CLIENT_CONTRACT.md` §N rule 11 sets,
/// and leaves it.
///
/// **A join** asks for the microphone, and nothing before it does: not
/// start-up, not a screen opening. On a grant it starts the call's
/// foreground service, and only once the service runs does it join, so the
/// capture never starts without the service that keeps it. A refusal at
/// either step stops the join there, with nothing sent; a refusal from the
/// call stops the service again. A deployment that serves no voice is
/// refused before the microphone is asked for at all.
///
/// **A leave** closes the call and stops the service, and abandons a join
/// still asking: whatever that join had started is stopped by the leave, and
/// it goes no further.
///
/// One join at a time, and none while a call runs: a call already running
/// keeps its service, and a second request is refused without asking for
/// anything.
final class VoiceCallController {
  VoiceCallController({
    required this.call,
    required this.microphone,
    required this.service,
    required this.availability,
  });

  final VoiceCallPort call;
  final MicrophonePermissionPort microphone;
  final VoiceCallServicePort service;
  final VoiceAvailabilityPort availability;

  final _statuses = StreamController<VoiceJoinStatus>.broadcast();
  var _status = const VoiceJoinStatus();

  /// Moves on every join, every leave and the disposal, so that a join
  /// overtaken by one of them stops at its next step.
  var _attempt = 0;
  var _disposed = false;

  VoiceJoinStatus get status => _status;

  /// The status now, then every change.
  Stream<VoiceJoinStatus> get statuses =>
      Stream<VoiceJoinStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _statuses.stream.listen(
          controller.add,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  /// Whether a call may be offered: the screens show no call control that
  /// can only fail when this is false.
  bool get isVoiceAvailable => availability.isVoiceAvailable;

  VoiceCallState get callState => call.state;

  /// The call now, then every change.
  Stream<VoiceCallState> get callStates => call.states;

  /// Joins a call in the room whose hex id is [roomId].
  Future<VoiceJoinAttempt> join(String roomId) async {
    final normalized = roomId.toLowerCase();
    if (_disposed || _status.isJoining || call.state.isActive) {
      return const VoiceJoinCallRefused(VoiceCallEndReason.alreadyInCall);
    }
    final attempt = ++_attempt;
    if (!availability.isVoiceAvailable) {
      return _finish(
        attempt,
        normalized,
        const VoiceJoinCallRefused(VoiceCallEndReason.voiceUnavailable),
      );
    }

    _publish(
      VoiceJoinStatus(
        step: VoiceJoinStep.askingForMicrophone,
        roomId: normalized,
      ),
    );
    final permission = await microphone.request();
    if (attempt != _attempt) {
      return const VoiceJoinAbandoned();
    }
    if (permission != MicrophonePermission.granted) {
      return _finish(
        attempt,
        normalized,
        VoiceJoinMicrophoneRefused(
          permanently: permission == MicrophonePermission.deniedPermanently,
        ),
      );
    }

    _publish(
      VoiceJoinStatus(step: VoiceJoinStep.startingService, roomId: normalized),
    );
    final started = await service.start();
    if (attempt != _attempt) {
      // The leave that overtook this join stopped the service, after this
      // start: starts and stops reach the platform in order.
      return const VoiceJoinAbandoned();
    }
    final bool notificationVisible;
    switch (started) {
      case VoiceCallServiceRefused(:final reason):
        return _finish(attempt, normalized, VoiceJoinServiceRefused(reason));
      case VoiceCallServiceRunning(notificationVisible: final visible):
        notificationVisible = visible;
    }

    _publish(VoiceJoinStatus(step: VoiceJoinStep.joining, roomId: normalized));
    final outcome = await call.join(normalized);
    if (attempt != _attempt) {
      return const VoiceJoinAbandoned();
    }
    switch (outcome) {
      case VoiceJoinAnnounced():
        return _finish(
          attempt,
          normalized,
          VoiceJoinStarted(notificationVisible: notificationVisible),
        );
      case VoiceJoinRefused(:final reason, :final retryAt):
        // The service guard stops the service when a call it saw start has
        // ended, but a join refused before the call published anything never
        // started one it could see. A stop is harmless when nothing runs.
        await service.stop();
        return _finish(
          attempt,
          normalized,
          VoiceJoinCallRefused(reason, retryAt: retryAt),
        );
    }
  }

  /// Leaves the call, or abandons a join still asking.
  Future<void> leave() async {
    _attempt += 1;
    _publish(const VoiceJoinStatus());
    await call.leave();
    await service.stop();
  }

  Future<void> setMuted(bool muted) => call.setMuted(muted);

  Future<Result<void>> sendRoomText(String text) => call.sendRoomText(text);

  /// Announces this device again to one peer that is not reachable.
  Future<void> tryAgain(String deviceId) => call.tryAgain(deviceId);

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _attempt += 1;
    await _statuses.close();
  }

  VoiceJoinAttempt _finish(
    int attempt,
    String roomId,
    VoiceJoinAttempt outcome,
  ) {
    if (attempt != _attempt) {
      return const VoiceJoinAbandoned();
    }
    _publish(VoiceJoinStatus(roomId: roomId, outcome: outcome));
    return outcome;
  }

  void _publish(VoiceJoinStatus status) {
    _status = status;
    if (!_statuses.isClosed) {
      _statuses.add(status);
    }
  }
}
