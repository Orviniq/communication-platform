// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/infrastructure/sync_platform_adapters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android side of deferred delivery, behind one method channel.
///
/// Nothing about a message crosses it. Dart asks the platform to arm or disarm
/// a periodic job and to say whether a headless catch-up currently owns
/// delivery; the platform asks Dart to run one catch-up now and waits for the
/// answer. There is no payload in either direction beyond an interval in
/// milliseconds, so an entry point reached this way carries nothing a hostile
/// caller could shape.
///
/// The reply to `runCatchUp` is the load-bearing part. The platform holds a
/// wake lock for the duration of the job and lets the process be frozen again
/// once the job is finished, so a reply sent before the drain has finished ends
/// the catch-up mid-flight. This adapter therefore does not answer until the
/// delivery owner acknowledges the tick — or until [tickDeadline] passes, which
/// keeps a stalled owner from holding the wake-up open until the platform's own
/// deadline kills the process.
final class PlatformDeferredDeliveryScheduler
    implements AndroidPollingScheduler {
  PlatformDeferredDeliveryScheduler({
    MethodChannel channel = const MethodChannel(channelName),
    this.tickDeadline = const Duration(minutes: 2),
    this.ownershipDeadline = const Duration(minutes: 5),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static const channelName = 'communication_platform/background_delivery';

  /// How long one deferred wake-up may take before this adapter stops waiting
  /// for the delivery owner and tells the platform the moment is over.
  ///
  /// Shorter than the platform's own job timeout on purpose: an answer this
  /// application chose is better than a stop the system imposes, because the
  /// system's is delivered by killing work wherever it stands.
  final Duration tickDeadline;

  /// How long a session may wait for exclusive ownership before it gives up and
  /// composes nothing.
  ///
  /// Longer than the deadline the platform applies to a headless run, so the
  /// ordinary end of a wait is that run finishing. Reaching this means the
  /// platform side stopped answering at all — in which case there is nothing
  /// running to race with either, but a session that cannot establish it is
  /// exclusive does not proceed as though it had.
  final Duration ownershipDeadline;

  final MethodChannel _channel;
  final StreamController<BestEffortDeliveryTick> _triggers =
      StreamController<BestEffortDeliveryTick>.broadcast();
  bool _disposed = false;

  @override
  Stream<BestEffortDeliveryTick> get foregroundTriggers => _triggers.stream;

  @override
  Future<void> scheduleBestEffort({required Duration minimumInterval}) =>
      _invoke('schedule', <String, Object?>{
        'minimumIntervalMillis': minimumInterval.inMilliseconds,
      });

  @override
  Future<void> cancel() => _invoke('cancel', const <String, Object?>{});

  @override
  Future<void> awaitExclusiveOwnership() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel
          .invokeMethod<void>(
            'awaitExclusiveOwnership',
            const <String, Object?>{},
          )
          .timeout(ownershipDeadline);
    } on MissingPluginException {
      // No implementation behind the channel, so nothing schedules anything and
      // there is no second owner this could be waiting for.
    } on PlatformException {
      // Same conclusion: the platform could not answer the question, and it is
      // also the thing that would have started the other owner.
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _triggers.close();
  }

  Future<Object?> _onPlatformCall(MethodCall call) async {
    if (call.method != 'runCatchUp') {
      throw MissingPluginException('Unknown method ${call.method}.');
    }
    if (_disposed || !_triggers.hasListener) {
      // No delivery owner is listening in this isolate, so there is nothing to
      // wait for. Answering at once lets the platform release the process
      // instead of holding a wake-up open for work that will never start.
      return null;
    }
    final acknowledged = Completer<void>();
    _triggers.add(
      BestEffortDeliveryTick(
        onComplete: () {
          if (!acknowledged.isCompleted) {
            acknowledged.complete();
          }
        },
      ),
    );
    await acknowledged.future.timeout(tickDeadline, onTimeout: () {});
    return null;
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    // The check is on the target platform rather than on `dart:io`, because
    // this file must stay importable by a future Web build and because a test
    // has to be able to drive the Android path without an Android device.
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No implementation behind the channel. Nothing is scheduled and nothing
      // pretends to be: the honest consequence is that a backgrounded build
      // performs no catch-up, which is what the caller's own state reports.
    } on PlatformException {
      // The platform refused. Same consequence, and the durable queue is
      // untouched either way.
    }
  }
}

