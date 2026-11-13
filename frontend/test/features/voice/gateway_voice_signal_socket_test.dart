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

  test('isOpen and opens follow the attached gateway', () async {
    final socket = GatewayVoiceSignalSocket();
    final first = _Gateway();
    final second = _Gateway();
    var opens = 0;
    // Subscribed before anything is attached, as the presence channel is.
    final subscription = socket.opens.listen((_) => opens += 1);

    expect(socket.isOpen, isFalse);

    await socket.attach(first);
    expect(socket.isOpen, isFalse, reason: 'the gateway has no connection');
    first.becomeOpen();
    await Future<void>.delayed(Duration.zero);
    expect(socket.isOpen, isTrue);
    expect(opens, 1);

    await socket.detach(first);
    expect(socket.isOpen, isFalse, reason: 'nothing is attached');
    first.becomeOpen();
    await Future<void>.delayed(Duration.zero);
    expect(opens, 1, reason: 'a detached gateway is not listened to');

    await socket.attach(second);
    expect(socket.isOpen, isFalse);
    second.becomeOpen();
    await Future<void>.delayed(Duration.zero);
    expect(opens, 2, reason: 'the same stream, across attach and detach');
    second.open = false;
    expect(socket.isOpen, isFalse);

    await subscription.cancel();
    await socket.dispose();
    await first.close();
    await second.close();
  });

  test('with no gateway attached nothing is open and a frame is refused as '
      'offline', () async {
    final socket = GatewayVoiceSignalSocket();

    expect(socket.isOpen, isFalse);
    final sent = await socket.sendSignal(toDeviceId: device, blob: 'blob');
    expect(sent, isA<FailureResult<void>>());
    expect(
      (sent as FailureResult<void>).failure,
      isA<TransportFailure>().having(
        (failure) => failure.kind,
        'kind',
        TransportFailureKind.offline,
      ),
    );
    await socket.dispose();
  });
}

final class _Gateway implements RealtimeGateway {
  final _events = StreamController<RealtimeEvent>.broadcast(sync: true);
  final _opens = StreamController<void>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];
  var open = false;

  void emit(RealtimeEvent event) => _events.add(event);

  /// The connection becomes ready: [isOpen] turns true, then [opens] emits.
  void becomeOpen() {
    open = true;
    _opens.add(null);
  }

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  bool get isOpen => open;

  @override
  Stream<void> get opens => _opens.stream;

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
  Future<void> close() async {
    open = false;
    await _events.close();
    await _opens.close();
  }
}
