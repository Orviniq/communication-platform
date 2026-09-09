import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_route_state.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/settings/presentation/settings_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart';

/// The erase-account action, its confirmation, and the four answers the route
/// gives it.
///
/// The wording is the requirement here rather than the packaging around it, so
/// the first test asserts the statements themselves and not that a dialog
/// opened. `backend/SECURITY.md` § "Best-effort features, worded honestly"
/// keeps three deletion meanings apart, and a confirmation that promised to
/// erase messages would collapse two of them.
void main() {
  group('The action', () {
    testWidgets('sits apart from log out, marked destructive', (tester) async {
      await _pump(tester);

      await _reveal(tester, 'settings-erase-account');
      final row = find.byKey(const ValueKey('settings-erase-account'));
      expect(row, findsOneWidget);

      // Below log out, not beside it: the last thing on the screen, so a thumb
      // that missed the row above cannot land on the irreversible one.
      final logOut = tester.getRect(
        find.byKey(const ValueKey('settings-log-out')),
      );
      final erase = tester.getRect(row);
      expect(erase.top, greaterThan(logOut.bottom));

      // `SettingsEntry` puts the key on the tile itself.
      final title = tester.widget<ListTile>(row).title! as Text;
      expect(
        title.style?.color,
        _dangerColour(tester),
        reason: 'the row is marked destructive in its own colour',
      );
    });

    testWidgets('is disabled while the session is busy', (tester) async {
      final container = await _pump(tester);
      container
          .read(authenticationControllerProvider.notifier)
          .state = const AuthenticationViewState(
        access: AuthenticationRouteAccess.fullScope,
        operation: AuthenticationOperation.logout,
      );
      await tester.pumpAndSettle();

      await _reveal(tester, 'settings-erase-account');
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('settings-erase-account')),
      );
      expect(tile.enabled, isFalse);
    });
  });

  group('The confirmation', () {
    testWidgets('states all four consequences before it asks for anything', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);

      // 1. What the call does reach.
      expect(
        find.textContaining('Everything the server holds for this account'),
        findsOneWidget,
      );
      // 2. What it does not, which is the statement the rule is about.
      expect(
        find.textContaining('The copies other people hold are not erased'),
        findsOneWidget,
      );
      expect(
        find.textContaining('decrypted on the phone of the person'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing in this reaches another device'),
        findsOneWidget,
      );
      // 3. The attachments the call cannot identify, with the window named.
      expect(
        find.textContaining('stay on the server for up to 10 days'),
        findsOneWidget,
        reason: 'the deployment window, not the default this build ships',
      );
      // 4. The username somebody else may take.
      expect(
        find.textContaining('username becomes free again at once'),
        findsOneWidget,
      );

      // And it asks for the password, without offering to fill it in.
      expect(
        find.byKey(const ValueKey('erase-account-password')),
        findsOneWidget,
      );
      expect(
        find.textContaining('stored nowhere'),
        findsOneWidget,
        reason: 'the screen says what happens to what it is asking for',
      );
    });

    testWidgets('will not send an empty password', (tester) async {
      final container = await _pump(tester);
      await _open(tester);

      expect(_confirmEnabled(tester), isFalse);
      await _press(tester, 'erase-account-confirm');
      expect(_repository(container).eraseCalls, 0);
    });

    testWidgets('renders in Persian without falling back to English', (
      tester,
    ) async {
      await _pump(tester, locale: const Locale('fa'));
      await _open(tester);

      expect(find.text('این حساب پاک شود؟'), findsOneWidget);
      expect(
        find.textContaining('نسخه‌هایی که دیگران دارند پاک نمی‌شوند'),
        findsOneWidget,
      );
      expect(find.textContaining('The copies other people'), findsNothing);
    });

    testWidgets('survives the largest supported text scale', (tester) async {
      await _pump(tester, textScale: 2);
      await _open(tester);

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('The copies other people hold are not erased'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('erase-account-confirm')),
        findsOneWidget,
      );
    });

    testWidgets('cancelling is a complete outcome', (tester) async {
      final container = await _pump(tester);
      await _open(tester);

      await _press(tester, 'erase-account-cancel');

      expect(
        find.byKey(const ValueKey('erase-account-password')),
        findsNothing,
      );
      expect(_repository(container).eraseCalls, 0);
      expect(_session(container).forgotErasedAccount, isFalse);
    });
  });

  group('The answers', () {
    testWidgets('a 204 clears the local store and lands on sign-in', (
      tester,
    ) async {
      final container = await _pump(tester, routed: true);
      await _open(tester);
      await _submit(tester, 'correct-horse-battery-staple');

      expect(
        _session(container).forgotErasedAccount,
        isTrue,
        reason: 'the wipe a logout performs runs, without the logout request',
      );
      expect(
        container.read(authenticationControllerProvider).access,
        AuthenticationRouteAccess.signedOut,
      );
      expect(
        find.byKey(const ValueKey('erase-account-password')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('sign-in-destination')),
        findsOneWidget,
        reason: 'the route guard reads the signed-out access and redirects',
      );
    });

    testWidgets('a 401 token_revoked on a retry counts as success', (
      tester,
    ) async {
      // The answer to the first call was lost, the user pressed the button
      // again, and the token that call presented died with the account. The
      // first call landed, so this is the same outcome as a 204 and never an
      // error the user has to interpret.
      final container = await _pump(
        tester,
        routed: true,
        eraseResults: const [
          Result.failure(BackendFailure(BackendFailureCode.tokenRevoked)),
        ],
      );
      await _open(tester);
      await _submit(tester, 'correct-horse-battery-staple');

      expect(_session(container).forgotErasedAccount, isTrue);
      expect(
        container.read(authenticationControllerProvider).access,
        AuthenticationRouteAccess.signedOut,
      );
      expect(find.byKey(const ValueKey('sign-in-destination')), findsOneWidget);
      expect(
        find.textContaining('revoked'),
        findsNothing,
        reason: 'a landed erasure is never reported as a revoked session',
      );
    });

    testWidgets('a wrong password counts the tries and names the lock', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        eraseResults: const [
          Result.failure(BackendFailure(BackendFailureCode.invalidCredentials)),
          Result.failure(BackendFailure(BackendFailureCode.invalidCredentials)),
        ],
      );
      await _open(tester);

      await _submit(tester, 'wrong-one');
      expect(find.textContaining('1 of 5 tries used'), findsOneWidget);
      expect(
        find.textContaining('locked for fifteen minutes'),
        findsOneWidget,
        reason: 'the cost of the fifth try is stated before it is spent',
      );
      expect(
        find.textContaining('on the sign-in screen, on every device'),
        findsOneWidget,
        reason: 'the lock stops signing in too, which is the sharper half',
      );
      // Still signed in, still on the dialog, and the field is empty again.
      expect(
        container.read(authenticationControllerProvider).access,
        AuthenticationRouteAccess.fullScope,
      );
      expect(_session(container).forgotErasedAccount, isFalse);
      expect(_confirmEnabled(tester), isFalse);

      await _submit(tester, 'wrong-two');
      expect(find.textContaining('2 of 5 tries used'), findsOneWidget);
    });

    testWidgets('a 429 shows the wait it was given', (tester) async {
      await _pump(
        tester,
        eraseResults: const [
          Result.failure(
            BackendFailure(
              BackendFailureCode.rateLimited,
              retryAfter: Duration(seconds: 754),
            ),
          ),
        ],
      );
      await _open(tester);
      await _submit(tester, 'correct-horse-battery-staple');

      // 754 seconds rounds *up* to thirteen minutes. Naming a moment the
      // server still refuses would cost the user a second refusal.
      expect(find.textContaining('Try again in 13 minutes'), findsOneWidget);
    });

    testWidgets('a 429 under a minute is stated in seconds', (tester) async {
      await _pump(
        tester,
        eraseResults: const [
          Result.failure(
            BackendFailure(
              BackendFailureCode.rateLimited,
              retryAfter: Duration(seconds: 20),
            ),
          ),
        ],
      );
      await _open(tester);
      await _submit(tester, 'correct-horse-battery-staple');

      expect(find.textContaining('Try again in 20 seconds'), findsOneWidget);
    });

    testWidgets('an ordinary failure gets a reviewed string, never the server '
        'detail', (tester) async {
      await _pump(
        tester,
        eraseResults: const [
          Result.failure(TransportFailure(TransportFailureKind.offline)),
        ],
      );
      await _open(tester);
      await _submit(tester, 'correct-horse-battery-staple');

      expect(
        find.textContaining('Try again in'),
        findsNothing,
        reason: 'an unreachable server is not a cool-off',
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the password reaches the request body and nothing else', (
    tester,
  ) async {
    const password = 'correct-horse-battery-staple';
    final printed = <String>[];
    final original = debugPrint;
    // Restored inside the body rather than in a tear-down: the framework
    // asserts that no foundation debug variable outlives the test, and that
    // check runs before tear-downs do.
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        printed.add(message);
      }
    };
    late final ProviderContainer container;
    try {
      container = await _pump(tester, routed: true);
      await _open(tester);
      await _submit(tester, password);
    } finally {
      debugPrint = original;
    }

    // It reached the one place it is meant to reach, once.
    expect(_repository(container).erasePasswords, [password]);

    // And nowhere else. The session port is the only storage this composition
    // has, and the method the erasure calls on it takes no argument at all;
    // the view state that survives the dialog holds no password field to have
    // put it in.
    expect(_session(container).forgotErasedAccount, isTrue);
    final view = container.read(authenticationControllerProvider);
    expect(view.username, isNull);
    expect(view.userId, isNull);
    expect(view.toString(), isNot(contains(password)));

    // Nothing on the screen echoed it while it was being typed, and nothing
    // printed it. `debugPrint` is where a stray `print`, an assertion message
    // and a framework error dump all come out.
    for (final widget in tester.widgetList<Text>(find.byType(Text))) {
      expect(widget.data ?? '', isNot(contains(password)));
    }
    expect(printed.join('\n'), isNot(contains(password)));
  });
}