/// Asks the platform whether anything else in this process owns delivery, and
/// waits until nothing does.
///
/// This is the *first* thing a foreground entry point does, before it builds a
/// runtime, opens protected storage or reads a token — because those are the
/// operations a second owner makes unsafe, not the delivery session that comes
/// long afterwards. Arriving here is also what tells the platform a foreground
/// engine now exists, which is what makes an in-flight catch-up stand down
/// instead of running to completion.
///
/// It is deliberately not a [MethodChannel] handler: the foreground engine's
/// handler for this channel belongs to [PlatformDeferredDeliveryScheduler],
/// which is composed later and for a different purpose.
final class DeliveryOwnershipGate {
  const DeliveryOwnershipGate({
    MethodChannel channel = const MethodChannel(
      PlatformDeferredDeliveryScheduler.channelName,
    ),
    this.deadline = const Duration(seconds: 20),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// How long an entry point waits before it gives up and starts anyway.
  ///
  /// Giving up is not fail-open by accident. Refusing to start would turn a
  /// platform that stopped answering into an application that cannot be opened,
  /// which is a permanent availability failure in place of an intermittent
  /// correctness one. What makes starting anyway survivable is what two owners
  /// can do to each other: hand one envelope to the ratchet twice, which fails
  /// and is retried, and send one outbox batch twice, which recipients
  /// deduplicate (ADR-050). The session is no part of it, because nothing
  /// retires a token (ADR-083).
  final Duration deadline;

  Future<void> awaitExclusiveOwnership() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel
          .invokeMethod<void>(
            'awaitExclusiveOwnership',
            const <String, Object?>{},
          )
          .timeout(deadline);
    } on TimeoutException {
      // The platform did not answer in time. Reported by no one: there is
      // nothing the user could do about it and nothing that would be true
      // about the next launch.
    } on MissingPluginException {
      // No implementation behind the channel, so nothing schedules a catch-up
      // and there is no second owner to wait for.
    } on PlatformException {
      // Same conclusion: the thing that could not answer is also the thing that
      // would have started the other owner.
    }
  }
}

/// What a headless catch-up tells the platform when it is done, and how the
/// platform tells it that it is no longer the delivery owner.
///
/// A deferred wake-up is a bounded moment the operating system granted, and the
/// process is frozen again once it is released. The Dart half of a headless run
/// is therefore responsible for saying that it has finished: the platform side
/// keeps the engine alive until then, and enforces its own deadline so a run
/// that never reports cannot hold the wake-up open indefinitely.
///
/// The other direction is [standDown]. A catch-up runs because nobody was
/// looking; when somebody starts looking, the foreground will drain the same
/// mailbox within seconds and this run has no reason left to exist. It is asked
/// to stop rather than killed, so that it gives way between units of work
/// instead of part-way through a transaction or a call into the native
/// cryptographic core.
final class DeferredCatchUpHandshake implements DeliveryStandDownSignal {
  DeferredCatchUpHandshake({
    MethodChannel channel = const MethodChannel(
      PlatformDeferredDeliveryScheduler.channelName,
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  bool _standDown = false;

  /// Once true, always true. A run that has been displaced is not un-displaced
  /// by anything the platform could say next; the owner that displaced it is
  /// the one that continues.
  @override
  bool get standDownRequested => _standDown;

  /// Starts listening for the platform's stand-down request.
  ///
  /// Called by the headless entry point before it does anything else, and
  /// released in the same `finally` that reports the run finished.
  void listen() => _channel.setMethodCallHandler(_onPlatformCall);

  void release() => _channel.setMethodCallHandler(null);

  /// Stops the periodic wake-up. Called by a headless run that found nothing to
  /// deliver to, so an application nobody is signed into stops being woken.
  Future<void> cancelSchedule() => _report('cancel');

  /// Reports that this headless run is over and its engine may be torn down.
  Future<void> reportFinished() => _report('finished');

  Future<Object?> _onPlatformCall(MethodCall call) async {
    if (call.method != 'standDown') {
      throw MissingPluginException('Unknown method ${call.method}.');
    }
    _standDown = true;
    return null;
  }

  Future<void> _report(String method) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, const <String, Object?>{});
    } on MissingPluginException {
      // Nothing is hosting this run, so there is nothing to tear down.
    } on PlatformException {
      // The platform's own deadline is what ends the run instead.
    }
  }
}
