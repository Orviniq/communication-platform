import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/features/bootstrap/application/bootstrap_flow.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/bootstrap/support/fake_bootstrap_ports.dart';

void main() {
  testWidgets('connection state has accessible Retry and no fake progress', (
    tester,
  ) async {
    final health = FakeHealthReachabilityPort.queued([
      const HealthUnreachable(),
      const HealthReachable(),
    ]);
    await _pumpBootstrap(
      tester,
      health: health,
      platform: BootstrapPlatform.web,
      configuration: testWebConfiguration,
    );

    expect(find.text("Can't reach the server"), findsOneWidget);
    expect(find.byKey(const ValueKey('bootstrap-retry')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.focusManager.primaryFocus, isNotNull);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login-route-boundary')), findsOneWidget);
    expect(health.calls, 2);
  });

  testWidgets('Web private-CA trust failure is blocking with no bypass', (
    tester,
  ) async {
    await _pumpBootstrap(
      tester,
      platform: BootstrapPlatform.web,
      configuration: testWebConfiguration,
      trust: FakePlatformTrustPort(
        const TrustValidationFailed(
          TrustFailureKind.browserPrivateCaNotTrusted,
        ),
      ),
    );

    expect(find.text('Server trust could not be verified'), findsOneWidget);
    expect(find.textContaining('operating system or browser'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Continue'), findsNothing);
    expect(find.byKey(const ValueKey('app-shell-golden')), findsNothing);
  });

  testWidgets('not-provisioned production state has no retry or bypass', (
    tester,
  ) async {
    final flow = BootstrapFlow(
      configuration: FakeBootstrapConfigurationPort(
        const ConfigurationNotProvisioned(
          ConfigurationFailureKind.missingProvisioning,
        ),
      ),
      storage: FakeProtectedStoragePort(),
      trust: FakePlatformTrustPort(),
      health: FakeHealthReachabilityPort(const HealthReachable()),
      platform: BootstrapPlatform.android,
    );

    await tester.pumpWidget(
      CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: const Locale('en'),
        bootstrapFlow: flow,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('App not provisioned'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('bypass'), findsOneWidget);
  });

  testWidgets('Android offline route opens shell with connection strip', (
    tester,
  ) async {
    await _pumpBootstrap(
      tester,
      platform: BootstrapPlatform.android,
      configuration: testAndroidConfiguration,
      health: FakeHealthReachabilityPort(const HealthUnreachable()),
      localState: const LocalBootstrapState(
        identity: LocalIdentityState.usable,
        session: LocalSessionState.expired,
      ),
    );

    expect(find.byKey(const ValueKey('app-shell-golden')), findsOneWidget);
    expect(find.text('No connection to server'), findsWidgets);
  });

  testWidgets('production connection gate shows no configuration banner', (
    tester,
  ) async {
    await _pumpBootstrap(
      tester,
      platform: BootstrapPlatform.android,
      configuration: testAndroidConfiguration,
      health: FakeHealthReachabilityPort(const HealthUnreachable()),
    );

    expect(find.text("Can't reach the server"), findsOneWidget);
    expect(find.text('Development configuration'), findsNothing);
    // And no Experimental designation either (ADR-076 D8).
    expect(find.textContaining('Experimental'), findsNothing);
  });
}

Future<void> _pumpBootstrap(
  WidgetTester tester, {
  required BootstrapPlatform platform,
  required ProvisionedBootstrapConfiguration configuration,
  FakePlatformTrustPort? trust,
  FakeHealthReachabilityPort? health,
  LocalBootstrapState localState = const LocalBootstrapState.fresh(),
  AppEnvironment environment = AppEnvironment.production,
}) async {
  final flow = BootstrapFlow(
    configuration: FakeBootstrapConfigurationPort(
      ConfigurationLoaded(configuration),
    ),
    storage: FakeProtectedStoragePort(
      discovery: LocalStateDiscovered(localState),
    ),
    trust: trust ?? FakePlatformTrustPort(),
    health: health ?? FakeHealthReachabilityPort(const HealthReachable()),
    platform: platform,
  );
  await tester.pumpWidget(
    CommunicationPlatformApp(
      environment: environment,
      locale: const Locale('en'),
      bootstrapFlow: flow,
      bootstrapPlatform: platform,
    ),
  );
  await tester.pumpAndSettle();
}
