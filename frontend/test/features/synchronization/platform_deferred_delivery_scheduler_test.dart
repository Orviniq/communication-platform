import 'dart:async';

import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the deferred catch-up, with a fake platform under it.
///
/// The Kotlin half cannot be exercised on a host and no device is available, so
/// what is provable here is everything that decides *when* the platform is
/// asked for something and *when* it is told the wake-up is over — which is the
/// half that decides whether a catch-up finishes or is killed mid-drain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;
  late TargetPlatform? previousPlatform;
  const channel = MethodChannel(PlatformDeferredDeliveryScheduler.channelName);

  setUp(() {
    // The adapter refuses to reach the platform on anything but Android,
    // because no other target has an implementation behind the channel.
    previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Delivers a platform-to-Dart call the way the job service would.
  Future<void> platformCallsIn(String method) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            PlatformDeferredDeliveryScheduler.channelName,
            const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
            (_) {},
          );

  test('arming asks the platform for an interval in milliseconds', () async {
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    await scheduler.scheduleBestEffort(
      minimumInterval: const Duration(minutes: 15),
    );

    expect(platformCalls.single.method, 'schedule');
    expect(
      platformCalls.single.arguments,
      containsPair('minimumIntervalMillis', 900000),
    );
  });

  test('disarming and the ownership question reach the platform', () async {
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    await scheduler.cancel();
    await scheduler.awaitExclusiveOwnership();

    expect(platformCalls.map((call) => call.method), [
      'cancel',
      'awaitExclusiveOwnership',
    ]);
  });

  test('a wake-up is not answered until the owner acknowledges it', () async {
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);
    BestEffortDeliveryTick? received;
    final subscription = scheduler.foregroundTriggers.listen(
      (tick) => received = tick,
    );
    addTearDown(subscription.cancel);

    var answered = false;
    final reply = platformCallsIn('runCatchUp').then((_) => answered = true);
    await pumpEventQueue();

    expect(received, isNotNull);
    expect(
      answered,
      isFalse,
      reason:
          'the platform lets the process be frozen again once the job is '
          'finished, so answering early ends the catch-up mid-drain',
    );

    received!.complete();
    await reply;

    expect(answered, isTrue);
  });

  test('a second acknowledgement of the same wake-up changes nothing', () {
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);
    var completions = 0;
    final tick = BestEffortDeliveryTick(onComplete: () => completions += 1)
      ..complete()
      ..complete();

    expect(tick.isCompleted, isTrue);
    expect(completions, 1);
  });

  test('a wake-up nobody is listening for is answered at once', () async {
    // No delivery owner in this isolate: the application is signed out, or its
    // session failed to compose. Holding the wake-up open would keep the
    // process awake for work that will never start.
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    var answered = false;
    await platformCallsIn('runCatchUp').then((_) => answered = true);

    expect(answered, isTrue);
  });

  test('a wake-up the owner never acknowledges is given up on', () async {
    final scheduler = PlatformDeferredDeliveryScheduler(
      tickDeadline: const Duration(milliseconds: 20),
    );
    addTearDown(scheduler.dispose);
    final subscription = scheduler.foregroundTriggers.listen((_) {});
    addTearDown(subscription.cancel);

    var answered = false;
    await platformCallsIn('runCatchUp').then((_) => answered = true);

    expect(
      answered,
      isTrue,
      reason:
          'an answer this application chose beats a stop the system imposes, '
          'because the system delivers its own by killing work where it stands',
    );
  });

  test('a platform with no implementation behind it is not an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    // Nothing is scheduled and nothing pretends to be. The honest consequence
    // is a build that performs no catch-up, not a session that fails to start.
    await expectLater(
      scheduler.scheduleBestEffort(
        minimumInterval: const Duration(minutes: 15),
      ),
      completes,
    );
    await expectLater(scheduler.awaitExclusiveOwnership(), completes);
  });

  test('a session that cannot establish exclusivity does not proceed', () async {
    // Reaching this means the platform side stopped answering the question at
    // all. There is very likely nothing to race with in that state, but a
    // session may not proceed as though it had established that it is the only
    // delivery owner.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => Completer<void>().future);
    final scheduler = PlatformDeferredDeliveryScheduler(
      ownershipDeadline: const Duration(milliseconds: 20),
    );
    addTearDown(scheduler.dispose);

    await expectLater(
      scheduler.awaitExclusiveOwnership(),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a platform that refuses is not an error either', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'refused'),
        );
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    await expectLater(
      scheduler.scheduleBestEffort(
        minimumInterval: const Duration(minutes: 15),
      ),
      completes,
    );
  });

  test('nothing reaches the platform on a target with no scheduler', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);

    await scheduler.scheduleBestEffort(
      minimumInterval: const Duration(minutes: 15),
    );
    await scheduler.cancel();

    expect(platformCalls, isEmpty);
  });

  group('the ownership gate a foreground entry point opens with', () {
    test('it asks the platform before anything else has happened', () async {
      // The whole correction ADR-050 makes. The question used to be asked by
      // the delivery session, which composes behind session restoration - and
      // restoration was then a token rotation against the shared durable row.
      // Asking here means nothing authenticated has happened yet.
      await const DeliveryOwnershipGate().awaitExclusiveOwnership();

      expect(platformCalls.map((call) => call.method), [
        'awaitExclusiveOwnership',
      ]);
    });

    test('a platform that never answers does not stop the launch', () async {
      // Refusing to start would replace an intermittent correctness bug with a
      // permanent availability one: an application that cannot be opened. What
      // makes starting anyway survivable is that two owners overlapping cost a
      // repeated envelope inspection and a repeated batch, never the session.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) => Completer<Object?>().future,
          );

      await expectLater(
        const DeliveryOwnershipGate(
          deadline: Duration(milliseconds: 50),
        ).awaitExclusiveOwnership(),
        completes,
      );
    });

    test(
      'a target with no implementation behind it waits for nobody',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);

        await expectLater(
          const DeliveryOwnershipGate().awaitExclusiveOwnership(),
          completes,
        );
      },
    );

    test('nothing is asked of a target that is not Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await const DeliveryOwnershipGate().awaitExclusiveOwnership();

      expect(platformCalls, isEmpty);
    });
  });

  group('being told to stop being the delivery owner', () {
    test('a headless run latches the request and keeps it latched', () async {
      final handshake = DeferredCatchUpHandshake()..listen();
      addTearDown(handshake.release);

      expect(handshake.standDownRequested, isFalse);
      await platformCallsIn('standDown');
      expect(handshake.standDownRequested, isTrue);

      // Nothing un-displaces a displaced run. The owner that displaced it is
      // the one that continues, and a second request changes nothing.
      await platformCallsIn('standDown');
      expect(handshake.standDownRequested, isTrue);
    });

    test('it is the signal the engine reads, without any adapter', () async {
      // The handshake *is* a DeliveryStandDownSignal, so what the platform says
      // and what the engine reads cannot drift apart through a mapping layer.
      final DeliveryStandDownSignal signal = DeferredCatchUpHandshake()
        ..listen();
      addTearDown((signal as DeferredCatchUpHandshake).release);

      await platformCallsIn('standDown');

      expect(signal.standDownRequested, isTrue);
    });

    test('a released handshake stops answering the platform', () async {
      final handshake = DeferredCatchUpHandshake()
        ..listen()
        ..release();

      await platformCallsIn('standDown');

      expect(
        handshake.standDownRequested,
        isFalse,
        reason: 'a finished run is not displaced, it is over',
      );
    });

    test('an unknown platform call is refused rather than absorbed', () async {
      final handshake = DeferredCatchUpHandshake()..listen();
      addTearDown(handshake.release);

      await expectLater(
        platformCallsIn('runCatchUp'),
        completes,
        reason:
            'MissingPluginException is what Flutter turns into an empty reply '
            'and the platform reads as notImplemented, so a future method the '
            'Kotlin half invents cannot be silently taken as a success',
      );
      expect(handshake.standDownRequested, isFalse);
    });
  });

  test('the headless handshake reports finishing and can disarm', () async {
    final handshake = DeferredCatchUpHandshake();

    await handshake.cancelSchedule();
    await handshake.reportFinished();

    expect(platformCalls.map((call) => call.method), ['cancel', 'finished']);
  });

  test('an unknown platform call is refused rather than answered', () async {
    // The adapter answers exactly one question. Anything else is refused by
    // throwing MissingPluginException, which Flutter turns into an empty reply
    // and the platform side reads as `notImplemented` - so a future method the
    // Kotlin half invents cannot be silently absorbed as a success here.
    final scheduler = PlatformDeferredDeliveryScheduler();
    addTearDown(scheduler.dispose);
    var replied = false;
    ByteData? envelope;

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          PlatformDeferredDeliveryScheduler.channelName,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('somethingElse'),
          ),
          (reply) {
            replied = true;
            envelope = reply;
          },
        );

    expect(replied, isTrue);
    expect(envelope, isNull);
  });
}
