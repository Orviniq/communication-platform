import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/realtime_gateway.dart';
import 'package:communication_platform/features/networking/domain/realtime_event.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// The `/ws` gateway, as the signalling transport's socket.
///
/// One for the process. The delivery session that owns the connection
/// attaches its gateway when it starts and detaches it when it stops, so a
/// signal travels over the same connection, the same session token and the
/// same provisioned trust as every durable wake-up, and there is never a second
/// socket for voice. With nothing attached a frame has nowhere to go, and
/// [sendSignal] says so rather than holding it.
final class GatewayVoiceSignalSocket implements VoiceSignalSocketPort {
  final _blobs = StreamController<String>.broadcast();
  RealtimeGateway? _gateway;
  StreamSubscription<RealtimeEvent>? _subscription;

  @override
  Stream<String> get inboundBlobs => _blobs.stream;

  /// Takes `signal` frames from [gateway] and sends through it, in place of
  /// whatever was attached before.
  Future<void> attach(RealtimeGateway gateway) async {
    await detach();
    _gateway = gateway;
    _subscription = gateway.events.listen((event) {
      if (event is RealtimeSignal && !_blobs.isClosed) {
        _blobs.add(event.blob);
      }
    });
  }

  /// Lets go of [gateway], when it is the one attached, or of whatever is
  /// attached when none is named. A session that stops after another has
  /// started detaches nothing of the newer one's.
  Future<void> detach([RealtimeGateway? gateway]) async {
    if (gateway != null && !identical(gateway, _gateway)) {
      return;
    }
    _gateway = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  Future<Result<void>> sendSignal({
    required String toDeviceId,
    required String blob,
  }) {
    final gateway = _gateway;
    if (gateway == null) {
      return Future.value(
        const Result.failure(TransportFailure(TransportFailureKind.offline)),
      );
    }
    return gateway.send({
      'type': 'signal',
      'to_device': toDeviceId,
      'blob': blob,
    });
  }

  Future<void> dispose() async {
    await detach();
    await _blobs.close();
  }
}
