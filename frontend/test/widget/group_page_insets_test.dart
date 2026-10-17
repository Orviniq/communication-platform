import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/add_group_members_page.dart';
import 'package:communication_platform/features/groups/presentation/create_group_page.dart';
import 'package:communication_platform/features/groups/presentation/edit_group_page.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/authentication_harness.dart' as auth;
import '../support/system_insets.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = auth.userId;
const _member = '00000000-0000-0000-0000-000000000003';
const _deviceId = 'device-01';

// A phone short enough that every page below has to scroll, and a gesture bar
// as tall as the fake insets make it.
const _height = 500.0;
const _gestureBar = 48.0;

/// The group pages are full-screen routes outside the shell. A list given a
/// fixed padding does not add the bottom system inset, so its last item came to
/// rest under the gesture bar; each page now takes its padding from
/// `AppInsets.belowAppBar`, which does.
void main() {
  testWidgets('Group Info keeps Leave group above the gesture bar', (
    tester,
  ) async {
    _phone(tester);
    await _pumpPlain(
      tester,
      GroupInfoPage(
        groupId: _groupId,
        injectedState: _state(),
        currentUserId: _owner,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    await _scrollToEnd(tester);

    _expectLastItemAboveGestureBar(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Create Group keeps its last control above the gesture bar', (
    tester,
  ) async {
    _phone(tester);
    await _pumpPlain(
      tester,
      CreateGroupPage(
        injectedContacts: [
          for (var index = 0; index < 8; index += 1)
            GroupPickerContact(
              userId: '10000000-0000-0000-0000-00000000000$index',
              name: 'Contact $index',
              verified: true,
            ),
        ],
        onCreate: (_, _) async => Result.success(_state()),
      ),
    );

    await _scrollToEnd(tester);

    _expectLastItemAboveGestureBar(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Edit Group keeps its last control above the gesture bar', (
    tester,
  ) async {
    _phone(tester);
    await _pumpPlain(
      tester,
      GroupEditView(
        state: _state(),
        currentUserId: _owner,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    await _scrollToEnd(tester);

    _expectLastItemAboveGestureBar(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add Members keeps its button above the gesture bar', (
    tester,
  ) async {
    _phone(tester);
    final harness = auth.AuthenticationHarness();
    addTearDown(harness.close);
    final repository = _GroupRepository({_groupId: _state()});
    final container = ProviderContainer(
      overrides: [
        authenticationUseCasesProvider.overrideWithValue(harness.useCases),
        currentMessagingDeviceIdProvider.overrideWith(
          (ref) => Future.value(_deviceId),
        ),
        groupProvider.overrideWith((ref, id) => Stream.value(_state())),
        contactListProvider.overrideWith(
          (ref, userId) => Stream.value([
            for (var index = 0; index < 8; index += 1)
              ContactProjection(
                userId: '10000000-0000-0000-0000-00000000000$index',
                username: 'contact$index',
                trustState: ContactTrustState.verified,
              ),
          ]),
        ),
        groupUseCasesProvider.overrideWith(
          (ref) => GroupUseCases(
            create: CreateGroup(
              repository: repository,
              crypto: const _UnusedCrypto(),
              identity: const _UnusedIdentity(),
              clock: const _Clock(),
            ),
            mutate: MutateGroup(
              repository: repository,
              crypto: const _UnusedCrypto(),
              identity: const _UnusedIdentity(),
              clock: const _Clock(),
            ),
            sendMessage: SendGroupMessage(
              repository: repository,
              sender: _UnusedSender(),
            ),
            retryMessage: RetryGroupMessage(
              repository: repository,
              sender: _UnusedSender(),
            ),
            setReaction: SetGroupReaction(
              repository: repository,
              sender: _UnusedSender(),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(
      await container
          .read(authenticationControllerProvider.notifier)
          .login(username: 'reader', password: 'correct horse battery'),
      isTrue,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(const AddGroupMembersPage(groupId: _groupId)),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToEnd(tester);

    _expectLastItemAboveGestureBar(tester);
    expect(tester.takeException(), isNull);
  });
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, _height);
  addTearDown(tester.view.resetPhysicalSize);
  fakeSystemInsets(tester, bottom: _gestureBar);
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
  await tester.pumpAndSettle();
}

/// The last item the page lays out is fully above the gesture bar.
///
/// Read from the list itself rather than from a named control, so that a page
/// which grows a notice or a button under the one a test knew about still has
/// its true last item measured.
void _expectLastItemAboveGestureBar(WidgetTester tester) {
  final list = tester.renderObject<RenderSliverMultiBoxAdaptor>(
    find.byType(SliverList).first,
  );
  final last = list.lastChild!;
  final bottom = last.localToGlobal(Offset(0, last.size.height)).dy;
  expect(bottom, lessThanOrEqualTo(_height - _gestureBar));
}

Future<void> _pumpPlain(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
      ],
      child: _app(page),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app(Widget page) => MaterialApp(
  theme: AppTheme.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  builder: (context, child) =>
      AppDesignSystem(child: child ?? const SizedBox.shrink()),
  home: page,
);

GroupState _state() => GroupState(
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
    GroupMember(userId: _member, displayName: 'Member', role: GroupRole.member),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
);

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
}

final class _GroupRepository implements GroupRepositoryPort {
  _GroupRepository(this.groups);

  final Map<String, GroupState> groups;

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedCrypto implements GroupControlCryptoPort {
  const _UnusedCrypto();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedIdentity implements GroupIdentityPort {
  const _UnusedIdentity();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedSender implements GroupMessageSenderPort {
  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}
