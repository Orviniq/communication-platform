// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';

/// The call service, held to the call (`backend/CLIENT_CONTRACT.md` §N rule
/// 11): it runs for as long as the call lasts and never longer.
///
/// The join starts it through [start], after the microphone grant and before
/// the join itself. From then on this stops it, whoever ended the call:
///
/// - **when the call ends**, for whatever reason - the user left, the room
///   removed this account, the call was full, a credential or a connection
///   failed - because every end publishes an ended call;
/// - **when it is disposed**, which is the Dart side detaching. When the
///   engine itself goes, Dart can no longer say so, and the native side stops
///   the service on its own (`VoiceCall.detach`).
///
/// It stops on a call that was active and is no longer, not on whatever state
/// it first hears: the call's stream opens with its current state, and an end
/// left over from the previous call must not stop the service a new join has
/// just started. One join publishes nothing: one refused because its room id
/// cannot be read, so a caller that started the service for it stops it.
///
/// It reads the call's state and changes nothing in the call.
final class VoiceCallServiceGuard implements VoiceCallServicePort {
  VoiceCallServiceGuard({
    required VoiceCallServicePort service,
    required Stream<VoiceCallState> calls,
  }) : _service = service {
    _calls = calls.listen(_onCall, onDone: _onCallsClosed);
  }

  final VoiceCallServicePort _service;
  late final StreamSubscription<VoiceCallState> _calls;
  var _callActive = false;
  var _disposed = false;

  @override
  Future<VoiceCallServiceStart> start() async {
    if (_disposed) {
      return const VoiceCallServiceRefused(VoiceCallServiceRefusal.unavailable);
    }
    return _service.start();
  }

  @override
  Future<void> stop() => _service.stop();

  /// Detaches from the call and stops the service. A service with no Dart
  /// side left to end it would outlive its call.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _callActive = false;
    await _calls.cancel();
    await _service.stop();
  }

  void _onCall(VoiceCallState state) {
    if (state.isActive) {
      _callActive = true;
      return;
    }
    if (_callActive) {
      _callActive = false;
      unawaited(_service.stop());
    }
  }

  /// The engine went away. Its last call ended with it, published or not.
  void _onCallsClosed() {
    if (_callActive) {
      _callActive = false;
      unawaited(_service.stop());
    }
  }
}
