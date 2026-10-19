import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';

/// The `/ws` socket, as far as volatile `signal` frames need it.
abstract interface class SignalSocketPort implements Port {
  /// The blob of every `signal` frame the socket delivered, as it arrived.
  Stream<String> get inboundBlobs;

  /// Sends one `signal` frame. A failure means the socket did not take it,
  /// and nothing was sent.
  Future<Result<void>> sendSignal({
    required String toDeviceId,
    required String blob,
  });
}

/// A frame opened under its pairwise session and not yet committed.
abstract interface class SignalOpening {
  /// The device the pairwise session authenticated.
  String get senderUserId;
  String get senderDeviceId;

  Uint8List get payload;

  /// Writes what opening the frame advanced.
  Future<Result<void>> commit();
}

/// Opens one frame under its pairwise session, writing nothing.
abstract interface class SignalOpenPort implements Port {
  Future<Result<SignalOpening>> open(Uint8List frame);
}

/// The deployment's published `signal_buckets`, read when asked.
abstract interface class SignalBucketsPort implements Port {
  Set<int> get signalBuckets;
}

/// Waits, so that a test can move time instead of spending it.
abstract interface class SignalTimerPort implements Port {
  Future<void> wait(Duration duration);
}
