import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/synchronization/application/ports/sustained_delivery_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:communication_platform/features/synchronization/presentation/sustained_delivery_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two user-facing surfaces this piece adds, in both supported languages
/// and both directions.
///
/// What is proven here is what the user sees and what the screen makes possible
/// — not what the platform does, which no host test can reach. The off state is
/// covered first and deliberately: it is the state every build ships in.
void main() {
  group('the Settings row', () {
    testWidgets('a build with no composition says so and offers nothing', (
      tester,
    ) async {
      // Route and app-shell harnesses render this without the production
      // container. It states what it can see rather than failing.
      await tester.pumpWidget(
        const MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: SustainedDeliverySettingsEntry()),
        ),
      );

      expect(find.text('Not available in this build.'), findsOneWidget);
    });

    testWidgets('off is the default, and it says what off means', (
      tester,
    ) async {
      await _pumpRow(tester, SustainedDeliveryStatus.off);

      expect(find.textContaining('Off.'), findsOneWidget);
      expect(
        find.textContaining('permanent notice'),
        findsNothing,
        reason: 'nothing is on the phone, so nothing is described as being',
      );
    });

    testWidgets('every degraded state has a summary of its own', (
      tester,
    ) async {
      for (final status in SustainedDeliveryStatus.values) {
        await _pumpRow(tester, status);
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(
          find.text(settingsSustainedSummary(l10n, status)),
          findsOneWidget,
          reason: '$status must be described, never left ambiguous',
        );
      }
    });

    testWidgets('the row is translated, not left in English', (tester) async {
      await _pumpRow(
        tester,
        SustainedDeliveryStatus.off,
        locale: const Locale('fa'),
      );

      expect(find.text('دریافت هنگام بسته بودن'), findsOneWidget);
      expect(find.textContaining('Receiving while closed'), findsNothing);
    });
  });

  group('the screen', () {
    testWidgets('states what it does, what it costs, and what it cannot do', (
      tester,
    ) async {
      await _pumpPage(tester, SustainedDeliveryStatus.off);

      expect(
        find.textContaining('kept open in the background'),
        findsOneWidget,
      );
      expect(
        find.textContaining('has not been measured'),
        findsOneWidget,
        reason:
            'ADR-053: a latency claim may only ever come from a measurement, '
            'and none has been made on any phone',
      );
      expect(
        find.textContaining('within seconds'),
        findsNothing,
        reason: 'the promise this screen shipped with, withdrawn',
      );
      expect(find.textContaining('uses more battery'), findsOneWidget);
      expect(find.textContaining('permanent notice'), findsOneWidget);
      expect(find.textContaining('cannot promise'), findsOneWidget);
      expect(
        find.textContaining('cannot check whether you have'),
        findsOneWidget,
        reason:
            'the manufacturer step must never be presented as something this '
            'application has confirmed',
      );
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.text('Turn off'), findsNothing);
    });

    testWidgets('turning it on asks the controller and nothing else', (
      tester,
    ) async {
      final controller = _FakeController(SustainedDeliveryStatus.off);
      await _pumpPage(tester, SustainedDeliveryStatus.off, controller);

      await tester.tap(find.byKey(const ValueKey('sustained-toggle')));
      await tester.pumpAndSettle();

      expect(controller.enables, 1);
      expect(controller.disables, 0);
    });

    testWidgets('a refusal is shown in the user’s own terms', (tester) async {
      final controller = _FakeController(
        SustainedDeliveryStatus.off,
        refusal: SustainedDeliveryRefusal.exemptionRefused,
      );
      await _pumpPage(tester, SustainedDeliveryStatus.off, controller);

      await tester.tap(find.byKey(const ValueKey('sustained-toggle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('did not give permission'), findsOneWidget);
    });

    testWidgets('every refusal has a sentence of its own', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final sentences = SustainedDeliveryRefusal.values
          .map((refusal) => sustainedRefusalText(l10n, refusal))
          .toSet();
      expect(
        sentences,
        hasLength(SustainedDeliveryRefusal.values.length),
        reason:
            'a refusal the user cannot tell apart from another one is a '
            'refusal they cannot act on',
      );
    });

    testWidgets('turning it off is what the screen offers once it is on', (
      tester,
    ) async {
      final controller = _FakeController(SustainedDeliveryStatus.holding);
      await _pumpPage(tester, SustainedDeliveryStatus.holding, controller);

      expect(find.text('Turn off'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sustained-toggle')));
      await tester.pumpAndSettle();

      expect(controller.disables, 1);
      expect(controller.enables, 0);
    });

    testWidgets('a degraded state is reported, not hidden', (tester) async {
      await _pumpPage(tester, SustainedDeliveryStatus.exemptionWithdrawn);

      expect(find.textContaining('taken back permission'), findsOneWidget);
      expect(
        find.textContaining('after a phone update'),
        findsOneWidget,
        reason:
            'the user is told this can happen without them doing anything, '
            'because on most of this fleet it can',
      );
      expect(find.text('Turn off'), findsOneWidget);
    });

    testWidgets('a build with no implementation offers no switch at all', (
      tester,
    ) async {
      await _pumpPage(tester, SustainedDeliveryStatus.unavailable);

      expect(find.text('Not available in this build.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('sustained-toggle')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('sustained-vendor-settings')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('a production build shows the switch on the page and in the '
        'Settings row', (tester) async {
      // The real controller, composed as a production build composes it: only
      // the platform and the signed-in state are substituted, because no host
      // test can reach either (ADR-094).
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pump(Widget home) async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              appEnvironmentProvider.overrideWithValue(
                AppEnvironment.production,
              ),
              sustainedDeliveryPlatformProvider.overrideWithValue(
                const _SupportedPlatform(),
              ),
              authenticationControllerProvider.overrideWithBuild(
                (ref, notifier) => const AuthenticationViewState.dormant(),
              ),
            ],
            child: MaterialApp(
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: home,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(const Scaffold(body: SustainedDeliverySettingsEntry()));
      expect(find.text('Receiving while closed'), findsOneWidget);
      expect(find.textContaining('Off.'), findsOneWidget);
      expect(find.text('Not available in this build.'), findsNothing);

      await pump(const SustainedDeliveryPage());
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.text('Not available in this build.'), findsNothing);
      for (final key in const [
        ValueKey('sustained-toggle'),
        ValueKey('sustained-vendor-settings'),
      ]) {
        expect(
          tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed,
          isNotNull,
          reason: 'a production build offers this, so the screen is live',
        );
      }
      // It still promises no time: the cost and the limits are on the screen,
      // and so is the statement that nobody has measured it.
      expect(find.textContaining('permanent notice'), findsOneWidget);
      expect(find.textContaining('has not been measured'), findsOneWidget);
      expect(find.textContaining('within seconds'), findsNothing);
    });

    testWidgets('the screen is translated and laid out right to left', (
      tester,
    ) async {
      await _pumpPage(
        tester,
        SustainedDeliveryStatus.off,
        null,
        const Locale('fa'),
      );

      expect(find.text('روشن کردن'), findsOneWidget);
      expect(find.textContaining('Turn on'), findsNothing);
      expect(
        Directionality.of(tester.element(find.text('روشن کردن'))),
        TextDirection.rtl,
      );
    });

    testWidgets('neither language overflows at a large text scale', (
      tester,
    ) async {
      for (final locale in const [Locale('en'), Locale('fa')]) {
        await _pumpPage(
          tester,
          SustainedDeliveryStatus.exemptionWithdrawn,
          null,
          locale,
          1.6,
        );
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

Future<void> _pumpRow(
  WidgetTester tester,
  SustainedDeliveryStatus status, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      // A fresh key per pump, so that re-rendering the same surface with a
      // different status inside one test really does build a new controller
      // instead of updating the overrides of the one already installed.
      key: UniqueKey(),
      overrides: [
        sustainedDeliveryControllerProvider.overrideWith(
          () => _FakeController(status),
        ),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(body: SustainedDeliverySettingsEntry()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(
  WidgetTester tester,
  SustainedDeliveryStatus status, [
  _FakeController? controller,
  Locale locale = const Locale('en'),
  double textScale = 1,
]) async {
  // Tall enough that the whole screen is laid out. A ListView builds only what
  // fits, so on the default 800x600 surface the status and the switch would be
  // absent from the tree and every assertion about them would fail for a reason
  // that has nothing to do with this surface.
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        sustainedDeliveryControllerProvider.overrideWith(
          () => controller ?? _FakeController(status),
        ),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          // Scaled from the ambient data rather than replacing it: a
          // MediaQueryData built from nothing has no viewport, and a ListView
          // in a zero-height viewport lays out no children at all, which would
          // make every assertion below pass for the wrong reason.
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const SustainedDeliveryPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The controller as the surface sees it: a status, and three things the user
/// can ask for. Nothing about the platform is reachable from a host test, so
/// nothing about it is pretended here either.
final class _FakeController extends SustainedDeliveryController {
  _FakeController(this._status, {this.refusal});

  final SustainedDeliveryStatus _status;
  final SustainedDeliveryRefusal? refusal;
  int enables = 0;
  int disables = 0;
  int vendorScreens = 0;

  @override
  SustainedDeliveryStatus build() => _status;

  @override
  Future<SustainedDeliveryRefusal?> enable() async {
    enables += 1;
    return refusal;
  }

  @override
  Future<void> disable() async {
    disables += 1;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> openVendorSettings() async {
    vendorScreens += 1;
  }
}

/// A platform that supports the capability and is not running it, which is
/// what a phone is before its owner has turned anything on.
final class _SupportedPlatform implements SustainedDeliveryPlatformPort {
  const _SupportedPlatform();

  static const _state = SustainedDeliveryPlatformState(
    supported: true,
    running: false,
    exempt: false,
    alertsEnabled: true,
  );

  @override
  Future<SustainedDeliveryPlatformState?> platformState() async => _state;

  @override
  Future<SustainedDeliveryPlatformState?> requestExemption() async => _state;

  @override
  Future<SustainedDeliveryPlatformState?> start() async => _state;

  @override
  Future<SustainedDeliveryPlatformState?> stop() async => _state;

  @override
  Future<void> openVendorSettings() async {}
}