Color _dangerColour(WidgetTester tester) => tester
    .element(find.byKey(const ValueKey('settings-screen')))
    .findAncestorWidgetOfExactType<MaterialApp>()!
    .theme!
    .extension<AppThemeTokens>()!
    .colors
    .danger;

WidgetAuthenticationRepository _repository(ProviderContainer container) =>
    (container.read(authenticationUseCasesProvider).erase.repository
        as WidgetAuthenticationRepository);

WidgetAuthenticationSession _session(ProviderContainer container) =>
    container.read(authenticationUseCasesProvider).erase.session
        as WidgetAuthenticationSession;

bool _confirmEnabled(WidgetTester tester) =>
    tester
        .widget<AppButton>(find.byKey(const ValueKey('erase-account-confirm')))
        .onPressed !=
    null;

Future<void> _open(WidgetTester tester) async {
  await _reveal(tester, 'settings-erase-account');
  await tester.tap(find.byKey(const ValueKey('settings-erase-account')));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const ValueKey('erase-account-password')),
    password,
  );
  await tester.pumpAndSettle();
  await _press(tester, 'erase-account-confirm');
}

/// Scrolls the dialog to a button before pressing it.
///
/// The confirmation is taller than a phone screen on purpose — four statements
/// have to be readable before the field is — so its own scroll view is part of
/// the surface under test rather than an inconvenience around it.
Future<void> _press(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Settings, signed in, with the erase call answering [eraseResults] in order.
///
/// [routed] swaps the bare page for the production route guard over two routes.
/// It is the smallest composition in which "goes to the sign-in screen" is a
/// fact rather than a claim about a state value: `AuthenticationRouteState` is
/// the production class, wired to the production controller exactly as
/// `app.dart` wires it, and the redirect it returns is the one `createAppRouter`
/// asks it for.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  bool routed = false,
  List<Result<void>> eraseResults = const [],
}) async {
  final harness = AuthenticationHarness(eraseResults: eraseResults);
  addTearDown(harness.close);
  final container = ProviderContainer(
    overrides: [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      // The window the dialog names is the deployment's, not this build's
      // default, so the harness supplies one that differs from it.
      publishedLimitsProvider.overrideWithValue(_publishedTenDays),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(authenticationControllerProvider.notifier)
      .state = const AuthenticationViewState(
    access: AuthenticationRouteAccess.fullScope,
    operation: AuthenticationOperation.idle,
    username: 'someone',
    userId: userId,
  );

  Widget wrap(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: AppDesignSystem(child: child ?? const SizedBox.shrink()),
  );

  Widget application;
  if (routed) {
    final routeState = AuthenticationRouteState();
    addTearDown(routeState.dispose);
    final subscription = container.listen(
      authenticationControllerProvider,
      (previous, next) => routeState.update(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    final router = GoRouter(
      initialLocation: '/settings',
      refreshListenable: routeState,
      redirect: (context, state) =>
          routeState.redirect(state.uri.path, state.uri.toString()),
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/login',
          builder: (context, state) =>
              const Scaffold(key: ValueKey('sign-in-destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    application = MaterialApp.router(
      theme: AppTheme.light(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: wrap,
      routerConfig: router,
    );
  } else {
    application = MaterialApp(
      theme: AppTheme.light(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: wrap,
      home: const SettingsPage(),
    );
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: application),
  );
  await tester.pumpAndSettle();
  return container;
}

/// A deployment that keeps an attachment for ten days rather than the thirty
/// this build defaults to.
const _publishedTenDays = ServerConfig(
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
