import 'dart:io';

import 'package:communication_platform/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of ADR-049 that only exist in the Android artifact.
///
/// None of this can be exercised by a host test and no device is available, so
/// what is asserted is what the source may and may not contain. These are the
/// properties that would be silently wrong on a device rather than loudly wrong
/// in a test run: what the artifact asks the platform for, what it declares to
/// it, what the second entry point can reach, and what it may never quietly
/// stop inheriting.
void main() {
  const kotlinRoot =
      'android/app/src/main/kotlin/com/example/communication_platform';
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  final delivery = File('$kotlinRoot/BackgroundDelivery.kt').readAsStringSync();

  group('what the artifact declares to the platform', () {
    test('the catch-up service is a plain job service, bound and unexported', () {
      // ADR-049's floor is defined by needing nothing from the user, and this
      // is what keeps it that way. A second service now exists - ADR-051's
      // opt-in sustained-delivery service - and the assertion that was
      // "there is one service" is narrowed rather than deleted: *this* service
      // is still a plain one, and it is still the only thing the job scheduler
      // can start.
      expect(manifest, contains('android:name=".DeferredDeliveryJobService"'));
      expect(
        manifest,
        contains('android:permission="android.permission.BIND_JOB_SERVICE"'),
        reason:
            'without it the system ignores the service, and with it nothing '
            'but the job scheduler can start it',
      );
      final declaration = manifest.substring(
        manifest.indexOf('<service\n            android:name=".Deferred'),
        manifest.indexOf('<!-- Sustained delivery (ADR-051)'),
      );
      expect(declaration, contains('android:exported="false"'));
      expect(
        declaration,
        isNot(contains('foregroundServiceType')),
        reason: 'the mandatory floor never runs in the foreground',
      );
      expect(
        '<service'.allMatches(manifest),
        hasLength(2),
        reason: 'the catch-up job service and the opt-in sustained service',
      );
    });

    test('everything runs in one process, which is what makes one owner', () {
      // The whole single-owner argument is that a job runs in this
      // application's own process and a Flutter process has one Dart VM. A
      // second process would put a second Dart VM beside it and the in-process
      // arbitration would arbitrate nothing.
      expect(manifest, isNot(contains('android:process')));
    });

    test('the floor still needs nothing granted, configured or changed', () {
      // The list this test used to make of the manifest is now made of the
      // floor's own source, because ADR-051 added permissions the manifest
      // legitimately carries for a capability that is off until somebody turns
      // it on. What must stay true is narrower and more precise: the *floor*
      // asks for none of it, uses none of it, and would work on a device where
      // every one of them was refused.
      expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
      for (final forbidden in const [
        'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        'isIgnoringBatteryOptimizations',
        'startForeground',
        'FOREGROUND_SERVICE',
        'AlarmManager',
        'RECEIVE_SMS',
        'WAKE_LOCK',
      ]) {
        expect(
          delivery,
          isNot(contains(forbidden)),
          reason:
              'the mandatory floor must work with nothing granted, configured '
              'or changed by the user',
        );
      }
      // And these may never appear anywhere at all: an exact alarm is a
      // revocable permission that cancels every future alarm when withdrawn,
      // and an SMS receiver hands a carrier a log of who is messaged and when.
      for (final forbidden in const [
        'SCHEDULE_EXACT_ALARM',
        'USE_EXACT_ALARM',
        'RECEIVE_SMS',
      ]) {
        expect(manifest, isNot(contains(forbidden)));
      }
    });
  });

  group('what the artifact asks the platform for', () {
    test('a periodic job at the platform floor, with a network constraint', () {
      expect(delivery, contains('setPeriodic('));
      expect(
        delivery,
        contains('JobInfo.getMinPeriodMillis()'),
        reason:
            'the floor is read from the platform rather than repeated as a '
            'number that could drift away from it',
      );
      expect(delivery, contains('JobInfo.NETWORK_TYPE_ANY'));
      expect(
        delivery,
        contains('setPersisted(true)'),
        reason: 'a restart must not silently end background delivery',
      );
    });

    test('it never buys timeliness with something else', () {
      for (final forbidden in const [
        'AlarmManager',
        'setExactAndAllowWhileIdle',
        'setAndAllowWhileIdle',
        'startForeground',
        'ServiceInfo.FOREGROUND_SERVICE_TYPE',
        'isIgnoringBatteryOptimizations',
        'FirebaseMessaging',
      ]) {
        expect(delivery, isNot(contains(forbidden)));
      }
    });

    test('it wakes to drain its own mailbox, never to probe a public host', () {
      // ADR-013: no foreign runtime call of any kind, and never a connectivity
      // probe against something outside the provisioned deployment.
      for (final forbidden in const ['http://', 'https://', 'InetAddress']) {
        expect(delivery, isNot(contains(forbidden)));
      }
    });

    test('nothing about the run is logged', () {
      expect(delivery, isNot(contains('Log.')));
      expect(delivery, isNot(contains('println')));
    });

    test('no dependency was added to reach the platform', () {
      // `JobScheduler` is in the framework at minSdk 24. `androidx.work` would
      // add its own database, its own service and its own boot receiver to the
      // merged manifest of a security-reviewed artifact, to schedule one job.
      final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
      final gradle = File(
        'android/app/build.gradle.kts',
      ).readAsStringSync().toLowerCase();
      for (final package in const ['workmanager', 'firebase', 'unifiedpush']) {
        expect(pubspec, isNot(contains(package)));
      }
      expect(gradle, isNot(contains('androidx.work')));
    });
  });

  group('what the second entry point can reach', () {
    final headless = File(
      'lib/app/dependencies/deferred_delivery_catch_up.dart',
    ).readAsStringSync();

    test('it inherits the composition root rather than rebuilding one', () {
      // The dangerous failure is not a crash, it is a quieter posture: the
      // public root store instead of the provisioned authority, a second token
      // coordinator, a crypto core built without the compiled environment's
      // permit. One constructor removes the possibility.
      expect(headless, contains('ApplicationRuntime.create('));
      for (final forbidden in const [
        'TransportSecurity.platformDefault',
        'NetworkingFoundation.create',
        'TokenCoordinator(',
        'DioRestClient(',
      ]) {
        expect(
          headless,
          isNot(contains(forbidden)),
          reason: 'a background entry point composes no transport of its own',
        );
      }
    });

    test('it holds nothing: one drain, no socket, no supervisor', () {
      for (final forbidden in const [
        'SyncLifecycleSupervisor',
        'WebSocketGateway',
        'GatewayRealtimeSyncAdapter',
        'realtimeGateway',
      ]) {
        expect(
          headless,
          isNot(contains(forbidden)),
          reason:
              'a bounded wake-up cannot hold a connection: a cached process is '
              'frozen and the system terminates its TCP sockets',
        );
      }
    });

    test('the headless engine is given the channels it cannot do without', () {
      // A headless engine reaches only the plugins Flutter registers
      // automatically. Without these two attached to it, the run could not
      // unwrap the database key at all, and could not say anything to the user
      // about what it drained.
      expect(delivery, contains('ProtectedStorageChannel(applicationContext)'));
      expect(delivery, contains('MessageAlertChannel(applicationContext)'));
      expect(delivery, contains(PlatformDeferredDeliveryScheduler.channelName));
    });
  });

  group('what makes exactly one part of this drive delivery (ADR-050)', () {
    final bootstrap = File('lib/app/bootstrap.dart').readAsStringSync();
    final headless = File(
      'lib/app/dependencies/deferred_delivery_catch_up.dart',
    ).readAsStringSync();

    test('the foreground asks before it builds anything', () {
      // The correction ADR-050 makes to ADR-049. The ownership question used to
      // be asked by `MessageDeliverySession.compose`, which is reached only
      // after session restoration - and restoration *is* a rotation of the
      // shared refresh token. Asked there, the gate was downstream of the
      // damage it existed to prevent. Source order is what pins it, because no
      // host test can compose `bootstrap`.
      final asked = bootstrap.indexOf(
        'DeliveryOwnershipGate().awaitExclusiveOwnership()',
      );
      final built = bootstrap.indexOf('ApplicationRuntime.create(');
      expect(asked, greaterThan(-1), reason: 'the gate is opened at all');
      expect(
        asked,
        lessThan(built),
        reason:
            'nothing that touches protected storage or a token may precede it',
      );
    });

    test('the two owners are not symmetric: the catch-up gives way', () {
      // A foreground engine attaching is the earliest this process can know a
      // user is present, and it is where the run in flight is asked to stop.
      expect(delivery, contains('fun requestStandDown()'));
      expect(
        delivery,
        contains('headless?.requestStandDown()'),
        reason: 'attaching a foreground engine is what displaces a catch-up',
      );
      expect(
        delivery,
        contains('standDownImmediately = foreground != null'),
        reason:
            'a run started while an activity is already attaching is displaced '
            'before it has done anything',
      );
    });

    test('it is asked to stop, never killed for convenience', () {
      // Abandoning a run mid-flight is what `onStopJob` and the four-minute
      // deadline do, because the platform has already taken the decision. It is
      // not what an ordinary displacement does: a call into the shared native
      // cryptographic core, or a transaction, must be allowed to finish.
      final attach = delivery.indexOf('fun attachForeground(');
      final detach = delivery.indexOf('fun detachForeground(');
      final body = delivery.substring(attach, detach);
      expect(body, isNot(contains('abandon')));
      expect(body, isNot(contains('destroy')));
    });

    test('the headless run listens for it, and stops listening when over', () {
      expect(headless, contains('channel.listen()'));
      expect(headless, contains('channel.release()'));
      expect(
        headless,
        contains('DeferredCatchUpOutcome.displaced'),
        reason: 'giving way is an outcome of its own, not a failure',
      );
      expect(
        headless,
        contains('standDown: handshake'),
        reason: 'the engine reads the same signal the platform speaks to',
      );
    });

    test('nothing about the arbitration is durable', () {
      // The whole argument for arbitrating in the process is that every owner
      // dies with it, so there is no stale holder to expire and nothing that
      // can outlive a crash and block delivery. A file, a preference or a
      // database row here would reintroduce exactly that.
      for (final forbidden in const [
        'SharedPreferences',
        'getSharedPreferences',
        'FileOutputStream',
        'openFileOutput',
        'ContentProvider',
      ]) {
        expect(delivery, isNot(contains(forbidden)));
      }
    });
  });

  group('which build a background run believes it is', () {
    test('the compiled entry point fixes the environment, not the platform', () {
      // ADR-044 holds that the environment decides both the provisioned server
      // and the trust anchor, and that it must be fixed by the entry point
      // rather than selectable at runtime. The platform picks a name; which
      // `AppEnvironment` that name resolves to is decided by which file was
      // compiled.
      const flavors = {
        'lib/main.dart': 'AppEnvironment.development',
        'lib/main_development.dart': 'AppEnvironment.development',
        'lib/main_production.dart': 'AppEnvironment.production',
      };
      flavors.forEach((path, environment) {
        final source = File(path).readAsStringSync();
        expect(source, contains("@pragma('vm:entry-point')"), reason: path);
        expect(
          source,
          contains('runDeferredDeliveryEntryPoint($environment)'),
          reason: path,
        );
      });
      expect(delivery, contains('ENTRYPOINT = "backgroundDelivery"'));
      expect(
        delivery,
        isNot(contains('dartEntrypointArgs')),
        reason:
            'nothing about which build this is may cross the boundary at '
            'runtime',
      );
    });
  });
}
