import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// A clock that moves only when [advance] or [FakeSignalTimer] moves it.
final class FakeSignalClock implements TimeSource {
  FakeSignalClock([DateTime? start])
    : _now = start ?? DateTime.utc(2026, 9, 30, 12);

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// Waits by moving [clock], so that a test spends no real time and every
/// wait is on the record.
final class FakeSignalTimer implements VoiceSignalTimerPort {
  FakeSignalTimer(this.clock);

  final FakeSignalClock clock;
  final waits = <Duration>[];

  @override
  Future<void> wait(Duration duration) {
    waits.add(duration);
    clock.advance(duration);
    return Future<void>.value();
  }
}

/// A timer whose waits complete only when the test says so.
final class HeldSignalTimer implements VoiceSignalTimerPort {
  final _held = <(Duration, Completer<void>)>[];

  List<Duration> get pending => [for (final (duration, _) in _held) duration];

  @override
  Future<void> wait(Duration duration) {
    final completer = Completer<void>();
    _held.add((duration, completer));
    return completer.future;
  }

  void releaseAll() {
    final held = List.of(_held);
    _held.clear();
    for (final (_, completer) in held) {
      completer.complete();
    }
  }
}

final class SentSignal {
  const SentSignal({
    required this.toDeviceId,
    required this.blob,
    required this.at,
  });

  final String toDeviceId;
  final String blob;
  final DateTime at;
}

/// The socket: every frame handed to it, with the moment it was handed.
final class FakeSignalSocket implements VoiceSignalSocketPort {
  FakeSignalSocket(this.clock);

  final TimeSource clock;
  final sent = <SentSignal>[];
  final _inbound = StreamController<String>.broadcast(sync: true);
  var connected = true;

  @override
  Stream<String> get inboundBlobs => _inbound.stream;

  void deliver(String blob) => _inbound.add(blob);

  @override
  Future<Result<void>> sendSignal({
    required String toDeviceId,
    required String blob,
  }) async {
    if (!connected) {
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    }
    sent.add(SentSignal(toDeviceId: toDeviceId, blob: blob, at: clock.now()));
    return const Result.success(null);
  }

  Future<void> close() => _inbound.close();
}

typedef SealAnswer =
    Result<List<VoiceSealOutcome>> Function(
      Uint8List payload,
      List<VoiceSignalTarget> targets,
    );

/// A sealer that answers from [answer], and by default seals every target
/// into a frame of [frameLength] bytes.
final class FakeSignalSealer implements VoiceSignalSealPort {
  FakeSignalSealer({this.frameLength = 1024, this.answer});

  final int frameLength;
  SealAnswer? answer;
  final calls = <List<VoiceSignalTarget>>[];
  final payloads = <Uint8List>[];

  @override
  Future<Result<List<VoiceSealOutcome>>> seal({
    required Uint8List payload,
    required List<VoiceSignalTarget> targets,
    required Set<int> allowedLengths,
  }) async {
    calls.add(List.of(targets));
    payloads.add(payload);
    final custom = answer;
    if (custom != null) {
      return custom(payload, targets);
    }
    return Result.success([
      for (final target in targets)
        VoiceSealed(target, Uint8List(frameLength)..[0] = calls.length),
    ]);
  }
}

final class FakeOpening implements VoiceSignalOpening {
  FakeOpening({
    required this.senderUserId,
    required this.senderDeviceId,
    required this.payload,
    this.commitResult = const Result.success(null),
  });

  @override
  final String senderUserId;
  @override
  final String senderDeviceId;
  @override
  final Uint8List payload;
  final Result<void> commitResult;
  var commits = 0;

  @override
  Future<Result<void>> commit() async {
    commits += 1;
    return commitResult;
  }
}

/// Opens a frame by looking up its first byte in [openings].
final class FakeSignalOpener implements VoiceSignalOpenPort {
  final openings = <int, FakeOpening>{};
  final opened = <Uint8List>[];
  Completer<void>? gate;

  @override
  Future<Result<VoiceSignalOpening>> open(Uint8List frame) async {
    opened.add(frame);
    final held = gate;
    if (held != null) {
      await held.future;
    }
    final opening = openings[frame[0]];
    if (opening == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(opening);
  }
}

final class FixedSignalBuckets implements VoiceSignalBucketsPort {
  const FixedSignalBuckets([this.signalBuckets = const {1024, 4096, 16384}]);

  @override
  final Set<int> signalBuckets;
}
