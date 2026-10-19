import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/signal_ports.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';

/// A volatile channel, named by the 8 bytes its plaintext begins with
/// (ADR-098 D1).
enum SignalChannel {
  /// `CPVSV001`, a call's signalling (`voice-signalling-v1.md`, Part 2).
  voice([0x43, 0x50, 0x56, 0x53, 0x56, 0x30, 0x30, 0x31]),

  /// `CPPSV001`, typing and the online status (ADR-098 D2).
  presence([0x43, 0x50, 0x50, 0x53, 0x56, 0x30, 0x30, 0x31]);

  const SignalChannel(this.magic);

  final List<int> magic;

  /// Whether [payload] begins with this channel's magic.
  bool matches(List<int> payload) {
    if (payload.length < magic.length) {
      return false;
    }
    for (var index = 0; index < magic.length; index += 1) {
      if (payload[index] != magic[index]) {
        return false;
      }
    }
    return true;
  }

  /// The channel [payload] claims, or null when it claims none.
  static SignalChannel? of(List<int> payload) {
    for (final channel in values) {
      if (channel.matches(payload)) {
        return channel;
      }
    }
    return null;
  }
}

/// A frame opened under its session and committed, for its channel to read.
///
/// [senderUserId] and [senderDeviceId] are the device the pairwise session
/// authenticated. Whether the payload names the same device is the channel's
/// to check, after the commit.
final class RoutedSignal {
  RoutedSignal({
    required this.senderUserId,
    required this.senderDeviceId,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  final String senderUserId;
  final String senderDeviceId;
  final Uint8List payload;

  @override
  String toString() => 'RoutedSignal(<redacted>)';
}

/// The device a committed frame came from, on whichever channel.
final class SignalHeard {
  const SignalHeard({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  @override
  String toString() => 'SignalHeard(<redacted>)';
}

/// The one reader of inbound `signal` frames (ADR-098 D1).
///
/// The socket reader never decrypts. A blob goes onto a queue of
/// [inboundQueueCapacity], and past it the oldest is dropped, as the relay
/// would have dropped it; one worker opens them in arrival order, whatever
/// their channel. Each blob is checked against the published buckets, opened
/// once under its session, and routed by the first 8 bytes of its plaintext.
///
/// **The commit rule.** A frame whose magic names a routed channel is
/// committed before the channel reads the rest, so that a malformed body, an
/// unknown kind or a sender the channel refuses still consumes its ratchet
/// step: a step left uncommitted makes the next message of that chain leave a
/// dead skipped key here. Anything else is dropped with its step uncommitted,
/// so a durable envelope the relay replayed as a signal still opens where it
/// belongs. A commit that loses to the durable path is tried once more from
/// the fresh state.
///
/// Opening and every channel's sealing take turns through [exclusively], so
/// that they never race each other's compare-and-set on one session.
///
/// Nothing is logged.
final class SignalRouter {
  SignalRouter({
    required this.socket,
    required this.opener,
    required this.buckets,
    Set<SignalChannel> channels = const {
      SignalChannel.voice,
      SignalChannel.presence,
    },
  }) : _channels = {
         for (final channel in channels)
           channel: StreamController<RoutedSignal>.broadcast(),
       };

  /// Inbound frames held for the worker. The server holds 256 undelivered
  /// frames for a socket before it closes it, so a reader never needs more.
  static const inboundQueueCapacity = 256;

  final SignalSocketPort socket;
  final SignalOpenPort opener;
  final SignalBucketsPort buckets;

  final Map<SignalChannel, StreamController<RoutedSignal>> _channels;
  final _heard = StreamController<SignalHeard>.broadcast();
  final _queue = ListQueue<String>();
  StreamSubscription<String>? _subscription;
  Future<void> _turn = Future<void>.value();
  var _draining = false;
  var _closed = false;

  /// Every committed frame of [channel], in the order it was opened. Nothing
  /// is replayed to a late listener. A channel this router does not route has
  /// nothing.
  Stream<RoutedSignal> channel(SignalChannel channel) =>
      _channels[channel]?.stream ?? const Stream.empty();

  /// The sender of every committed frame, on every channel, told before its
  /// channel reads it.
  Stream<SignalHeard> get heard => _heard.stream;

  /// Starts taking frames off the socket.
  void start() {
    if (_closed) {
      return;
    }
    _subscription ??= socket.inboundBlobs.listen(_enqueue);
  }

  /// Stops taking frames off the socket and forgets those still waiting. A
  /// later [start] reads again.
  Future<void> stop() async {
    _queue.clear();
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    _closed = true;
    await stop();
    for (final controller in _channels.values) {
      await controller.close();
    }
    await _heard.close();
  }

  /// Runs [action] when no open and no other seal is running, and holds them
  /// off until it ends.
  Future<T> exclusively<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
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
        final routed = await exclusively(() => _receive(blob));
        if (routed == null || _closed) {
          continue;
        }
        final (channel, signal) = routed;
        _heard.add(
          SignalHeard(
            userId: signal.senderUserId,
            deviceId: signal.senderDeviceId,
          ),
        );
        _channels[channel]?.add(signal);
      }
    } finally {
      _draining = false;
    }
  }

  Future<(SignalChannel, RoutedSignal)?> _receive(String blob) async {
    final frame = _decodeBlob(blob);
    if (frame == null) {
      return null;
    }
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final openedResult = await opener.open(frame);
      if (openedResult case FailureResult()) {
        return null;
      }
      final opening = (openedResult as Success<SignalOpening>).value;
      final channel = SignalChannel.of(opening.payload);
      if (channel == null || !_channels.containsKey(channel)) {
        // Not a channel's. Left unopened, so a durable envelope the relay
        // replayed as a signal still opens where it belongs.
        return null;
      }
      final committed = await opening.commit();
      if (committed case FailureResult(failure: final failure)) {
        if (_isConflict(failure)) {
          continue;
        }
        return null;
      }
      return (
        channel,
        RoutedSignal(
          senderUserId: opening.senderUserId,
          senderDeviceId: opening.senderDeviceId,
          payload: opening.payload,
        ),
      );
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

  static bool _isConflict(Failure failure) =>
      failure is ValidationFailure &&
      failure.kind == ValidationFailureKind.conflict;
}

final RegExp _standardBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
