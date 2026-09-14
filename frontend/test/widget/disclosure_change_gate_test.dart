import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/devices/presentation/disclosure_change_gate.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The half of ADR-045 that ADR-052 found missing: what reaches somebody who
/// already accepted a statement that has since been corrected.
void main() {
  testWidgets('it re-presents the statement and marks what moved', (
    tester,
  ) async {
    await _pump(tester, acknowledged: 8);

    expect(find.byKey(const ValueKey('disclosure-change-screen')), findsOne);
    expect(find.text('What this app tells you has changed'), findsOne);
    // One copy of the content, the same one enrollment and Settings render.
    expect(find.byKey(const ValueKey('deployment-disclosure')), findsOne);
    expect(find.text('What this build is'), findsOne);

    // Two points have moved since revision 8 - the delivery and group points
    // revision 9 rewrote (ADR-076) - and two badges say so. The mark is a
    // labelled badge rather than a colour, so a screen reader reaches it too.
    expect(find.text('New or changed'), findsNWidgets(2));
    expect(
      find.textContaining('the same encryption as direct messages'),
      findsOne,
    );
    // And the six that did not move carry no badge, which is what makes the
    // badge mean anything.
    expect(
      find.textContaining('A message waits on the server only until'),
      findsOne,
    );
    expect(
      find.textContaining('Nobody outside the project has reviewed'),
      findsOne,
    );
  });

  testWidgets('a reader with no record is shown everything, marked nothing', (
    tester,
  ) async {
    // Everybody who enrolled before this mechanism existed. Marking every line
    // marks none of them, and 0 means the app does not know what they saw.
    await _pump(tester, acknowledged: 0);

    expect(find.byKey(const ValueKey('disclosure-change-screen')), findsOne);
    expect(find.text('New or changed'), findsNothing);
    expect(find.byKey(const ValueKey('deployment-disclosure')), findsOne);
  });

  testWidgets('answering it hands the application back', (tester) async {
    var accepted = 0;
    await _pump(tester, acknowledged: 4, onAcknowledged: () => accepted += 1);

    final accept = find.byKey(const ValueKey('accept-changed-disclosure'));
    await tester.scrollUntilVisible(accept, 200);
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(accepted, 1);
  });

  testWidgets('it is translated, not left in English', (tester) async {
    await _pump(tester, acknowledged: 8, locale: const Locale('fa'));

    expect(
      find.text('آنچه این برنامه دربارهٔ خودش می‌گوید تغییر کرده است'),
      findsOne,
    );
    expect(find.text('تازه یا تغییرکرده'), findsNWidgets(2));
    expect(find.textContaining('What this app tells you'), findsNothing);
  });

  testWidgets('it lays out right-to-left in Persian', (tester) async {
    await _pump(tester, acknowledged: 4, locale: const Locale('fa'));

    final direction = Directionality.of(
      tester.element(find.byKey(const ValueKey('disclosure-change-screen'))),
    );
    expect(direction, TextDirection.rtl);
  });

  testWidgets('neither language overflows at a large text scale', (
    tester,
  ) async {
    // The audience reads this on a phone, and some of them read it enlarged.
    // A statement that clips at 160% is a statement that was not disclosed.
    for (final locale in const [Locale('en'), Locale('fa')]) {
      await _pump(
        tester,
        acknowledged: 4,
        locale: locale,
        textScale: 1.6,
        size: const Size(360, 800),
      );
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });

  testWidgets('only a build that carries the disclosure has a gate', (
    tester,
  ) async {
    // Development is never handed to anyone, so it has nothing to re-present.
    // Production is handed to named people (ADR-076), so it carries the one
    // statement this gate re-presents.
    expect(
      AppEnvironment.development.deploymentDisclosure,
      isNull,
      reason: 'development must have nothing to re-present',
    );
    expect(
      AppEnvironment.production.deploymentDisclosure,
      same(DeploymentDisclosure.distributed),
    );
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required int acknowledged,
  Locale locale = const Locale('en'),
  VoidCallback? onAcknowledged,
  double textScale = 1,
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: DisclosureChangePage(
            disclosure: DeploymentDisclosure.distributed,
            acknowledgedRevision: acknowledged,
            onAcknowledged: () => onAcknowledged?.call(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
