import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/diagnostics.dart';
import 'package:communication_platform/app/dependencies/recovery_providers.dart';
import 'package:communication_platform/app/dependencies/settings.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/devices/application/rotate_recovery_secret.dart';
import 'package:communication_platform/features/devices/presentation/sensitive_screen_control.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/features/diagnostics/presentation/diagnostics_page.dart';
import 'package:communication_platform/features/settings/domain/appearance_model.dart';
import 'package:communication_platform/features/settings/presentation/about_page.dart';
import 'package:communication_platform/features/settings/presentation/appearance_page.dart';
import 'package:communication_platform/features/settings/presentation/recovery_rotation_page.dart';
import 'package:communication_platform/features/settings/presentation/security_settings_page.dart';
import 'package:communication_platform/features/settings/presentation/settings_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/authentication_harness.dart';
import '../support/recovery_rotation_fakes.dart';

/// The settings surface set, in both supported languages, at both text scales,
/// and in the states that make each screen honest.
void main() {
  group('Settings home', () {
    testWidgets('offers every documented destination, the two destructive '
        'rows last', (tester) async {
      await _pump(tester, const SettingsPage());

      for (final key in const [
        'settings-profile',
        'settings-saved-messages',
        'settings-linked-devices',
        'settings-security',
        'settings-notifications',
        'settings-appearance',
        'settings-security-notice',
        'settings-about',
        'settings-log-out',
        'settings-erase-account',
      ]) {
        // Scrolled into view one at a time: the list is longer than a phone
        // screen, and a row that only exists off-screen is still a row.
        await _reveal(tester, key);
        expect(
          find.byKey(ValueKey(key)),
          findsOneWidget,
          reason: '$key is missing from the settings list',
        );
      }
    });

    testWidgets('log out states what it erases before it happens', (
      tester,
    ) async {
      await _pump(tester, const SettingsPage(), signedIn: true);

      await _reveal(tester, 'settings-log-out');
      await tester.tap(find.byKey(const ValueKey('settings-log-out')));
      await tester.pumpAndSettle();

      expect(find.text('Log out of this device?'), findsOneWidget);
      expect(find.textContaining('is erased'), findsOneWidget);
      expect(
        find.textContaining('recovery secret restores your identity'),
        findsOneWidget,
        reason: 'the two secrets are never conflated in a confirmation',
      );
      // Cancelling is a complete outcome: nothing happens.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Log out of this device?'), findsNothing);
    });

    testWidgets('renders in Persian without falling back to English', (
      tester,
    ) async {
      await _pump(tester, const SettingsPage(), locale: const Locale('fa'));

      expect(find.text('امنیت و بازیابی'), findsOneWidget);
      expect(find.textContaining('Security & recovery'), findsNothing);
      await _reveal(tester, 'settings-about');
      expect(find.text('درباره'), findsOneWidget);
    });

    testWidgets('survives the largest supported text scale', (tester) async {
      await _pump(tester, const SettingsPage(), textScale: 2);
      expect(tester.takeException(), isNull);
      await _reveal(tester, 'settings-log-out');
      expect(find.byKey(const ValueKey('settings-log-out')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Appearance', () {
    testWidgets('offers three themes and three languages, none preselected '
        'beyond the stored one', (tester) async {
      await _pump(tester, const AppearancePage());

      for (final theme in AppThemePreference.values) {
        expect(
          find.byKey(ValueKey('appearance-theme-${theme.name}')),
          findsOneWidget,
        );
      }
      for (final language in AppLanguagePreference.values) {
        await _reveal(tester, 'appearance-language-${language.name}');
        expect(
          find.byKey(ValueKey('appearance-language-${language.name}')),
          findsOneWidget,
        );
      }
      expect(
        find.textContaining('stay on this phone'),
        findsOneWidget,
        reason: 'the client-only scope is stated, not implied',
      );
      expect(
        find.textContaining('High contrast follows your phone'),
        findsOneWidget,
        reason: 'the one display setting this screen does not own says so',
      );
    });

    testWidgets('a choice is applied immediately', (tester) async {
      final container = await _pump(tester, const AppearancePage());

      await _reveal(tester, 'appearance-theme-dark');
      await tester.tap(find.byKey(const ValueKey('appearance-theme-dark')));
      await tester.pumpAndSettle();

      expect(
        container.read(appearancePreferencesProvider).theme,
        AppThemePreference.dark,
      );
    });

    testWidgets('a choice that could not be stored says so', (tester) async {
      await _pump(
        tester,
        const AppearancePage(),
        appearance: _FailingAppearanceController.new,
      );

      await _reveal(tester, 'appearance-language-persian');
      await tester.tap(
        find.byKey(const ValueKey('appearance-language-persian')),
      );
      await tester.pumpAndSettle();

      // The notice lives at the top of the screen, above both groups, so the
      // list is dragged back up to read it.
      await tester.dragUntilVisible(
        find.textContaining('could not save the choice'),
        find.byType(Scrollable).first,
        const Offset(0, 200),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('could not save the choice'),
        findsOneWidget,
        reason: 'a preference that will not survive a restart is not silent',
      );
    });

    testWidgets('language names are written in their own language', (
      tester,
    ) async {
      await _pump(tester, const AppearancePage());
      await _reveal(tester, 'appearance-language-persian');
      expect(find.text('English'), findsOneWidget);
      expect(find.text('فارسی'), findsOneWidget);
    });
  });

  group('Security & recovery', () {
    testWidgets('explains why a saved secret cannot be shown again', (
      tester,
    ) async {
      await _pump(tester, const SecuritySettingsPage());

      expect(find.textContaining('never keeps a copy'), findsOneWidget);
      expect(
        find.textContaining('unreadable backup of your identity'),
        findsOneWidget,
        reason: 'the server-side limit is stated where it matters',
      );
      expect(
        find.byKey(const ValueKey('security-rotate-recovery')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('security-safety-numbers')),
        findsOneWidget,
      );
    });
  });

  group('Recovery rotation', () {
    testWidgets('blocks screen capture for as long as the route is mounted', (
      tester,
    ) async {
      final control = _RecordingScreenControl();
      await _pump(tester, RecoveryRotationPage(control: control));
      expect(control.enabled, [true]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(control.enabled, [true, false]);
    });

    testWidgets('states the cost before the button that pays it', (
      tester,
    ) async {
      await _pump(tester, const RecoveryRotationPage());

      expect(find.textContaining('stops working'), findsOneWidget);
      expect(find.textContaining('shown once'), findsOneWidget);
      expect(
        find.textContaining('never what was said'),
        findsOneWidget,
        reason: 'recovery restores identity, never history',
      );
      expect(
        find.byKey(const ValueKey('recovery-rotation-secret')),
        findsNothing,
        reason: 'nothing is generated until the user asks for it',
      );
    });

    testWidgets('shows the new secret only after the server accepted it', (
      tester,
    ) async {
      final control = _RecordingScreenControl();
      await _pump(
        tester,
        RecoveryRotationPage(control: control),
        rotate: _rotation(),
      );

      await tester.tap(find.byKey(const ValueKey('recovery-rotation-start')));
      await tester.pumpAndSettle();

      expect(find.text(rotatedRecoverySecret), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recovery-rotation-copy')));
      await tester.pumpAndSettle();
      expect(control.copied, [rotatedRecoverySecret]);
      expect(find.textContaining('cleared in a minute'), findsOneWidget);
    });

    testWidgets('a refused upload shows no secret and says the old one works', (
      tester,
    ) async {
      await _pump(
        tester,
        const RecoveryRotationPage(),
        rotate: _rotation(
          uploadFailure: const TransportFailure(TransportFailureKind.offline),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('recovery-rotation-start')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('recovery-rotation-secret')),
        findsNothing,
      );
      expect(find.text('Nothing changed'), findsOneWidget);
      expect(
        find.textContaining('still works'),
        findsOneWidget,
        reason: 'a user must never be left holding a secret that opens nothing',
      );
    });

    testWidgets(
      'a build with no clipboard path says so instead of pretending',
      (tester) async {
        final control = _RecordingScreenControl(canCopy: false);
        await _pump(
          tester,
          RecoveryRotationPage(control: control),
          rotate: _rotation(),
        );

        await tester.tap(find.byKey(const ValueKey('recovery-rotation-start')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('recovery-rotation-copy')));
        await tester.pumpAndSettle();

        expect(find.textContaining('Write the secret down'), findsOneWidget);
      },
    );
  });

  group('About', () {
    testWidgets('reads the build from the build, and fetches nothing', (
      tester,
    ) async {
      await _pump(tester, const AboutPage(), environment: AppEnvironment.beta);

      expect(find.byKey(const ValueKey('about-version')), findsOneWidget);
      expect(find.text('0.1.0+1'), findsOneWidget);
      expect(find.byKey(const ValueKey('about-disclosure')), findsOneWidget);
      // The build is named once, in the reviewed title, and the flavor
      // identifier never reaches a user: `BETA` beneath "(Experimental)"
      // would be a second maturity word for one artifact.
      expect(
        find.text('Communication Platform (Experimental)'),
        findsOneWidget,
      );
      expect(find.textContaining('BETA'), findsNothing);
      expect(find.textContaining('Nothing was fetched'), findsOneWidget);
      expect(find.byKey(const ValueKey('about-diagnostics')), findsOneWidget);
    });

    testWidgets('a build with no statement shows no revision', (tester) async {
      await _pump(
        tester,
        const AboutPage(),
        environment: AppEnvironment.production,
      );
      expect(find.byKey(const ValueKey('about-disclosure')), findsNothing);
    });
  });

  group('Diagnostics', () {
    testWidgets('shows exactly the text the copy button copies', (
      tester,
    ) async {
      final copied = <String>[];
      final report = DiagnosticsReport(const [
        DiagnosticEntry(
          DiagnosticField.reportFormat,
          DiagnosticValue.number(1),
        ),
        DiagnosticEntry(
          DiagnosticField.queueGapDetected,
          DiagnosticValue.flag(false),
        ),
      ]);

      await _pump(
        tester,
        DiagnosticsPage(onCopy: (text) async => copied.add(text)),
        report: report,
      );

      final shown = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('diagnostics-report-text')),
          )
          .data;
      expect(shown, report.render());

      await tester.tap(find.byKey(const ValueKey('diagnostics-copy')));
      await tester.pumpAndSettle();
      expect(copied, [report.render()]);
      expect(find.text('Report copied.'), findsOneWidget);
    });

    testWidgets('says the application sends it nowhere', (tester) async {
      await _pump(
        tester,
        DiagnosticsPage(onCopy: (_) async {}),
        report: DiagnosticsReport(const []),
      );

      expect(find.textContaining('sends it nowhere'), findsOneWidget);
      expect(find.textContaining('no message, no name'), findsOneWidget);
    });

    testWidgets('a refused clipboard is reported, not swallowed', (
      tester,
    ) async {
      await _pump(
        tester,
        DiagnosticsPage(
          onCopy: (_) async =>
              throw PlatformException(code: 'clipboard_unavailable'),
        ),
        report: DiagnosticsReport(const []),
      );

      await tester.tap(find.byKey(const ValueKey('diagnostics-copy')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diagnostics-copy-message')),
        findsOneWidget,
      );
      expect(find.textContaining('did not let the app'), findsOneWidget);
    });

    testWidgets('is readable in Persian at the largest text scale', (
      tester,
    ) async {
      await _pump(
        tester,
        DiagnosticsPage(onCopy: (_) async {}),
        report: DiagnosticsReport(const [
          DiagnosticEntry(
            DiagnosticField.reportFormat,
            DiagnosticValue.number(1),
          ),
        ]),
        locale: const Locale('fa'),
        textScale: 2,
      );

      expect(find.text('گزارش عیب‌یابی'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The report body itself stays left-to-right: it is an ASCII technical
      // document, and mirroring it would reverse lines a reader has to copy.
      final body = tester.widget<SelectableText>(
        find.byKey(const ValueKey('diagnostics-report-text')),
      );
      expect(body.textDirection, TextDirection.ltr);
    });
  });
}

/// Scrolls the list until [key] is mounted *and* inside the viewport.
///
/// `scrollUntilVisible` stops as soon as the row exists, which can leave it a
/// pixel below the fold and make the following tap miss.
Future<void> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  AppEnvironment environment = AppEnvironment.development,
  AppearanceController Function()? appearance,
  bool signedIn = false,
  RotateRecoverySecret? rotate,
  DiagnosticsReport? report,
}) async {
  final harness = signedIn ? AuthenticationHarness() : null;
  if (harness != null) {
    addTearDown(harness.close);
  }
  final container = ProviderContainer(
    overrides: [
      appEnvironmentProvider.overrideWithValue(environment),
      if (signedIn)
        authenticationUseCasesProvider.overrideWithValue(harness!.useCases),
      if (appearance != null)
        appearancePreferencesProvider.overrideWith(appearance),
      if (rotate != null)
        rotateRecoverySecretProvider.overrideWith(
          (ref) => Future<RotateRecoverySecret>.value(rotate),
        ),
      if (report != null)
        diagnosticsReportProvider.overrideWith(
          (ref) => Future<DiagnosticsReport>.value(report),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, appChild) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: AppDesignSystem(child: appChild ?? const SizedBox.shrink()),
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

base class _RecordingScreenControl extends SensitiveScreenControl {
  _RecordingScreenControl({this.canCopy = true});

  final bool canCopy;
  final enabled = <bool>[];
  final copied = <String>[];

  @override
  Future<void> setEnabled(bool value) async => enabled.add(value);

  @override
  Future<bool> copyText(String text) async {
    if (canCopy) {
      copied.add(text);
    }
    return canCopy;
  }
}

base class _FailingAppearanceController extends AppearanceController {
  @override
  Future<Result<void>> update(AppearancePreferences preferences) async {
    state = preferences;
    return const Result.failure(StorageFailure(StorageFailureKind.unavailable));
  }
}

/// The production use case, over ports that answer without a network.
///
/// The screen is tested against the real rotation rather than a stand-in,
/// because the property being asserted — no secret unless the server accepted
/// the upload — lives in the use case, and a fake would only prove that the
/// fake behaves.
RotateRecoverySecret _rotation({Failure? uploadFailure}) =>
    RotateRecoverySecret(
      identities: FakeIdentityStore(),
      crypto: FakeRotationCrypto(),
      repository: FakeEnrollmentRepository()..uploadFailure = uploadFailure,
      versions: FakeBackupVersionStore(),
    );
