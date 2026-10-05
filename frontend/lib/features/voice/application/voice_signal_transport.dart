import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/signal_frame_pacer.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// The call's signalling transport: `CPVSV001` messages carried one device to
/// another in volatile `signal` frames (`voice-signalling-v1.md`, Part 2).
///
/// **Out.** A message is encoded once, sealed to each target device's
/// pairwise session, and every advanced session state is committed before any
/// frame leaves; no outbox row is written, because a frame is delivered at
/// once or never. Each frame is then paced through [SignalFramePacer] and
/// handed to the socket as standard base64 of one published signal bucket. A
/// join seals at most [volatileBudgetPerPeer] frames to one device, because
/// every frame the relay drops costs that device pair a dead skipped key.
///
/// **In.** The socket reader never decrypts. A frame goes onto a queue of
/// [inboundQueueCapacity], and past it the oldest is dropped, as the relay
/// would have dropped it; one worker opens them in order. A frame is opened
/// under its session exactly as a durable envelope is, and committed only when
/// its payload is `CPVSV001`, so the ciphertext of anything else is left for
/// the channel it belongs to. A message whose header names a sender other than
/// the device the session authenticated is dropped.
///
/// Opening and sealing take turns, so that they never race each other's
/// compare-and-set on one session. A commit that loses to the durable path
/// is tried once more from the fresh state.
///
/// Nothing here holds a room, a participant or a retry, and nothing is
/// logged: the call decides who to send what to, and when to try again.
final class VoiceSignalTransport implements VoiceSignallingPort {
  VoiceSignalTransport({
    required this.currentUserId,
    required this.currentDeviceId,
    required this.socket,
    required this.sealer,
    required this.opener,
    required this.buckets,
    required this.clock,
    required VoiceSignalTimerPort timer,
  }) : _pacer = SignalFramePacer(clock: clock, timer: timer);

  /// Sealed frames one join sends one device (`voice-signalling-v1.md`,
  /// "Volatile seal and open").
  static const volatileBudgetPerPeer = 32;

  /// Inbound frames held for the worker. The server holds 256 undelivered
  /// frames for a socket before it closes it, so a reader never needs more.
  static const inboundQueueCapacity = 256;

  /// Joins whose budget is remembered. A device is in one call at a time, so
  /// this only bounds a caller that never forgets a join.
  static const _rememberedJoins = 8;

  final String currentUserId;
  final String currentDeviceId;
  final VoiceSignalSocketPort socket;
  final VoiceSignalSealPort sealer;
  final VoiceSignalOpenPort opener;
  final VoiceSignalBucketsPort buckets;
  final TimeSource clock;
  final SignalFramePacer _pacer;

  final _inbound = StreamController<InboundVoiceSignal>.broadcast();
  final _queue = ListQueue<String>();
  final _budgets = <String, Map<String, int>>{};
  StreamSubscription<String>? _subscription;
  Future<void> _turn = Future<void>.value();
  var _draining = false;
  var _closed = false;

  @override
  Stream<InboundVoiceSignal> get inbound => _inbound.stream;

  /// Starts taking frames off the socket.
  void start() {
    if (_closed) {
      return;
    }
    _subscription ??= socket.inboundBlobs.listen(_enqueue);
  }

  Future<void> dispose() async {
    _closed = true;
    _queue.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _inbound.close();
  }

  @override
  void forgetJoin(Uint8List joinId) =>
      _budgets.remove(protocolBytesToHex(joinId));

