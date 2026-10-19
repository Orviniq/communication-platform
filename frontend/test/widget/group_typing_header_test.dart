import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/messaging/infrastructure/memory_volatile_conversation_state.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _me = '00000000-0000-0000-0000-000000000001';
const _alice = '00000000-0000-0000-0000-000000000002';
const _bob = '00000000-0000-0000-0000-000000000003';
const _carol = '00000000-0000-0000-0000-000000000004';
const _dan = '00000000-0000-0000-0000-000000000005';

/// ADR-098 D3 and D11: a group's header names the members who type, by the
/// name the group gives their messages, and goes back to the member count
/// when they stop or their typing expires.
void main() {
  late _Clock clock;
  late MemoryVolatileConversationState typing;

  setUp(() {
    clock = _Clock();
    typing = MemoryVolatileConversationState(clock: clock);
  });

  tearDown(() => typing.dispose());

  void types(String userId, {bool active = true, String? deviceId}) =>
      typing.applyTyping(
        conversationId: _groupId,
        userId: userId,
        deviceId: deviceId ?? 'device-of-$userId',
        isTyping: active,
        expiresAt: clock.now().add(const Duration(seconds: 15)),
        authenticatedAt: clock.now(),
      );

  /// The typing state's stream, the provider and the frame after them.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
  }

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
          timeSourceProvider.overrideWithValue(clock),
          volatileConversationStateProvider.overrideWithValue(typing),
        ],
        child: MaterialApp(
          locale: locale,
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppDesignSystem(child: child ?? const SizedBox.shrink()),
          home: GroupChatPage(
            groupId: _groupId,
            injectedState: _state(),
            injectedMessages: const [],
            injectedTyping: typing.watchTyping(_groupId),
            currentUserId: _me,
            injectedMemberNames: GroupMemberNames({
              _alice: const GroupMemberName(name: 'Alice', verified: true),
              _bob: const GroupMemberName(name: 'Bob', verified: true),
              _carol: const GroupMemberName(name: 'Carol', verified: true),
            }),
            onSend: (_, {replyToMessageId, quoteFallback}) async =>
                const Result.success(null),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder inBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  testWidgets('one, two and three members typing, then the member count', (
    tester,
  ) async {
    await pump(tester);
    expect(inBar('5 members'), findsOneWidget);

    types(_alice);
    await settle(tester);
    expect(inBar('Alice is typing…'), findsOneWidget);
    expect(inBar('5 members'), findsNothing);

    types(_bob);
    await settle(tester);
    expect(inBar('Alice and Bob are typing…'), findsOneWidget);

    types(_carol);
    types(_dan);
    await settle(tester);
    expect(
      inBar('Alice and 3 others are typing…'),
      findsOneWidget,
      reason: 'Dan has no name here, and is counted all the same',
    );

    for (final user in [_alice, _bob, _carol, _dan]) {
      types(user, active: false);
    }
    await settle(tester);
    expect(inBar('5 members'), findsOneWidget);
    // In the body: the binding checks for a pending expiry timer before
    // any tear-down runs.
    typing.dispose();
  });

  testWidgets('one member typing on two devices is one name', (tester) async {
    await pump(tester);
    types(_alice, deviceId: 'phone');
    types(_alice, deviceId: 'tablet');
    await settle(tester);

    expect(inBar('Alice is typing…'), findsOneWidget);
    // In the body: the binding checks for a pending expiry timer before
    // any tear-down runs.
    typing.dispose();
  });

  testWidgets('this account typing on another device is nobody', (
    tester,
  ) async {
    await pump(tester);
    types(_me);
    await settle(tester);

    expect(inBar('5 members'), findsOneWidget);
    // In the body: the binding checks for a pending expiry timer before
    // any tear-down runs.
    typing.dispose();
  });

  testWidgets('the line clears when the typing expires', (tester) async {
    await pump(tester);
    types(_alice);
    await settle(tester);
    expect(inBar('Alice is typing…'), findsOneWidget);

    clock.advance(const Duration(seconds: 14));
    await tester.pump(const Duration(seconds: 14));
    expect(inBar('Alice is typing…'), findsOneWidget);

    clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(inBar('Alice is typing…'), findsNothing);
    expect(inBar('5 members'), findsOneWidget);
    // In the body: the binding checks for a pending expiry timer before
    // any tear-down runs.
    typing.dispose();
  });

  testWidgets('in Persian', (tester) async {
    await pump(tester, locale: const Locale('fa'));
    types(_alice);
    types(_bob);
    await settle(tester);

    expect(inBar('Alice و Bob در حال نوشتن هستند…'), findsOneWidget);
    typing.dispose();
  });
}

final class _Clock implements TimeSource {
  DateTime _now = DateTime.utc(2026, 10, 19, 12);

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

GroupState _state() => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Team', description: ''),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
  members: [
    for (final (userId, role) in [
      (_me, GroupRole.owner),
      (_alice, GroupRole.member),
      (_bob, GroupRole.member),
      (_carol, GroupRole.member),
      (_dan, GroupRole.member),
    ])
      GroupMember(userId: userId, displayName: '', role: role, verified: true),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
  lifecycle: GroupLifecycle.active,
);
