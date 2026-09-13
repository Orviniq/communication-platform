import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
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
            localPreviewOnly: true,
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
        onSend: (_) async => Result.success(
          const GroupMessage(
            messageId: '22222222222222222222222222222222',
            groupId: _groupId,
            senderUserId: _owner,
            text: 'hello',
            createdMs: 100,
            localPreviewOnly: true,
          ),
        ),
      ),
    );

    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(find.text('Private Team'), findsWidgets);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(tester.takeException(), isNull);
  });
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
      acceptedEpoch: 1,
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
