import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The re-viewable half of the ADR-045 disclosure model.
///
/// The notice is acknowledged once, during enrollment, and is deliberately
/// never repeated on a timer. That only works if it stays readable on demand,
/// so these tests hold the entry points open.
void main() {
  testWidgets('the notice is reachable without authentication wiring', (
    tester,
  ) async {
    await _pump(tester, AppEnvironment.production);

    expect(
      find.byKey(const ValueKey('preauth-security-notice')),
      findsOneWidget,
    );
    expect(
      find.text("What this app protects — and what it doesn't"),
      findsOneWidget,
    );
    expect(find.text('What it DOES protect'), findsOneWidget);
    expect(find.text('What it does NOT protect'), findsOneWidget);
  });

  testWidgets('re-reading the notice offers nothing to acknowledge', (
    tester,
  ) async {
    await _pump(tester, AppEnvironment.beta);

    // Acknowledgement belongs to the enrollment gate alone. A second "I
    // understand" here would be a consent the app does not record and does not
    // act on.
    expect(find.text('I understand'), findsNothing);
    expect(find.text('Back'), findsWidgets);
  });

  testWidgets('the re-viewable notice carries the same build disclosure', (
    tester,
  ) async {
    await _pump(tester, AppEnvironment.beta);

    expect(find.byKey(const ValueKey('deployment-disclosure')), findsOneWidget);
    expect(find.text('What this build is'), findsOneWidget);
    expect(
      find.textContaining('Nobody outside the project has reviewed'),
      findsOneWidget,
    );
  });

  testWidgets('the retention window is stated only when it is known', (
    tester,
  ) async {
    // `ENVELOPE_TTL_DAYS` has no other observable: nothing refuses, so no
    // error teaches it. Until the route has answered, this build's default is
    // a guess, and a guess in a mandatory statement is exactly the claim this
    // disclosure exists to avoid.
    await _pump(tester, AppEnvironment.beta);

    expect(
      find.textContaining('a time set by whoever runs the server'),
      findsOneWidget,
    );
    expect(find.textContaining('days is deleted'), findsNothing);
  });

  testWidgets('the deployment window replaces the wording that lacks it', (
    tester,
  ) async {
    await _pump(tester, AppEnvironment.beta, limits: _publishedThreeDays);

    expect(
      find.textContaining('still waiting after 3 days is deleted'),
      findsOneWidget,
    );
    expect(
      find.textContaining('a time set by whoever runs the server'),
      findsNothing,
    );
  });

  testWidgets('production re-reads the permanent boundary and nothing else', (
    tester,
  ) async {
    await _pump(tester, AppEnvironment.production);

    expect(find.byKey(const ValueKey('deployment-disclosure')), findsNothing);
    expect(find.textContaining('What this build is'), findsNothing);
  });

  testWidgets('Settings re-opens the notice', (tester) async {
    await _pump(tester, AppEnvironment.beta, initialLocation: '/settings');

    final entry = find.byKey(const ValueKey('settings-security-notice'));
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('preauth-security-notice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('deployment-disclosure')), findsOneWidget);
  });

  testWidgets('the notice is translated, not left in English', (tester) async {
    await _pump(tester, AppEnvironment.beta, locale: const Locale('fa'));

    expect(find.byKey(const ValueKey('deployment-disclosure')), findsOneWidget);
    expect(find.text('این نسخه چیست'), findsOneWidget);
    expect(find.textContaining('What this build is'), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester,
  AppEnvironment environment, {
  String initialLocation = '/security-notice',
  Locale locale = const Locale('en'),
  ServerConfig limits = ServerConfig.fallback,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      // `bootstrap()` sets both of these from one argument, and
      // `app_bootstrap_test.dart` holds them together.
      overrides: [
        appEnvironmentProvider.overrideWithValue(environment),
        publishedLimitsProvider.overrideWithValue(limits),
      ],
      child: CommunicationPlatformApp(
        environment: environment,
        locale: locale,
        initialLocation: initialLocation,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A deployment that prunes in three days, and says so.
const _publishedThreeDays = ServerConfig(
  envelopeTtlDays: 3,
  attachmentTtlDays: 10,
  attachmentDailyBytes: 1048576,
  mailboxMaxBytes: 2097152,
  maxDevicesPerUser: 2,
  maxDeviceLogRecords: 100,
  sessionTokenDays: 7,
  sendBatchMax: 16,
  ackMax: 8,
  drainPageMax: 4,
  claimMax: 2,
  envelopeBuckets: {1024},
  attachmentBuckets: {65536},
  signalBuckets: {1024},
  voiceConfigured: false,
  fromDeployment: true,
);
