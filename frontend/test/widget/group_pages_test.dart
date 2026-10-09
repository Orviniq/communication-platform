import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/create_group_page.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/system_insets.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';

void main() {
  testWidgets('create flow remains usable at narrow RTL and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      CreateGroupPage(
        injectedContacts: const [
          GroupPickerContact(userId: _member, name: 'مریم', verified: true),
        ],
        onCreate: (_, _) async => Result.success(_state()),
      ),
      locale: const Locale('fa'),
      textScaler: const TextScaler.linear(2),
    );

    expect(
      Directionality.of(tester.element(find.byType(Scaffold))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
    final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(memberPicker);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
    await tester.tap(find.byKey(const ValueKey('group-next')));
    await tester.pumpAndSettle();

    expect(find.text('مشخصات گروه'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-name-field')), findsOneWidget);
    // At this width and text size the cost notice pushes Create below the
    // fold; usable means it is still reachable.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('group-create')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('group-fanout-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-create')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin sees removal but never owner-only role actions', (
    tester,
  ) async {
    await _pump(
      tester,
      GroupInfoPage(
        groupId: _groupId,
        injectedState: _state(),
        currentUserId: _admin,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    final memberRow = find.byKey(const ValueKey('group-member-$_member'));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(memberRow);
    await tester.pumpAndSettle();
    expect(find.text('Remove from group'), findsOneWidget);
    expect(find.text('Make admin'), findsNothing);
    expect(find.text('Transfer ownership'), findsNothing);
  });

  // The rule is written once, in `app_modals.dart`, and proved on the two
  // sheet functions in `sheet_insets_test.dart`. The owner's view of a member
  // is the longest this sheet gets: four buttons.
  testWidgets("the owner's member sheet keeps its last button above the "
      'gesture bar', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    fakeSystemInsets(tester);
    await _pump(
      tester,
      GroupInfoPage(
        groupId: _groupId,
        injectedState: _state(),
        currentUserId: _owner,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-member-$_member')));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('app-sheet-surface'));
    expect(tester.getRect(surface).bottom, 800);
    expect(
      tester
          .getRect(find.widgetWithText(AppButton, 'Transfer ownership'))
          .bottom,
      closeTo(800 - 48 - 24, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed group stays readable while composer is withheld', (
    tester,
  ) async {
    final removed = _state(lifecycle: GroupLifecycle.removed);
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: removed,
        injectedMessages: const [
          GroupMessage(
            messageId: '11111111111111111111111111111111',
            groupId: _groupId,
            senderUserId: _owner,
            text: 'Past message remains readable',
            createdMs: 100,
            delivery: GroupMessageDelivery.received,
          ),
        ],
        currentUserId: _member,
        onSend: (_) async => throw StateError('composer must be disabled'),
      ),
    );

    expect(find.text('Past message remains readable'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer-field')), findsNothing);
    expect(find.textContaining('read-only'), findsWidgets);
  });

  testWidgets('wide group chat exposes a bounded information panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_) async => const Result.success(null),
      ),
    );

    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(find.text('Private Team'), findsWidgets);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending a group message leaves the composer, its focus and the '
      'keyboard where they were', (tester) async {
    // The send is held open on purpose. The composer used to be swapped for a
    // progress bar for as long as `onSend` took, and a text field that leaves
    // the tree takes the keyboard with it.
    final finished = Completer<Result<void>>();
    final sent = <String>[];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (text) {
          sent.add(text);
          return finished.future;
        },
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'Keep typing');
    await tester.pump();
    final focus = tester.widget<TextField>(field).focusNode!;
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(_sendButton);
    await tester.pump();

    expect(sent, ['Keep typing']);
    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    finished.complete(const Result.success(null));
    await tester.pumpAndSettle();

    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('a group send that is refused says so and keeps the composer', (
    tester,
  ) async {
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_) async => const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'Not allowed');
    await tester.pump();
    await tester.tap(_sendButton);
    await tester.pumpAndSettle();

    expect(
      find.text('The message was not saved. Nothing was sent.'),
      findsOneWidget,
    );
    expect(find.byType(ChatComposerBuilder), findsOneWidget);
  });

  testWidgets('a send that succeeds does not hide an earlier one that failed', (
    tester,
  ) async {
    // Two sends can now be in flight at once, because the composer stays. The
    // one that ends last must not decide whether the failure of the other is
    // still on screen.
    final first = Completer<Result<void>>();
    final second = Completer<Result<void>>();
    final answers = [first, second];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_) => answers.removeAt(0).future,
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    for (final text in ['First', 'Second']) {
      await tester.enterText(field, text);
      await tester.pump();
      await tester.tap(_sendButton);
      await tester.pump();
    }

    first.complete(
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked)),
    );
    await tester.pump();
    second.complete(const Result.success(null));
    await tester.pumpAndSettle();

    expect(
      find.text('The message was not saved. Nothing was sent.'),
      findsOneWidget,
    );
  });

  testWidgets('a group message is not accepted before its last copy, and its '
      'bubble keeps its width until then', (tester) async {
    const messageId = '22222222222222222222222222222222';
    // A word short enough that the row under it, the time and the mark, is
    // what sizes the bubble. Anything added to that row while the message is
    // on its way shows as a wider bubble that narrows again once it is sent.
    Future<double> bubbleWidth(GroupMessageDelivery delivery) async {
      await _pump(
        tester,
        GroupChatPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMessages: [
            GroupMessage(
              messageId: messageId,
              groupId: _groupId,
              senderUserId: _owner,
              text: 'Hi',
              createdMs: 100,
              delivery: delivery,
            ),
          ],
          currentUserId: _owner,
          onSend: (_) async => const Result.success(null),
        ),
      );
      return tester
          .getSize(find.byKey(const ValueKey('message-$messageId')))
          .width;
    }

    final queued = await bubbleWidth(GroupMessageDelivery.queued);
    expect(find.byTooltip('queued offline'), findsOneWidget);

    final sending = await bubbleWidth(GroupMessageDelivery.sending);
    expect(find.byTooltip('sending to server'), findsOneWidget);
    expect(find.byTooltip('accepted by server relay'), findsNothing);

    final sent = await bubbleWidth(GroupMessageDelivery.sent);
    expect(find.byTooltip('accepted by server relay'), findsOneWidget);

    expect(queued, sent);
    expect(sending, sent);
  });

  testWidgets('a failed group send retries that same message', (tester) async {
    const messageId = '33333333333333333333333333333333';
    final retried = <String>[];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [
          GroupMessage(
            messageId: messageId,
            groupId: _groupId,
            senderUserId: _owner,
            text: 'Not everyone has this yet',
            createdMs: 100,
            delivery: GroupMessageDelivery.failed,
          ),
        ],
        currentUserId: _owner,
        onSend: (_) async => const Result.success(null),
        onRetry: (message) async {
          retried.add(message.messageId);
          return const Result.success(null);
        },
      ),
    );

    await tester.tap(find.text('Retry as a new encrypted send'));
    // The bubble's double-tap recognizer holds the arena before a tap wins.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(retried, [messageId]);
  });

  testWidgets('group details say what one message costs', (tester) async {
    await _pump(
      tester,
      CreateGroupPage(
        injectedContacts: const [
          GroupPickerContact(userId: _member, name: 'Member', verified: true),
        ],
        onCreate: (_, _) async => Result.success(_state()),
      ),
    );
    final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
    await tester.ensureVisible(memberPicker);
    await tester.tap(memberPicker);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
    await tester.tap(find.byKey(const ValueKey('group-next')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-fanout-notice')), findsOneWidget);
    expect(find.textContaining('about 150 copies'), findsOneWidget);
  });

  group('back from a group never leaves the application', () {
    testWidgets('a new group opens above the Chats list, and back returns to '
        'the list', (tester) async {
      final router = await _pumpGroupRoutes(tester, '/chats/new');
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();

      final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
      await tester.ensureVisible(memberPicker);
      await tester.tap(memberPicker);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
      await tester.tap(find.byKey(const ValueKey('group-next')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('group-name-field')),
          matching: find.byType(EditableText),
        ),
        'Private Team',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('group-create')));
      await tester.tap(find.byKey(const ValueKey('group-create')));
      await tester.pumpAndSettle();
      expect(find.text('Group chat $_groupId'), findsOneWidget);

      // Nothing of the steps that made it is left between the chat and the
      // list.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Chats list'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });

    testWidgets('Search on Group Info returns to the conversation below it', (
      tester,
    ) async {
      final router = await _pumpGroupRoutes(tester, '/chats');
      unawaited(router.push('/groups/$_groupId'));
      await tester.pumpAndSettle();
      unawaited(router.push('/groups/$_groupId/info'));
      await tester.pumpAndSettle();

      final search = find.byKey(const ValueKey('group-info-search'));
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(find.text('Group chat $_groupId'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Chats list'), findsOneWidget);
    });
  });
}

/// The routes around a group as the application lays them out: the Chats
/// list in a shell branch with New above it on the root navigator, and the
/// group routes outside the shell.
Future<GoRouter> _pumpGroupRoutes(
  WidgetTester tester,
  String initialLocation,
) async {
  final root = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: root,
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chats',
                builder: (context, state) =>
                    const Scaffold(body: Center(child: Text('Chats list'))),
                routes: [
                  GoRoute(
                    path: 'new',
                    parentNavigatorKey: root,
                    builder: (context, state) => Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () => context.push('/groups/new'),
                          child: const Text('New group'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/groups/new',
        builder: (context, state) => CreateGroupPage(
          injectedContacts: const [
            GroupPickerContact(userId: _member, name: 'Member', verified: true),
          ],
          onCreate: (_, _) async => Result.success(_state()),
        ),
      ),
      GoRoute(
        path: '/groups/:groupId',
        builder: (context, state) => Scaffold(
          body: Center(
            child: Text('Group chat ${state.pathParameters['groupId']}'),
          ),
        ),
        routes: [
          GoRoute(
            path: 'info',
            builder: (context, state) => GroupInfoPage(
              groupId: _groupId,
              injectedState: _state(),
              currentUserId: _owner,
              onMutate: (_) async => Result.success(_state()),
            ),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

GroupState _state({GroupLifecycle lifecycle = GroupLifecycle.active}) =>
    GroupState(
      groupId: _groupId,
      metadata: const GroupMetadata(
        name: 'Private Team',
        description: 'Encrypted metadata',
      ),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
      members: [
        GroupMember(
          userId: _owner,
          displayName: 'Owner',
          role: GroupRole.owner,
          verified: true,
        ),
        GroupMember(
          userId: _admin,
          displayName: 'Admin',
          role: GroupRole.admin,
          verified: true,
        ),
        GroupMember(
          userId: _member,
          displayName: 'Member',
          role: GroupRole.member,
          membership: lifecycle == GroupLifecycle.removed
              ? GroupMembershipState.removed
              : GroupMembershipState.active,
        ),
      ],
      controlRevision: 1,
      controlStateHash:
          '1010101010101010101010101010101010101010101010101010101010101010',
      lifecycle: lifecycle,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  AppEnvironment environment = AppEnvironment.development,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appEnvironmentProvider.overrideWithValue(environment)],
      child: MaterialApp(
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, appChild) => AppDesignSystem(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: appChild ?? const SizedBox.shrink(),
          ),
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Send, once the composer holds a draft to send.
final Finder _sendButton = find.byWidgetPredicate(
  (widget) =>
      widget is AppIconButton &&
      widget.icon == AppIcons.send &&
      widget.onPressed != null,
);
