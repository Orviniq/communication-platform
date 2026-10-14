import 'dart:async';
import 'dart:math' as math;

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';

/// 65 characters, far wider than the bar at 360 px.
const _longName =
    'Neighbourhood chess club of the old harbour district, since 1998.';

/// What the top bar of a group chat promises: the whole bar between the back
/// button and Search opens Group Info, however short the name is.
void main() {
  group('the header spans the free part of the top bar', () {
    for (final (label, name) in [
      ('a short name', 'Team'),
      ('a 65-character name', _longName),
    ]) {
      testWidgets('for $label', (tester) async {
        await _pumpGroupChat(tester, name: name);

        final bar = _measure(tester, name);

        expect(
          (bar.header.left - bar.spanStart).abs(),
          lessThanOrEqualTo(4),
          reason: 'starts at the back button: $bar',
        );
        expect(
          (bar.header.right - bar.spanEnd).abs(),
          lessThanOrEqualTo(4),
          reason: 'ends at the Search button: $bar',
        );
        expect(
          bar.header.height,
          greaterThanOrEqualTo(56),
          reason: 'is as high as the bar: $bar',
        );
      });
    }
  });

  group('a tap anywhere on the header opens Group Info', () {
    testWidgets('at both ends, at the top and at the bottom of the bar', (
      tester,
    ) async {
      final router = await _pumpGroupChat(tester);

      await _tapEverywhere(tester, router, 'Team');
    });

    testWidgets('at 200 % text and in Persian, right to left', (tester) async {
      final router = await _pumpGroupChat(
        tester,
        locale: const Locale('fa'),
        textScaler: const TextScaler.linear(2),
      );

      expect(
        Directionality.of(tester.element(find.byType(Scaffold).last)),
        TextDirection.rtl,
      );
      await _tapEverywhere(tester, router, 'Team');
      expect(tester.takeException(), isNull);
    });

    testWidgets('with a name that does not fit, at 200 % text', (tester) async {
      final router = await _pumpGroupChat(
        tester,
        name: _longName,
        textScaler: const TextScaler.linear(2),
      );

      await _tapEverywhere(tester, router, _longName);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the top bar has no Info button, and keeps Search', (
    tester,
  ) async {
    await _pumpGroupChat(tester);

    final appBar = find.byType(AppBar);
    expect(
      find.descendant(
        of: appBar,
        matching: find.byWidgetPredicate(
          (widget) => widget is AppIconButton && widget.icon == AppIcons.info,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: appBar, matching: _searchButton),
      findsOneWidget,
    );
  });

  group('a screen reader', () {
    testWidgets('finds one Group Info control, which reads the name once', (
      tester,
    ) async {
      // Disposed in the body: the test binding checks for it before any
      // tear-down callback runs.
      final semantics = tester.ensureSemantics();
      await _pumpGroupChat(tester);
      final bar = tester.getRect(find.byType(AppBar));

      // A semantics finder counts a duplicate node, which a widget finder
      // does not see.
      final control = find.semantics.byPredicate(
        (node) => _inTopBar(node, bar) && node.label.contains('Team'),
        describeMatch: (plurality) => switch (plurality) {
          Plurality.one => 'node of the top bar that names the group',
          Plurality.zero ||
          Plurality.many => 'nodes of the top bar that name the group',
        },
      );
      expect(control, findsOneWidget);
      final node = control.evaluate().single;
      final data = node.getSemanticsData();

      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect('Team'.allMatches(data.label), hasLength(1));
      expect('3 members'.allMatches(data.label), hasLength(1));
      expect(data.hint, 'Group Info');

      // The tap lives on that node alone, and nothing else in the bar is
      // named Group Info: the avatar's label and the old Info button are
      // gone.
      expect(
        find.semantics.byPredicate(
          (node) =>
              _inTopBar(node, bar) &&
              node.getSemanticsData().hasAction(SemanticsAction.tap) &&
              (node.label.contains('Group Info') ||
                  node.hint.contains('Group Info')),
        ),
        findsOneWidget,
      );
      expect(
        find.semantics.byPredicate(
          (node) => _inTopBar(node, bar) && node.label.contains('Group Info'),
        ),
        findsNothing,
      );

      // The action is the node's own, not one it would have borrowed from
      // the `InkWell` under it.
      tester.semantics.tap(control);
      await tester.pumpAndSettle();
      expect(find.byKey(_infoStandIn), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('at a wide width the side panel stays and the header still opens '
      'Group Info', (tester) async {
    final router = await _pumpGroupChat(tester, size: const Size(1280, 900));

    expect(find.byType(GroupInfoSummary), findsOneWidget);
    final bar = _measure(tester, 'Team');
    expect(bar.header.left, closeTo(bar.spanStart, 4));
    expect(bar.header.right, closeTo(bar.spanEnd, 4));
    await tester.tapAt(bar.header.center);
    await tester.pumpAndSettle();
    expect(find.byKey(_infoStandIn), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(GroupInfoSummary), findsOneWidget);
  });
}

/// Whether [node] lies inside the top bar, so that the body's own nodes do
/// not count.
bool _inTopBar(SemanticsNode node, Rect bar) {
  // A node's rect is in its own space; each ancestor's transform carries it
  // one step up. The view's pixel ratio is 1, so the root adds no scale.
  var rect = node.rect;
  for (SemanticsNode? step = node; step != null; step = step.parent) {
    final transform = step.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
  }
  return bar.contains(rect.center);
}

/// Taps the header at 4 px inside each end of the free span, 3 px inside the
/// top and the bottom edge of the bar, and in the middle. Each tap must open
/// Group Info, and the bar must still be there to tap again after it closes.
Future<void> _tapEverywhere(
  WidgetTester tester,
  GoRouter router,
  String name,
) async {
  final bar = _measure(tester, name);
  final middle = bar.bar.center.dy;
  final points = {
    'the start of the free span': Offset(bar.spanStart + 4, middle),
    'the end of the free span': Offset(bar.spanEnd - 4, middle),
    'the top edge of the bar': Offset(bar.header.center.dx, bar.bar.top + 3),
    'the bottom edge of the bar': Offset(
      bar.header.center.dx,
      bar.bar.bottom - 3,
    ),
    'the middle of the bar': bar.bar.center,
  };
  for (final MapEntry(key: where, value: point) in points.entries) {
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(
      find.byKey(_infoStandIn),
      findsOneWidget,
      reason: 'a tap at $where, $point, in $bar',
    );
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-chat-screen')), findsOneWidget);
  }
}

const _infoStandIn = ValueKey('group-info-stand-in');

/// The rectangles that decide where a tap lands, in logical pixels.
class _Bar {
  const _Bar({
    required this.bar,
    required this.back,
    required this.search,
    required this.header,
  });

  final Rect bar;
  final Rect back;
  final Rect search;
  final Rect header;

  /// The free span runs from the back button to the Search button. The two
  /// buttons sit at opposite ends in either direction, so the nearer edge of
  /// each is the end of the span.
  double get spanStart => math.min(back.right, search.right);
  double get spanEnd => math.max(back.left, search.left);

  @override
  String toString() =>
      'bar $bar, back $back, search $search, header $header '
      '(free span $spanStart to $spanEnd)';
}

/// The header is the tap target around the group's name, found from the name
/// so that the measurement does not depend on how the header is built.
_Bar _measure(WidgetTester tester, String name) {
  final appBar = find.byType(AppBar);
  return _Bar(
    bar: tester.getRect(appBar),
    back: tester.getRect(find.byType(BackButton)),
    search: tester.getRect(
      find.descendant(of: appBar, matching: _searchButton),
    ),
    header: tester.getRect(
      find.ancestor(
        of: find.descendant(of: appBar, matching: find.text(name)),
        matching: find.byType(InkWell),
      ),
    ),
  );
}

final Finder _searchButton = find.byWidgetPredicate(
  (widget) => widget is AppIconButton && widget.icon == AppIcons.search,
);

/// The group chat as the application lays it out: pushed above a Chats
/// stand-in, so that its bar has a back button, with Group Info a stand-in
/// page of its own.
Future<GoRouter> _pumpGroupChat(
  WidgetTester tester, {
  String name = 'Team',
  Size size = const Size(360, 800),
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/chats',
    routes: [
      GoRoute(
        path: '/chats',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('Chats list'))),
      ),
      GoRoute(
        path: '/groups/:groupId',
        builder: (context, state) => GroupChatPage(
          groupId: _groupId,
          injectedState: _state(name),
          injectedMessages: const [],
          currentUserId: _owner,
          onSend: (_) async => const Result.success(null),
        ),
        routes: [
          GoRoute(
            path: 'info',
            builder: (context, state) => Scaffold(
              body: Center(child: Text('Info', key: _infoStandIn)),
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
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppDesignSystem(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push('/groups/$_groupId'));
  await tester.pumpAndSettle();
  expect(find.byType(BackButton), findsOneWidget);
  return router;
}

GroupState _state(String name) => GroupState(
  groupId: _groupId,
  metadata: GroupMetadata(name: name, description: 'Encrypted metadata'),
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
    GroupMember(userId: _member, displayName: 'Member', role: GroupRole.member),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
  lifecycle: GroupLifecycle.active,
);
