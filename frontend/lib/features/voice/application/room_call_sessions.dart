import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/application/room_outbound_dispatcher.dart';
import 'package:communication_platform/features/voice/application/room_session_starter.dart';

/// The call's check before its join, on the room's own machinery: a session is
/// started with every live device of every active member that has none, and
/// the room's outbound work — those requests among it — is routed into the
/// pairwise outbox, whose growth wakes the delivery cycle that sends it.
final class RoomCallSessions implements VoiceCallSessionsPort {
  const RoomCallSessions({
    required this.starter,
    required this.dispatcher,
    required this.currentUserId,
    required this.currentDeviceId,
  });

  final RoomSessionStarter starter;
  final RoomOutboundDispatcher dispatcher;
  final String currentUserId;
  final String currentDeviceId;

  @override
  Future<Result<void>> prepareSessionsForCall(String roomId) async {
    final started = await starter.startSessionsForCall(roomId);
    // Whatever the check came to, the room's owed payloads are routed: an
    // earlier request that never left starts its session just as well.
    final routed = await dispatcher.dispatchPending(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
    );
    return switch ((started, routed)) {
      (FailureResult(:final failure), _) => Result.failure(failure),
      (_, FailureResult(:final failure)) => Result.failure(failure),
      _ => const Result.success(null),
    };
  }
}
