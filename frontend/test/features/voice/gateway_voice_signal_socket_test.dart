import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/realtime_gateway.dart';
import 'package:communication_platform/features/networking/domain/realtime_event.dart';
import 'package:communication_platform/features/voice/infrastructure/gateway_voice_signal_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const device = '00000000-0000-4000-8000-000000000802';

  test(
    'sends a signal frame through the attached gateway, and only then',
    () async {
      final socket = GatewayVoiceSignalSocket();
      final gateway = _Gateway();

      final beforeAttach = await socket.sendSignal(
        toDeviceId: device,
        blob: 'b',
      );
      await socket.attach(gateway);
      final attached = await socket.sendSignal(
        toDeviceId: device,
        blob: 'blob',
      );
      await socket.detach(gateway);
      final afterDetach = await socket.sendSignal(
        toDeviceId: device,
        blob: 'b',
      );

      expect(
        (beforeAttach as FailureResult<void>).failure,
        isA<TransportFailure>(),
      );
      expect(attached, isA<Success<void>>());
      expect(afterDetach, isA<FailureResult<void>>());
      expect(gateway.sent, [
        {'type': 'signal', 'to_device': device, 'blob': 'blob'},
      ]);
      await socket.dispose();
      await gateway.close();
    },
  );

  test('passes on signal blobs and nothing else', () async {
    final socket = GatewayVoiceSignalSocket();
    final gateway = _Gateway();
    final blobs = <String>[];
    socket.inboundBlobs.listen(blobs.add);
    await socket.attach(gateway);

    gateway
      ..emit(const RealtimeSignal('first'))
      ..emit(
        const RealtimeEnvelope(
          id: '00000000-0000-4000-8000-000000000001',
          sequence: 1,
          blob: 'durable',
        ),
      )
      ..emit(const UnsupportedRealtimeEvent())
      ..emit(const RealtimeSignal('second'));
    await Future<void>.delayed(Duration.zero);

    expect(blobs, ['first', 'second']);
    await socket.dispose();
    await gateway.close();
  });

  test(
    'a session that stopped late detaches nothing of the next one',
    () async {
      final socket = GatewayVoiceSignalSocket();
      final stopped = _Gateway();
      final running = _Gateway();

      await socket.attach(stopped);
      await socket.attach(running);
      await socket.detach(stopped);

      expect(
        await socket.sendSignal(toDeviceId: device, blob: 'blob'),
        isA<Success<void>>(),
      );
      expect(running.sent, hasLength(1));
      expect(stopped.sent, isEmpty);
      await socket.dispose();
      await stopped.close();
      await running.close();
    },
  );
}

final class _Gateway implements RealtimeGateway {
  final _events = StreamController<RealtimeEvent>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];

  void emit(RealtimeEvent event) => _events.add(event);

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  Future<Result<void>> send(Map<String, Object?> frame) async {
    sent.add(frame);
    return const Result.success(null);
  }

  @override
  Future<Result<void>> connect() async => const Result.success(null);

  @override
  void markStableConnection() {}

  @override
  Future<void> close() => _events.close();
}
