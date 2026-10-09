import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/app_shell/presentation/app_shell.dart';
import 'package:communication_platform/features/voice/presentation/voice_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('selects narrow, medium, and wide structures by measured width', (
    tester,
  ) async {
    await _pumpApp(tester, size: const Size(360, 800));
    expect(find.byKey(const ValueKey('shell-narrow')), findsOneWidget);

    await _resize(tester, const Size(800, 900));
    expect(find.byKey(const ValueKey('shell-medium')), findsOneWidget);

    await _resize(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('shell-wide')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preserves a nested route and its draft while resizing across '
      'breakpoints', (tester) async {
    await _pumpApp(
      tester,
      size: const Size(360, 800),
      initialLocation: '/voice-rooms/new',
    );
    expect(
      find.byKey(const ValueKey('create-voice-room-screen')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('voice-room-name-field')),
        matching: find.byType(EditableText),
      ),
      'Standup',
    );

    // The page covers the shell at every width; the rail of the wide shell
    // waits below it.
    await _resize(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('shell-wide')), findsNothing);
    expect(
      find.byKey(const ValueKey('shell-wide'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-voice-room-screen')),
      findsOneWidget,
    );
    expect(find.text('Standup'), findsOneWidget);
  });

  testWidgets('keyboard shortcuts navigate the stable destination set', (
    tester,
  ) async {
    await _pumpApp(tester, size: const Size(1440, 900));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('voice-rooms-screen')), findsOneWidget);
    expect(find.text('No voice rooms yet'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('Linked Devices'), findsOneWidget);
  });

  testWidgets('guard hook can reject a protected destination', (tester) async {
    await _pumpApp(tester, size: const Size(1440, 900), guardSettings: true);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.text('No chats yet'), findsOneWidget);
    expect(find.text('Linked Devices'), findsNothing);
  });

  testWidgets('withdraws compose on a page pushed above the destination', (
    tester,
  ) async {
    await _pumpApp(tester, size: const Size(360, 800));
    expect(find.byTooltip('Start a conversation'), findsOneWidget);
    final router = GoRouter.of(
      tester.element(find.byKey(const ValueKey('shell-narrow'))),
    );

    // A sub-route of the branch, reached by navigating rather than by booting
    // into it. The page covers the shell, and the shell under it re-reads the
    // location and withdraws compose too.
    router.go('/voice-rooms/new');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('create-voice-room-screen')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);
    for (final compose in ['Create a voice room', 'Start a conversation']) {
      expect(find.byTooltip(compose, skipOffstage: false), findsNothing);
    }

    router.go('/voice-rooms');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Create a voice room'), findsOneWidget);
  });

  testWidgets('large text on an Android-sized viewport does not overflow', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpApp(tester, size: const Size(360, 800));

    expect(find.text('Chats'), findsWidgets);
    expect(find.text('Voice Rooms'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Start a chat'));
    await tester.pumpAndSettle();
    expect(find.text('Start a chat').hitTestable(), findsOneWidget);
  });

  testWidgets('dark and authored high-contrast themes expose semantic tokens', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      size: const Size(800, 900),
      themeMode: ThemeMode.dark,
    );
    var context = tester.element(
      find.byKey(const ValueKey('chats-list-screen')),
    );
    expect(context.tokens.colors.canvas, const Color(0xFF0E1014));
    expect(context.tokens.colors.accent, const Color(0xFF8298FF));

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      const CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: Locale('en'),
        themeMode: ThemeMode.light,
      ),
    );
    await tester.pumpAndSettle();
    context = tester.element(find.byKey(const ValueKey('chats-list-screen')));
    expect(context.tokens.colors.canvas, Colors.white);
    expect(context.tokens.colors.border, Colors.black);
  });

  testWidgets('reduced motion removes spatial route travel', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpApp(tester, size: const Size(360, 800));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('voice-rooms-screen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-route-spatial-transition')),
      findsNothing,
    );
  });

  testWidgets('a call in progress raises a banner on every screen but its own, '
      'and the banner returns to it', (tester) async {
    final semantics = tester.ensureSemantics();
    const roomId =
        'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';
    await _pumpApp(
      tester,
      size: const Size(360, 800),
      status: const AppShellStatus(
        activeVoiceRoomId: roomId,
        activeVoiceRoomName: 'Standup',
        activeVoiceMuted: true,
      ),
    );

    final banner = find.byKey(const ValueKey('active-voice-banner'));
    expect(banner, findsOneWidget);
    expect(find.text('Return to voice room: Standup'), findsOneWidget);
    expect(
      tester.getSemantics(banner).label,
      'Return to voice room: Standup, Muted',
    );
    final router = GoRouter.of(
      tester.element(find.byKey(const ValueKey('shell-narrow'))),
    );

    await tester.tap(banner);
    // The call screen shows a spinner in this harness, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // On the call's own screen the banner would only point at itself, and
    // the shell under the screen holds none. The room's page under it keeps
    // its own, for the way back.
    expect(find.byType(VoiceCallPage), findsOneWidget);
    expect(find.byKey(const ValueKey('active-voice-banner')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shell-narrow'), skipOffstage: false),
        matching: find.byKey(
          const ValueKey('active-voice-banner'),
          skipOffstage: false,
        ),
        skipOffstage: false,
      ),
      findsNothing,
    );

    router.go('/settings');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('active-voice-banner')), findsOneWidget);

    // Atop the rail on a wide layout, and still on every screen.
    await _resize(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('shell-wide')), findsOneWidget);
    expect(find.byKey(const ValueKey('active-voice-banner')), findsOneWidget);
    semantics.dispose();
  });

  for (final (size, shell) in const [
    (Size(360, 800), 'shell-narrow'),
    (Size(800, 900), 'shell-medium'),
    (Size(1440, 900), 'shell-wide'),
  ]) {
    testWidgets('the banner above the navigation bar or atop the rail offers '
        'a tap action, and performing it opens the call, at '
        '${size.width.round()} wide', (tester) async {
      final semantics = tester.ensureSemantics();
      const roomId =
          'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';
      await _pumpApp(
        tester,
        size: size,
        status: const AppShellStatus(
          activeVoiceRoomId: roomId,
          activeVoiceRoomName: 'Standup',
        ),
      );
      expect(find.byKey(ValueKey(shell)), findsOneWidget);

      const label = 'Return to voice room: Standup, Microphone on';
      expect(
        tester.getSemantics(find.byKey(const ValueKey('active-voice-banner'))),
        isSemantics(label: label, isButton: true, hasTapAction: true),
      );
      // One node announces the banner, and none the control under it.
      expect(
        find.semantics.byLabel(RegExp('Return to voice room')),
        findsOneWidget,
      );

      tester.semantics.tap(find.semantics.byLabel(label));
      // The call screen shows a spinner in this harness, so it never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(VoiceCallPage), findsOneWidget);
      final router = GoRouter.of(tester.element(find.byType(VoiceCallPage)));
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/voice-rooms/$roomId/call',
      );
      semantics.dispose();
    });
  }

  for (final size in const [Size(360, 800), Size(1440, 900)]) {
    testWidgets('the environment banner and the connection strip reach a '
        'service at ${size.width.round()} wide', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpApp(
        tester,
        size: size,
        environment: AppEnvironment.development,
        status: const AppShellStatus(connection: AppConnectionState.offline),
      );

      // Both sit above the tab root's navigator, whose route barrier hides
      // from a service whatever was painted before it, up to the nearest
      // semantics container.
      expect(
        find.semantics.byLabel('Development configuration'),
        findsOneWidget,
      );
      expect(
        find.semantics.byLabel(RegExp('^No connection to server')),
        findsOneWidget,
      );
      semantics.dispose();
    });
  }

  testWidgets('no call raises no banner, and a server without voice offers no '
      'room to create', (tester) async {
    await _pumpApp(
      tester,
      size: const Size(360, 800),
      initialLocation: '/voice-rooms',
      status: const AppShellStatus(voiceRoomsComposeAvailable: false),
    );

    expect(find.byKey(const ValueKey('active-voice-banner')), findsNothing);
    expect(find.byTooltip('Create a voice room'), findsNothing);

    GoRouter.of(
      tester.element(find.byKey(const ValueKey('shell-narrow'))),
    ).go('/chats');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Start a conversation'), findsOneWidget);
  });
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required Size size,
  AppEnvironment environment = AppEnvironment.production,
  ThemeMode themeMode = ThemeMode.light,
  String initialLocation = '/chats',
  bool guardSettings = false,
  AppShellStatus status = const AppShellStatus(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    CommunicationPlatformApp(
      environment: environment,
      locale: const Locale('en'),
      themeMode: themeMode,
      initialLocation: initialLocation,
      shellStatus: status,
      routeGuard: guardSettings
          ? (context, state) =>
                state.uri.path.startsWith('/settings') ? '/chats' : null
          : null,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}
