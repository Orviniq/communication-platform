import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/app/routing/app_router.dart';
import 'package:communication_platform/features/app_shell/presentation/voice_room_banner.dart';
import 'package:communication_platform/features/app_shell/presentation/voice_room_banner_frame.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_route_state.dart';
import 'package:communication_platform/features/bootstrap/application/bootstrap_flow.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/settings/presentation/security_settings_page.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/presentation/create_voice_room_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_call_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../features/bootstrap/support/fake_bootstrap_ports.dart';
import '../support/authentication_harness.dart';
import '../support/system_insets.dart';
import '../support/voice_screen_harness.dart';

const _narrow = Size(360, 800);
const _medium = Size(800, 900);
const _wide = Size(1440, 900);
const _banner = ValueKey('active-voice-banner');

/// A room this device holds no state for: its call page is not the call's.
final _otherRoomId = 'ab' * 32;

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

  testWidgets('every page on the root navigator carries the call banner but '
      'the bootstrap and sign-in pages, and no tab root does', (tester) async {
    final routeState = AuthenticationRouteState();
    addTearDown(routeState.dispose);
    // Both make the router register the pages that only they reach.
    final router = createAppRouter(
      environment: AppEnvironment.production,
      bootstrapFlow: BootstrapFlow(
        configuration: FakeBootstrapConfigurationPort(
          const ConfigurationNotProvisioned(
            ConfigurationFailureKind.missingProvisioning,
          ),
        ),
        storage: FakeProtectedStoragePort(),
        trust: FakePlatformTrustPort(),
        health: FakeHealthReachabilityPort(const HealthReachable()),
        platform: BootstrapPlatform.android,
      ),
      authenticationRouteState: routeState,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));

    // Every route's page, built as the router builds it, by whether the
    // banner's frame wraps it.
    final framed = <String>[];
    final unframed = <String>[];
    void visit(String parent, RouteBase route) {
      switch (route) {
        case StatefulShellRoute(:final branches):
          for (final branch in branches) {
            for (final child in branch.routes) {
              visit(parent, child);
            }
          }
        case GoRoute(:final path, :final pageBuilder, :final routes):
          final location = path.startsWith('/') ? path : '$parent/$path';
          final page = pageBuilder!(
            context,
            GoRouterState(
              router.configuration,
              uri: Uri.parse(location),
              matchedLocation: location,
              fullPath: location,
              pathParameters: {
                'userId': 'user-01',
                'groupId': 'group-01',
                'conversationId': 'c-01',
                'roomId': voiceRoomId,
              },
              pageKey: ValueKey(location),
            ),
          );
          final child = (page as CustomTransitionPage<void>).child;
          (child is VoiceRoomBannerFrame ? framed : unframed).add(location);
          for (final child in routes) {
            visit(location, child);
          }
        default:
          fail('an unexpected route: ${route.runtimeType}');
      }
    }

    for (final route in router.configuration.routes) {
      visit('', route);
    }
    expect(unframed, [
      '/connection',
      '/login',
      '/session-restoring',
      '/register',
      '/pending-activation',
      '/encryption-setup',
      '/chats',
      '/voice-rooms',
      '/settings',
    ]);
    // The call's page too: the banner leaves the call's own page itself.
    expect(framed, [
      '/security-notice',
      '/contacts/:userId',
      '/contacts/:userId/safety',
      '/groups/new',
      '/groups/:groupId',
      '/groups/:groupId/info',
      '/groups/:groupId/edit',
      '/groups/:groupId/add-members',
      '/saved-messages',
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

  testWidgets('back from a group chat returns to the Chats list at the same '
      'place', (tester) async {
    await _pumpApp(tester, size: _narrow, summaries: _summaries());
    final offset = await _scrollChats(tester);

    await tester.tap(find.text('Weekend plans'));
    await _settle(tester);
    expect(find.byType(GroupChatPage), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(find.byKey(const ValueKey('chats-list-screen')), findsOneWidget);
    expect(_chatsOffset(tester), offset);
  });

  testWidgets('back from Saved Messages returns to the Chats list at the same '
      'place', (tester) async {
    await _pumpApp(tester, size: _narrow, summaries: _summaries());
    final offset = await _scrollChats(tester);

    await tester.tap(find.text('Saved Messages'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('saved-messages-screen')), findsOneWidget);
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

  group('a direct chat keeps its composer out of the system insets', () {
    const location = '/chats/conversation/c-01?peer=peer-01';
    final composer = find.byType(ChatComposerBuilder);
    final controls = find
        .ancestor(
          of: find.byKey(const ValueKey('chat-composer-field')),
          matching: find.byType(Row),
        )
        .first;

    testWidgets('above the gesture bar, with its colour down to the edge', (
      tester,
    ) async {
      fakeSystemInsets(tester);
      await _pumpApp(tester, size: _narrow, initialLocation: location);

      expect(tester.getRect(composer).bottom, _narrow.height);
      expect(
        tester.getRect(controls).bottom,
        lessThanOrEqualTo(_narrow.height - 48),
      );
    });

    testWidgets('above the keyboard', (tester) async {
      fakeSystemInsets(tester);
      await _pumpApp(tester, size: _narrow, initialLocation: location);
      fakeOpenKeyboard(tester);
      await _settle(tester);

      expect(
        tester.getRect(composer).bottom,
        lessThanOrEqualTo(_narrow.height - 300),
      );
    });
  });

  group('during a call', () {
    const directChat = '/chats/conversation/c-01?peer=peer-01';

    group('a full-screen page shows one banner, at its top', () {
      for (final size in [_narrow, _wide]) {
        for (final (location, page) in [
          (directChat, DirectChatPage),
          ('/voice-rooms/$voiceRoomId', VoiceRoomInfoPage),
          ('/settings/security', SecuritySettingsPage),
        ]) {
          testWidgets('$location at ${size.width.round()} wide', (
            tester,
          ) async {
            fakeSystemInsets(tester);
            final container = await _pumpApp(
              tester,
              size: size,
              initialLocation: location,
            );
            final appBar = find.descendant(
              of: find.byType(page),
              matching: find.byType(AppBar),
            );
            final withoutCall = tester.getRect(appBar);
            expect(withoutCall.top, 0);

            _startCall(container);
            await _settle(tester);

            expect(find.byType(page), findsOneWidget);
            expect(find.byKey(_banner), findsOneWidget);
            // Below the status bar, which its colour runs up under.
            final banner = tester.getRect(find.byKey(_banner));
            expect(banner.top, 24);
            expect(banner.height, greaterThanOrEqualTo(AppFocus.minimumTarget));
            expect(banner.width, size.width);
            expect(tester.getRect(find.byType(VoiceRoomBanner)).top, 0);
            // Above the app bar, which takes no second top inset.
            expect(tester.getRect(appBar).top, banner.bottom);
            expect(tester.getRect(appBar).height, withoutCall.height - 24);
          });
        }
      }
    });

    testWidgets("the call's own page shows no banner, and another room's "
        'call page does', (tester) async {
      final container = await _pumpApp(
        tester,
        size: _narrow,
        initialLocation: '/voice-rooms/$voiceRoomId',
      );
      _startCall(container);
      await _settle(tester);
      expect(find.byKey(_banner), findsOneWidget);

      // As the room's info opens the call.
      final router = GoRouter.of(
        tester.element(find.byType(VoiceRoomInfoPage)),
      );
      router.go('/voice-rooms/$voiceRoomId/call');
      await _settle(tester);
      expect(find.byType(VoiceCallPage), findsOneWidget);
      expect(find.byKey(_banner), findsNothing);
      // Nor does the shell under it hold one.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('shell-narrow'), skipOffstage: false),
          matching: find.byKey(_banner, skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
      // The room's info under it keeps its own. It is framed for its own path
      // rather than for the call's on top, so the banner stays put while the
      // call slides over it.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.byType(VoiceRoomInfoPage, skipOffstage: false),
            matching: find.byType(VoiceRoomBannerFrame, skipOffstage: false),
          ),
          matching: find.byKey(_banner, skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      router.go('/voice-rooms/$_otherRoomId/call');
      await _settle(tester);
      expect(find.byType(VoiceCallPage), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
    });

    group('a tab root shows the banner of the shell only', () {
      for (final location in ['/chats', '/voice-rooms', '/settings']) {
        testWidgets(location, (tester) async {
          final container = await _pumpApp(
            tester,
            size: _narrow,
            initialLocation: location,
          );
          _startCall(container);
          await _settle(tester);
          _expectShellBanner('shell-narrow');

          await _resize(tester, _wide);
          _expectShellBanner('shell-wide');
        });
      }
    });

    testWidgets('a tap on the banner of a full-screen page opens the call', (
      tester,
    ) async {
      final container = await _pumpApp(
        tester,
        size: _narrow,
        initialLocation: directChat,
      );
      _startCall(container);
      await _settle(tester);

      await tester.tap(find.byKey(_banner));
      await _settle(tester);
      expect(find.byType(VoiceCallPage), findsOneWidget);
      final router = GoRouter.of(tester.element(find.byType(VoiceCallPage)));
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/voice-rooms/$voiceRoomId/call',
      );
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('a draft in the composer stays when a call starts and when it '
        'ends', (tester) async {
      final container = await _pumpApp(
        tester,
        size: _narrow,
        initialLocation: directChat,
      );
      final field = find.descendant(
        of: find.byKey(const ValueKey('chat-composer-field')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, 'half a thought');
      await tester.pump();
      final editor = tester.state<EditableTextState>(field);
      expect(editor.widget.focusNode.hasFocus, isTrue);

      _startCall(container);
      await _settle(tester);
      expect(find.byKey(_banner), findsOneWidget);
      // The same editor, still focused: the page was kept, not rebuilt.
      expect(tester.state<EditableTextState>(field), same(editor));
      expect(editor.textEditingValue.text, 'half a thought');
      expect(editor.widget.focusNode.hasFocus, isTrue);

      _endCall(container);
      await _settle(tester);
      expect(find.byKey(_banner), findsNothing);
      expect(tester.state<EditableTextState>(field), same(editor));
      expect(editor.textEditingValue.text, 'half a thought');
      expect(editor.widget.focusNode.hasFocus, isTrue);
    });

    testWidgets('the banner of a muted call names its room and its '
        'microphone', (tester) async {
      final semantics = tester.ensureSemantics();
      final container = await _pumpApp(
        tester,
        size: _narrow,
        initialLocation: '/settings/security',
      );
      _startCall(container, muted: true);
      await _settle(tester);

      expect(
        tester.getSemantics(find.byKey(_banner)),
        isSemantics(
          label: 'Return to voice room: Weekly Sync, Muted',
          isButton: true,
        ),
      );
      semantics.dispose();
    });

    group('the banner offers a tap action that opens the call', () {
      for (final size in [_narrow, _wide]) {
        testWidgets('at ${size.width.round()} wide', (tester) async {
          final semantics = tester.ensureSemantics();
          final container = await _pumpApp(
            tester,
            size: size,
            initialLocation: directChat,
          );
          _startCall(container);
          await _settle(tester);

          const label = 'Return to voice room: Weekly Sync, Microphone on';
          expect(
            tester.getSemantics(find.byKey(_banner)),
            isSemantics(label: label, isButton: true, hasTapAction: true),
          );
          // One node announces the banner, and none the control under it.
          expect(
            find.semantics.byLabel(RegExp('Return to voice room')),
            findsOneWidget,
          );

          // By the node's action, as a service that does not touch the screen
          // does it, not by a tap at its centre.
          tester.semantics.tap(find.semantics.byLabel(label));
          await _settle(tester);
          expect(find.byType(VoiceCallPage), findsOneWidget);
          final router = GoRouter.of(
            tester.element(find.byType(VoiceCallPage)),
          );
          expect(
            router.routerDelegate.currentConfiguration.uri.path,
            '/voice-rooms/$voiceRoomId/call',
          );
          expect(find.byKey(_banner), findsNothing);
          semantics.dispose();
        });
      }
    });

    group('a service reaches the rail of a tab root, and the banner atop it '
        'opens the call', () {
      for (final size in [_medium, _wide]) {
        testWidgets('at ${size.width.round()} wide', (tester) async {
          final semantics = tester.ensureSemantics();
          final container = await _pumpApp(tester, size: size);
          _startCall(container);
          await _settle(tester);
          final shell = size == _medium ? 'shell-medium' : 'shell-wide';
          expect(find.byKey(ValueKey(shell)), findsOneWidget);

          // Painted before the tab root's navigator, whose route barrier
          // hides from a service whatever was painted before it, up to the
          // nearest semantics container.
          for (final name in [
            'Chats',
            'Voice Rooms',
            'Settings',
            'Start a conversation',
          ]) {
            expect(_button(name), findsOneWidget, reason: name);
          }
          const label = 'Return to voice room: Weekly Sync, Microphone on';
          expect(
            tester.getSemantics(find.byKey(_banner)),
            isSemantics(label: label, isButton: true, hasTapAction: true),
          );
          expect(
            find.semantics.byLabel(RegExp('Return to voice room')),
            findsOneWidget,
          );

          tester.semantics.tap(find.semantics.byLabel(label));
          await _settle(tester);
          expect(find.byType(VoiceCallPage), findsOneWidget);
          final router = GoRouter.of(
            tester.element(find.byType(VoiceCallPage)),
          );
          expect(
            router.routerDelegate.currentConfiguration.uri.path,
            '/voice-rooms/$voiceRoomId/call',
          );
          semantics.dispose();
        });
      }
    });

    group('at twice the text size, 360 by 800, nothing overflows', () {
      for (final location in [
        '/chats',
        directChat,
        '/voice-rooms/$voiceRoomId',
        '/settings/security',
      ]) {
        testWidgets(location, (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          fakeSystemInsets(tester);
          final container = await _pumpApp(
            tester,
            size: _narrow,
            initialLocation: location,
          );
          _startCall(container);
          await _settle(tester);

          final banner = tester.getRect(find.byKey(_banner));
          expect(banner.height, greaterThanOrEqualTo(AppFocus.minimumTarget));
          expect(banner.bottom, lessThan(_narrow.height));
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}

/// One banner on screen, and it is the shell's.
void _expectShellBanner(String shell) {
  expect(find.byKey(_banner), findsOneWidget);
  expect(
    find.descendant(
      of: find.byKey(ValueKey(shell)),
      matching: find.byKey(_banner),
    ),
    findsOneWidget,
  );
}

/// A call in the test room, told to the shell the way the call service tells
/// it: through the call's mirror, which every banner reads.
void _startCall(ProviderContainer container, {bool muted = false}) => container
    .read(voiceCallMirrorProvider.notifier)
    .follow(
      VoiceCallState(
        phase: VoiceCallPhase.inCall,
        roomId: voiceRoomId,
        muted: muted,
      ),
    );

void _endCall(ProviderContainer container) => container
    .read(voiceCallMirrorProvider.notifier)
    .follow(
      VoiceCallState(
        phase: VoiceCallPhase.ended,
        roomId: voiceRoomId,
        endReason: VoiceCallEndReason.left,
      ),
    );

void _expectDestinations(WidgetTester tester) {
  for (final label in ['Chats', 'Voice Rooms', 'Settings']) {
    expect(find.text(label).hitTestable(), findsWidgets, reason: label);
  }
}

/// The node of a control a service can activate: a button with a tap action
/// whose label is [name], said once.
SemanticsFinder _button(String name) => find.semantics.byPredicate(
  (node) {
    final data = node.getSemanticsData();
    return data.label == name &&
        data.flagsCollection.isButton &&
        data.hasAction(SemanticsAction.tap);
  },
  describeMatch: (plurality) => switch (plurality) {
    Plurality.one => '"$name" button with a tap action',
    Plurality.zero || Plurality.many => '"$name" buttons with a tap action',
  },
);

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
/// the pages under test draw are answered here. The call controller is never
/// built, so a test tells the shell of a call itself ([_startCall]).
Future<ProviderContainer> _pumpApp(
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
      // A verified peer, so a direct chat's composer takes text.
      contactProvider.overrideWith(
        (ref, userId) => Stream.value(
          ContactProjection(
            userId: userId,
            username: userId,
            trustState: ContactTrustState.verified,
          ),
        ),
      ),
      voiceRoomsProvider.overrideWith((ref) => Stream.value(const [])),
      // The test room, as its info page and the banner read it.
      voiceScopeProvider.overrideWith(
        (ref) => (userId: voiceSelf, deviceId: voiceSelfDevice),
      ),
      voiceRoomProvider.overrideWith(
        (ref, roomId) =>
            Stream.value(roomId == voiceRoomId ? voiceRoom() : null),
      ),
      roomUseCasesProvider.overrideWith(
        (ref) => Completer<RoomUseCases>().future,
      ),
      voiceCallControllerProvider.overrideWith(
        (ref, scope) => Completer<VoiceCallController>().future,
      ),
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
  return container;
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