  @override
  Future<Result<List<VoiceSignalDelivery>>> send({
    required Uint8List roomId,
    required Uint8List joinId,
    required int counter,
    required VoiceSignalBody body,
    required List<VoiceSignalTarget> targets,
  }) async {
    if (_closed) {
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    }
    final VoiceSignalMessage message;
    try {
      message = VoiceSignalMessage(
        header: VoiceSignalHeader(
          roomId: roomId,
          joinId: joinId,
          senderUserId: protocolUuidBytes(currentUserId),
          senderDeviceId: protocolUuidBytes(currentDeviceId),
          counter: counter,
          createdMs: clock.now().toUtc().millisecondsSinceEpoch,
        ),
        body: body,
      );
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (!_isDeviceSet(targets)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final encoded = VoiceSignalCodec.encode(message);
    if (encoded case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final payload = (encoded as Success<Uint8List>).value;

    final prepared = await _exclusively(
      () => _sealAndQueue(
        payload: payload,
        joinKey: protocolBytesToHex(joinId),
        targets: targets,
      ),
    );
    final deliveries = <VoiceSignalDelivery>[];
    for (final item in prepared) {
      switch (item) {
        case _Refused(:final target, :final reason):
          deliveries.add(VoiceSignalNotSent(target, reason));
        case _Queued(:final target, :final blob, :final slot):
          await slot;
          final sent = await socket.sendSignal(
            toDeviceId: target.deviceId,
            blob: blob,
          );
          deliveries.add(
            sent is Success<void>
                ? VoiceSignalSent(target)
                : VoiceSignalNotSent(
                    target,
                    VoiceSignalRefusal.socketUnavailable,
                  ),
          );
      }
    }
    return Result.success(List.unmodifiable(deliveries));
  }

  /// Seals, commits, counts each sealed frame against its budget and takes a
  /// pacing slot for it, all in one turn, so that frames leave in the order
  /// their sessions advanced.
  Future<List<_Prepared>> _sealAndQueue({
    required Uint8List payload,
    required String joinKey,
    required List<VoiceSignalTarget> targets,
  }) async {
    final budget = _budgetFor(joinKey);
    final prepared = <VoiceSignalTarget, _Prepared>{};
    final eligible = <VoiceSignalTarget>[];
    for (final target in targets) {
      if ((budget[_deviceKey(target)] ?? 0) >= volatileBudgetPerPeer) {
        prepared[target] = _Refused(target, VoiceSignalRefusal.budgetExhausted);
      } else {
        eligible.add(target);
      }
    }
    if (eligible.isNotEmpty) {
      final published = buckets.signalBuckets;
      var sealed = await sealer.seal(
        payload: payload,
        targets: eligible,
        allowedLengths: published,
      );
      if (_isConflict(sealed)) {
        sealed = await sealer.seal(
          payload: payload,
          targets: eligible,
          allowedLengths: published,
        );
      }
      if (sealed case FailureResult()) {
        // Nothing was committed and no frame exists.
        for (final target in eligible) {
          prepared[target] = _Refused(target, VoiceSignalRefusal.sealFailed);
        }
      } else {
        final outcomes = (sealed as Success<List<VoiceSealOutcome>>).value;
        for (var index = 0; index < eligible.length; index += 1) {
          final target = eligible[index];
          final outcome = index < outcomes.length ? outcomes[index] : null;
          if (outcome == null ||
              _deviceKey(outcome.target) != _deviceKey(target)) {
            prepared[target] = _Refused(target, VoiceSignalRefusal.sealFailed);
            continue;
          }
          switch (outcome) {
            case VoiceSealRefused(:final reason):
              prepared[target] = _Refused(target, reason);
            case VoiceSealed(:final frame):
              budget[_deviceKey(target)] =
                  (budget[_deviceKey(target)] ?? 0) + 1;
              // The seal already refused an off-bucket frame. This is the
              // rule restated at the last point before the socket.
              prepared[target] = published.contains(frame.length)
                  ? _Queued(target, base64.encode(frame), _pacer.acquire())
                  : _Refused(target, VoiceSignalRefusal.offBucket);
          }
        }
      }
    }
    return [
      for (final target in targets)
        prepared[target] ?? _Refused(target, VoiceSignalRefusal.sealFailed),
    ];
  }

  void _enqueue(String blob) {
    if (_closed) {
      return;
    }
    if (_queue.length >= inboundQueueCapacity) {
      _queue.removeFirst();
    }
    _queue.addLast(blob);
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_closed) {
        final blob = _queue.removeFirst();
        final received = await _exclusively(() => _receive(blob));
        if (received != null && !_closed) {
          _inbound.add(received);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<InboundVoiceSignal?> _receive(String blob) async {
    final frame = _decodeBlob(blob);
    if (frame == null) {
      return null;
    }
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final openedResult = await opener.open(frame);
      if (openedResult case FailureResult()) {
        return null;
      }
      final opening = (openedResult as Success<VoiceSignalOpening>).value;
      final decoding = VoiceSignalCodec.decode(opening.payload);
      if (decoding is NotVoiceSignal) {
        // Not the call's. Left unopened, so a durable envelope the relay
        // replayed as a signal still opens where it belongs.
        return null;
      }
      final committed = await opening.commit();
      if (committed case FailureResult(failure: final failure)) {
        if (_isConflictFailure(failure)) {
          continue;
        }
        return null;
      }
      return switch (decoding) {
        DecodedVoiceSignal(:final message) =>
          _isFromSender(message.header, opening)
              ? ReceivedVoiceSignal(
                  senderUserId: opening.senderUserId,
                  senderDeviceId: opening.senderDeviceId,
                  message: message,
                )
              : null,
        UnsupportedVoiceSignalVersion(:final version) => UnsupportedVoiceSignal(
          senderUserId: opening.senderUserId,
          senderDeviceId: opening.senderDeviceId,
          version: version,
        ),
        UnknownVoiceSignalKind() || MalformedVoiceSignal() => null,
        NotVoiceSignal() => null,
      };
    }
    return null;
  }

  /// The frame, when [blob] is standard base64 of exactly one published
  /// signal bucket. The gateway already dropped anything else; this holds
  /// the same rule at the one place a frame is opened.
  Uint8List? _decodeBlob(String blob) {
    final published = buckets.signalBuckets;
    if (blob.isEmpty ||
        blob.length % 4 != 0 ||
        !published.any((bucket) => blob.length == (bucket + 2) ~/ 3 * 4) ||
        !_standardBase64.hasMatch(blob)) {
      return null;
    }
    try {
      final frame = base64.decode(blob);
      return published.contains(frame.length) ? frame : null;
    } on FormatException {
      return null;
    }
  }

  /// The sender a header names must be the device the session authenticated.
  bool _isFromSender(VoiceSignalHeader header, VoiceSignalOpening opening) {
    try {
      return _same(
            header.senderUserId,
            protocolUuidBytes(opening.senderUserId),
          ) &&
          _same(
            header.senderDeviceId,
            protocolUuidBytes(opening.senderDeviceId),
          );
    } on FormatException {
      return false;
    }
  }

  bool _isDeviceSet(List<VoiceSignalTarget> targets) {
    final own = currentDeviceId.toLowerCase();
    final seen = <String>{};
    return targets.isNotEmpty &&
        targets.every((target) {
          final key = _deviceKey(target);
          return _uuid.hasMatch(target.userId) &&
              _uuid.hasMatch(target.deviceId) &&
              key != own &&
              seen.add(key);
        });
  }

  Map<String, int> _budgetFor(String joinKey) {
    final existing = _budgets.remove(joinKey);
    final budget = existing ?? <String, int>{};
    _budgets[joinKey] = budget;
    while (_budgets.length > _rememberedJoins) {
      _budgets.remove(_budgets.keys.first);
    }
    return budget;
  }

  Future<T> _exclusively<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static String _deviceKey(VoiceSignalTarget target) =>
      target.deviceId.toLowerCase();

  static bool _isConflict(Result<Object?> result) =>
      result is FailureResult<Object?> && _isConflictFailure(result.failure);

  static bool _isConflictFailure(Failure failure) =>
      failure is ValidationFailure &&
      failure.kind == ValidationFailureKind.conflict;
}

sealed class _Prepared {
  const _Prepared(this.target);

  final VoiceSignalTarget target;
}

final class _Refused extends _Prepared {
  const _Refused(super.target, this.reason);

  final VoiceSignalRefusal reason;
}

final class _Queued extends _Prepared {
  const _Queued(super.target, this.blob, this.slot);

  final String blob;

  /// Completes when the pacer lets this frame leave.
  final Future<void> slot;
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

final RegExp _standardBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
