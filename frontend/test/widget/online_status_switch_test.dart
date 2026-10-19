import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/signal_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/settings/presentation/settings_page.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-098 D9 and D11: the Settings switch "Show my online status" writes the
/// preference of this phone, is read as one switch, and fits in both languages
/// at 200% text.
void main() {
  group('the Settings switch', () {
    late MemoryPresenceSharePreference store;
    late PresenceShareSetting setting;

    setUp(() {
      store = MemoryPresenceSharePreference();
      setting = PresenceShareSetting(store);
    });

    tearDown(() => setting.dispose());

    Future<void> pump(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
      double textScale = 1,
    }) async {
      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
          presenceShareSettingProvider.overrideWith(
            (ref) => Future<PresenceShareSetting>.value(setting),
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: AppDesignSystem(child: child ?? const SizedBox.shrink()),
            ),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('settings-online-status'));
      await tester.scrollUntilVisible(
        row,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    final row = find.byKey(const ValueKey('settings-online-status'));

    bool shown(WidgetTester tester) =>
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

    testWidgets('is on by default and says what it does', (tester) async {
      await pump(tester);

      expect(find.text('Show my online status'), findsOneWidget);
      expect(
        find.text(
          'Off on this phone: nobody sees when you are online or typing, and '
          "you do not see anyone's.",
        ),
        findsOneWidget,
      );
      expect(shown(tester), isTrue);
    });

    testWidgets('turning it off writes the preference, and on writes it '
        'back', (tester) async {
      await pump(tester);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(store.sharing, isFalse);
      expect(await setting.read(), isFalse);
      expect(shown(tester), isFalse);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(store.sharing, isTrue);
      expect(shown(tester), isTrue);
    });

    testWidgets('shows what is stored when the phone has it off', (
      tester,
    ) async {
      store.sharing = false;
      await pump(tester);

      expect(shown(tester), isFalse);
    });

    testWidgets('is read as one switch', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      final switches = find.descendant(of: row, matching: find.byType(Switch));
      expect(switches, findsOneWidget);
      final node = tester.getSemantics(find.byType(SwitchListTile));
      expect(
        node,
        isSemantics(hasToggledState: true, isToggled: true, hasTapAction: true),
      );
      expect(node.label, contains('Show my online status'));
      expect(node.label, contains('nobody sees when you are online'));
      expect(
        find.bySemanticsLabel(RegExp('Show my online status')),
        findsOneWidget,
        reason: 'the title is not a second node beside the switch',
      );
      semantics.dispose();
    });

    testWidgets('reports a failed save of the on choice', (tester) async {
      // Off on a store that cannot write.
      setting = PresenceShareSetting(
        _FailingSharePreference(MemoryPresenceSharePreference(sharing: false)),
      );
      await pump(tester);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        find.text('This choice could not be saved on this phone.'),
        findsOneWidget,
      );
      expect(shown(tester), isFalse, reason: 'on is applied only once stored');
    });

    testWidgets('in Persian, without an overflow at 200% text', (tester) async {
      await pump(tester, locale: const Locale('fa'), textScale: 2);

      expect(find.text('نمایش وضعیت آنلاین من'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A store that reads what [delegate] holds and cannot write.
final class _FailingSharePreference implements PresenceSharePort {
  _FailingSharePreference(this.delegate);

  final PresenceSharePort delegate;

  @override
  Future<bool> readSharing() => delegate.readSharing();

  @override
  Future<Result<void>> writeSharing({required bool sharing}) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));
}
