import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/routing/app_router.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/settings/presentation/security_settings_page.dart';
import 'package:communication_platform/features/voice/presentation/create_voice_room_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart';

const _narrow = Size(360, 800);
const _wide = Size(1440, 900);

void main() {
  testWidgets('every page above a tab root opens on the root navigator', (
    tester,
  ) async {
    final router = createAppRouter(environment: AppEnvironment.production);
    addTearDown(router.dispose);
    final root = router.configuration.navigatorKey;
    final shell = router.configuration.routes
        .whereType<StatefulShellRoute>()
        .single;
    final tabRoots = [
      for (final branch in shell.branches) ...branch.routes.cast<GoRoute>(),
    ];
    expect(tabRoots.map((route) => route.path), [
      '/chats',
      '/voice-rooms',
      '/settings',
    ]);

    // Nested routes included: one that names no navigator stays in its
    // branch, under a parent on the root navigator, where nobody sees it.
    final pages = <String, GoRoute>{};
    void collect(String parent, GoRoute route) {
      for (final child in route.routes.cast<GoRoute>()) {
        final path = '$parent/${child.path}';
        pages[path] = child;
        collect(path, child);
      }
    }

    for (final tabRoot in tabRoots) {
      expect(tabRoot.parentNavigatorKey, isNull, reason: tabRoot.path);
      collect(tabRoot.path, tabRoot);
    }
    expect(pages.keys, [
      '/chats/new',
      '/chats/conversation/:conversationId',
      '/chats/direct/:userId',
      '/voice-rooms/new',
      '/voice-rooms/:roomId',
      '/voice-rooms/:roomId/call',
      '/voice-rooms/:roomId/invite',
      '/settings/appearance',
      '/settings/security',
      '/settings/security/recovery',
      '/settings/security/safety-numbers',
      '/settings/about',
      '/settings/about/diagnostics',
      '/settings/profile',
      '/settings/linked-devices',
      '/settings/receiving-while-closed',
    ]);
    for (final MapEntry(key: path, value: route) in pages.entries) {
      expect(route.parentNavigatorKey, same(root), reason: path);
    }

    // A key of its own for each router: one key marks one navigator.
    final other = createAppRouter(environment: AppEnvironment.production);
    addTearDown(other.dispose);
    expect(other.configuration.navigatorKey, isNot(same(root)));
  });

  group('a page above a tab root covers the shell', () {
    for (final size in [_narrow, _wide]) {
      final shell = ValueKey(size == _narrow ? 'shell-narrow' : 'shell-wide');
      for (final (location, page) in [
        ('/chats/conversation/c-01?peer=peer-01', DirectChatPage),
        ('/voice-rooms/new', CreateVoiceRoomPage),
        ('/settings/security', SecuritySettingsPage),
      ]) {
        testWidgets('$location at ${size.width.round()} wide', (tester) async {
          await _pumpApp(tester, size: size, initialLocation: location);

          expect(find.byType(page), findsOneWidget);
          expect(find.byKey(shell), findsNothing);
          // Covered rather than replaced: the shell waits below the page.
          expect(find.byKey(shell, skipOffstage: false), findsOneWidget);
        });
      }
    }
  });

  group('a tab root keeps the navigation bar and the rail', () {
    for (final location in ['/chats', '/voice-rooms', '/settings']) {
      testWidgets(location, (tester) async {
        await _pumpApp(tester, size: _narrow, initialLocation: location);
        expect(find.byKey(const ValueKey('shell-narrow')), findsOneWidget);
        _expectDestinations(tester);

        await _resize(tester, _wide);
        expect(find.byKey(const ValueKey('shell-wide')), findsOneWidget);
        _expectDestinations(tester);
      });
    }
  });

  testWidgets('back from a direct chat returns to the Chats list at the '
      'same place', (tester) async {
    await _pumpApp(tester, size: _narrow, summaries: _summaries());
    final offset = await _scrollChats(tester);

    await tester.tap(find.text('peer-20'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('direct-chat-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(find.byKey(const ValueKey('chats-list-screen')), findsOneWidget);
    expect(_chatsOffset(tester), offset);
  });

  testWidgets('back from a Settings page returns to Settings', (tester) async {
    await _pumpApp(tester, size: _narrow, initialLocation: '/settings');

    await tester.tap(find.byKey(const ValueKey('settings-security')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('security-settings-screen')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-narrow')), findsOneWidget);
  });
}

void _expectDestinations(WidgetTester tester) {
  for (final label in ['Chats', 'Voice Rooms', 'Settings']) {
    expect(find.text(label).hitTestable(), findsWidgets, reason: label);
  }
}

/// Forty conversations, newest first: a group at 24 and Saved Messages at 26,
/// and a direct conversation with `peer-NN` at every other place.
List<ConversationSummary> _summaries() => [
  for (var index = 0; index < 40; index += 1)
    ConversationSummary(
      conversationId: 'c-${index.toString().padLeft(2, '0')}',
      kind: switch (index) {
        24 => ConversationKind.group,
        26 => ConversationKind.saved,
        _ => ConversationKind.direct,
      },
      peerUserId: index == 24 || index == 26
          ? null
          : 'peer-${index.toString().padLeft(2, '0')}',
      lastMessage: 'message $index',
      lastActivityMs:
          DateTime.utc(2026, 10, 8).millisecondsSinceEpoch - index * 60000,
      unreadCount: 0,
      mutedUntil: null,
      draft: null,
      pinnedMessageIds: const {},
      displayTitle: index == 24 ? 'Weekend plans' : null,
    ),
];

/// Mounts the application signed in, on the real router, over providers that
/// never reach storage: the database never opens, and the few projections
/// the pages under test draw are answered here.
Future<void> _pumpApp(
  WidgetTester tester, {
  required Size size,
  String initialLocation = '/chats',
  List<ConversationSummary> summaries = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = AuthenticationHarness();
  addTearDown(harness.close);
  final container = ProviderContainer(
    overrides: [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      localDatabaseProvider.overrideWith(
        (ref) => Completer<LocalDatabase>().future,
      ),
      conversationSummariesProvider.overrideWith(
        (ref, userId) => Stream.value(summaries),
      ),
      conversationMessagesProvider.overrideWith(
        (ref, request) => Stream.value(
          const ConversationTimelineState(
            page: ConversationMessagePage.empty,
            loadingBefore: false,
            olderLoadFailed: false,
          ),
        ),
      ),
      contactListProvider.overrideWith((ref, userId) => Stream.value(const [])),
      voiceRoomsProvider.overrideWith((ref) => Stream.value(const [])),
    ],
  );
  addTearDown(container.dispose);
  final signedIn = await container
      .read(authenticationControllerProvider.notifier)
      .login(username: 'reader', password: 'correct horse battery');
  expect(signedIn, isTrue);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: const Locale('en'),
        themeMode: ThemeMode.light,
        initialLocation: initialLocation,
      ),
    ),
  );
  await _settle(tester);
}

/// Long enough for a route transition and for the projections to answer. A
/// page still loading shows a spinner, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await _settle(tester);
}

ScrollPosition _chatsPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('chats-list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

double _chatsOffset(WidgetTester tester) => _chatsPosition(tester).pixels;

/// Scrolls the Chats list well past its first screen, and returns where it
/// stopped.
Future<double> _scrollChats(WidgetTester tester) async {
  _chatsPosition(tester).jumpTo(1500);
  await tester.pump();
  final offset = _chatsOffset(tester);
  expect(offset, 1500);
  return offset;
}
