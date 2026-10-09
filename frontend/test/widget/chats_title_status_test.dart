import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/authentication_harness.dart';

const _narrow = Size(360, 800);

final _title = find.byKey(const ValueKey('chats-title'));
final _list = find.byKey(const PageStorageKey<String>('chats-list'));
final _spinner = find.byType(CircularProgressIndicator);
final _stillGlyph = find.byWidgetPredicate(
  (widget) => widget is AppIcon && widget.data == AppIcons.connecting,
);

const _waiting = 'Waiting to reconnect…';

/// The nine phases of the engine and the words the title shows for each. A
/// tenth phase has to be decided here as well as in the mapping.
const _words = <SyncConnectionPhase, String>{
  SyncConnectionPhase.stopped: _waiting,
  SyncConnectionPhase.offline: _waiting,
  SyncConnectionPhase.connecting: 'Connecting…',
  SyncConnectionPhase.draining: 'Syncing…',
  SyncConnectionPhase.online: 'Chats',
  SyncConnectionPhase.reconnectWaiting: _waiting,
  SyncConnectionPhase.revoked: _waiting,
  SyncConnectionPhase.protocolCircuitOpen: _waiting,
  SyncConnectionPhase.originRejected: _waiting,
};

void main() {
  test('every phase of the engine has its words in this table', () {
    expect(_words.keys, unorderedEquals(SyncConnectionPhase.values));
  });

  testWidgets('a settled phase shows "Chats", and so does a session that has '
      'heard nothing from the engine', (tester) async {
    final engine = await _pumpApp(tester);
    expect(_label(tester), 'Chats');

    // No projection yet: nothing to say, however long it takes.
    await tester.pump(const Duration(seconds: 5));
    expect(_label(tester), 'Chats');

    await engine.enter(tester, SyncConnectionPhase.online);
    await tester.pump(const Duration(seconds: 5));
    expect(_label(tester), 'Chats');
  });

  testWidgets('a syncing phase that lasts 500 ms leaves "Chats" on the title', (
    tester,
  ) async {
    final engine = await _pumpApp(tester);

    await engine.enter(tester, SyncConnectionPhase.draining);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_label(tester), 'Chats');

    await engine.enter(tester, SyncConnectionPhase.online);
    // The clock the cycle started is gone with it.
    await tester.pump(const Duration(seconds: 2));
    expect(_label(tester), 'Chats');
  });

  testWidgets('a connecting phase that lasts one second shows "Connecting…", '
      'and not a moment before', (tester) async {
    final engine = await _pumpApp(tester);

    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(milliseconds: 999));
    expect(_label(tester), 'Chats');

    await tester.pump(const Duration(milliseconds: 1));
    expect(_label(tester), 'Connecting…');
  });

  group('each state that is not settled shows its words', () {
    for (final MapEntry(key: phase, value: words) in _words.entries) {
      testWidgets('${phase.name}: $words', (tester) async {
        final engine = await _pumpApp(tester);

        await engine.enter(tester, phase);
        await tester.pump(const Duration(seconds: 1));
        expect(_label(tester), words);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('a settled phase shows "Chats" again at once', (tester) async {
    final engine = await _pumpApp(tester);

    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(seconds: 1));
    expect(_label(tester), 'Connecting…');

    // One frame, no time passing.
    await engine.enter(tester, SyncConnectionPhase.online);
    expect(_label(tester), 'Chats');
    expect(_spinner, findsNothing);
  });

  testWidgets(
    'a change between two states that are not settled shows at once',
    (tester) async {
      final engine = await _pumpApp(tester);

      await engine.enter(tester, SyncConnectionPhase.connecting);
      await tester.pump(const Duration(seconds: 1));
      expect(_label(tester), 'Connecting…');

      await engine.enter(tester, SyncConnectionPhase.draining);
      expect(_label(tester), 'Syncing…');
      await engine.enter(tester, SyncConnectionPhase.offline);
      expect(_label(tester), _waiting);
      await engine.enter(tester, SyncConnectionPhase.connecting);
      expect(_label(tester), 'Connecting…');
    },
  );

  testWidgets('the second runs from the moment the engine stopped being '
      'settled, and a change to another state does not start it again', (
    tester,
  ) async {
    final engine = await _pumpApp(tester);

    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(milliseconds: 600));
    await engine.enter(tester, SyncConnectionPhase.draining);
    expect(_label(tester), 'Chats');

    await tester.pump(const Duration(milliseconds: 399));
    expect(_label(tester), 'Chats');
    await tester.pump(const Duration(milliseconds: 1));
    expect(_label(tester), 'Syncing…');
  });

  testWidgets('a settled moment in between starts the second again, whether or '
      'not the title had left its name', (tester) async {
    final engine = await _pumpApp(tester);

    // Before the second was up.
    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(milliseconds: 900));
    await engine.enter(tester, SyncConnectionPhase.online);
    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(milliseconds: 900));
    expect(_label(tester), 'Chats');
    await tester.pump(const Duration(milliseconds: 100));
    expect(_label(tester), 'Connecting…');

    // After it: the title is its name again, and the next state waits too.
    await engine.enter(tester, SyncConnectionPhase.online);
    expect(_label(tester), 'Chats');
    await engine.enter(tester, SyncConnectionPhase.draining);
    expect(_label(tester), 'Chats');
    await tester.pump(const Duration(milliseconds: 999));
    expect(_label(tester), 'Chats');
    await tester.pump(const Duration(milliseconds: 1));
    expect(_label(tester), 'Syncing…');
  });

  testWidgets('the second runs while a page covers the list', (tester) async {
    final engine = await _pumpApp(tester);

    // The page opens first and the engine stops settling under it: a covered
    // page hears of it only through a subscription that Riverpod does not
    // pause.
    await tester.tap(find.byKey(const ValueKey('chats-search-action')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('chats-search-field')), findsOneWidget);
    await engine.enter(tester, SyncConnectionPhase.connecting);
    await tester.pump(const Duration(milliseconds: 1200));

    // Back to a list that has been unsettled for longer than a second: the
    // title says so as it comes back, and does not count the second again.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('chats-search-field')), findsNothing);
    expect(_label(tester), 'Connecting…');
  });

  group('the indicator before the words', () {
    testWidgets('a spinner stands before "Connecting…" and "Syncing…", and '
        'nothing before the others', (tester) async {
      final engine = await _pumpApp(tester);
      expect(_spinner, findsNothing);
      expect(_stillGlyph, findsNothing);

      await engine.enter(tester, SyncConnectionPhase.connecting);
      await tester.pump(const Duration(seconds: 1));
      expect(_spinner, findsOneWidget);
      expect(_stillGlyph, findsNothing);
      expect(
        tester.getRect(_spinner).right,
        lessThanOrEqualTo(tester.getRect(_titleWords('Connecting…')).left),
        reason: 'before the words',
      );
      expect(
        find.descendant(of: _title, matching: _spinner),
        findsOneWidget,
        reason: 'in the title',
      );

      await engine.enter(tester, SyncConnectionPhase.draining);
      expect(_label(tester), 'Syncing…');
      expect(_spinner, findsOneWidget);

      await engine.enter(tester, SyncConnectionPhase.offline);
      expect(_label(tester), _waiting);
      expect(_spinner, findsNothing);
      expect(_stillGlyph, findsNothing);
    });

    testWidgets('with animations off the still icon stands in its place, and '
        'nothing animates', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final engine = await _pumpApp(tester);

      await engine.enter(tester, SyncConnectionPhase.connecting);
      await tester.pump(const Duration(seconds: 1));
      expect(_label(tester), 'Connecting…');
      expect(_spinner, findsNothing);
      expect(_stillGlyph, findsOneWidget);
      expect(
        find.descendant(of: _title, matching: _stillGlyph),
        findsOneWidget,
      );
      // A running animation would never let this finish.
      await tester.pumpAndSettle();

      await engine.enter(tester, SyncConnectionPhase.draining);
      expect(_label(tester), 'Syncing…');
      expect(_spinner, findsNothing);
      expect(_stillGlyph, findsOneWidget);
      await tester.pumpAndSettle();

      await engine.enter(tester, SyncConnectionPhase.offline);
      expect(_stillGlyph, findsNothing);
      await tester.pumpAndSettle();
    });
  });

  group('the body of the page holds the list and nothing above it', () {
    for (final offline in const [false, true]) {
      testWidgets(
        offline ? 'in a session that opened offline' : 'in an online session',
        (tester) async {
          final engine = await _pumpApp(
            tester,
            summaries: _summaries(),
            offline: offline,
          );
          final access = ProviderScope.containerOf(
            tester.element(_title),
          ).read(authenticationControllerProvider).access;
          expect(
            access,
            offline
                ? AuthenticationRouteAccess.offlineFullScope
                : AuthenticationRouteAccess.fullScope,
          );

          // The list starts where the app bar ends, with nothing between.
          final top = tester.getTopLeft(_list).dy;
          expect(top, tester.getBottomLeft(find.byType(AppBar)).dy);
          expect(find.text('Weekend plans'), findsOneWidget);
          expect(find.textContaining('Offline'), findsNothing);
          expect(find.textContaining('queue'), findsNothing);

          // The status comes up in the title and moves nothing.
          await engine.enter(tester, SyncConnectionPhase.connecting);
          await tester.pump(const Duration(seconds: 1));
          expect(_label(tester), 'Connecting…');
          expect(find.text('Connecting…'), findsOneWidget);
          expect(tester.getTopLeft(_list).dy, top);
          expect(find.text('Weekend plans'), findsOneWidget);

          // And leaves again with the connection, whatever the session
          // opened as.
          await engine.enter(tester, SyncConnectionPhase.online);
          expect(_label(tester), 'Chats');
          expect(find.textContaining('Offline'), findsNothing);
          expect(tester.getTopLeft(_list).dy, top);
        },
      );
    }
  });

  group('the title for a screen reader', () {
    testWidgets('is a header in every state, and only the status is a live '
        'region', (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = await _pumpApp(tester);

      SemanticsNode node() => tester.getSemantics(_title);
      expect(
        node(),
        isSemantics(label: 'Chats', isHeader: true, isLiveRegion: false),
      );
      final id = node().id;

      for (final (phase, words) in const [
        (SyncConnectionPhase.connecting, 'Connecting…'),
        (SyncConnectionPhase.draining, 'Syncing…'),
        (SyncConnectionPhase.offline, _waiting),
      ]) {
        await engine.enter(tester, phase);
        await tester.pump(const Duration(seconds: 1));
        expect(
          node(),
          isSemantics(label: words, isHeader: true, isLiveRegion: true),
          reason: words,
        );
        // One node says it, and it is the node that said "Chats".
        expect(find.semantics.byLabel(words), findsOneWidget, reason: words);
        expect(node().id, id, reason: words);
      }

      await engine.enter(tester, SyncConnectionPhase.online);
      expect(
        node(),
        isSemantics(label: 'Chats', isHeader: true, isLiveRegion: false),
      );
      expect(node().id, id);
      expect(
        find.semantics.byLabel(RegExp('Connecting|Syncing')),
        findsNothing,
      );
      semantics.dispose();
    });

    testWidgets('keeps its node and its words when the page rebuilds, so a '
        'rebuild is not announced again', (tester) async {
      final semantics = tester.ensureSemantics();
      final engine = await _pumpApp(tester, summaries: _summaries());
      final settled = tester.getSemantics(_title).id;
      for (var frame = 0; frame < 3; frame += 1) {
        tester.element(_title).markNeedsBuild();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getSemantics(_title).id, settled);
        expect(tester.getSemantics(_title).label, 'Chats');
      }

      await engine.enter(tester, SyncConnectionPhase.connecting);
      await tester.pump(const Duration(seconds: 1));
      final status = tester.getSemantics(_title);
      expect(status.id, settled);
      for (var frame = 0; frame < 3; frame += 1) {
        tester.element(_title).markNeedsBuild();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getSemantics(_title).id, status.id);
        // The spinner adds no words of its own.
        expect(tester.getSemantics(_title).label, 'Connecting…');
      }
      semantics.dispose();
    });
  });

  group('at twice the text size, 360 by 800, nothing overflows', () {
    for (final locale in const [Locale('en'), Locale('fa')]) {
      testWidgets(locale.languageCode, (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final strings = lookupAppLocalizations(locale);
        final engine = await _pumpApp(
          tester,
          summaries: _summaries(),
          locale: locale,
        );
        final rtl = locale.languageCode == 'fa';
        expect(
          Directionality.of(tester.element(_title)),
          rtl ? TextDirection.rtl : TextDirection.ltr,
        );

        for (final (phase, words) in [
          (SyncConnectionPhase.online, strings.chatsTitle),
          (
            SyncConnectionPhase.connecting,
            strings.chatsDeliveryConnectingNotice,
          ),
          (SyncConnectionPhase.draining, strings.chatsDeliverySyncingNotice),
          (SyncConnectionPhase.offline, strings.chatsDeliveryWaitingNotice),
        ]) {
          await engine.enter(tester, phase);
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull, reason: words);
          expect(_label(tester), words, reason: words);

          // One line, ending before the search control and not under it.
          final text = tester.widget<Text>(
            find.descendant(of: _title, matching: find.byType(Text)),
          );
          expect(text.maxLines, 1, reason: words);
          expect(text.overflow, TextOverflow.ellipsis, reason: words);
          final title = tester.getRect(_title);
          final search = tester.getRect(
            find.byKey(const ValueKey('chats-search-action')),
          );
          expect(
            rtl ? title.left >= search.right : title.right <= search.left,
            isTrue,
            reason: '$words: $title against $search',
          );

          // The longest does not fit in what the title has, and ends with an
          // ellipsis instead of a second line.
          if (phase == SyncConnectionPhase.offline) {
            expect(
              tester
                  .renderObject<RenderParagraph>(
                    find.descendant(
                      of: _title,
                      matching: find.byType(RichText),
                    ),
                  )
                  .didExceedMaxLines,
              isTrue,
              reason: words,
            );
          }
        }
      });
    }
  });
}

/// The words on the title, which is one `Text`.
String _label(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: _title, matching: find.byType(Text)))
    .data!;

Finder _titleWords(String text) =>
    find.descendant(of: _title, matching: find.text(text));

/// What the engine reports, a phase at a time.
final class _Engine {
  final _projections = StreamController<SyncProjection>();

  /// Reports [phase] and draws what it changed, with no time passing. The
  /// first frame delivers the event and, when nothing animates, only that.
  Future<void> enter(WidgetTester tester, SyncConnectionPhase phase) async {
    _projections.add(
      SyncProjection(
        connectionPhase: phase,
        queueGapState: QueueGapState.clear,
        highestContiguousAcknowledgedSequence: 0,
        prunedThrough: 0,
        inboxDepth: 0,
        outboxDepth: 0,
        nextRetryAt: null,
        lastSuccessfulSyncAt: null,
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

List<ConversationSummary> _summaries() => [
  ConversationSummary(
    conversationId: 'c-group',
    kind: ConversationKind.group,
    peerUserId: null,
    lastMessage: 'Who brings the ball?',
    lastActivityMs: DateTime.utc(2026, 10, 9).millisecondsSinceEpoch,
    unreadCount: 0,
    mutedUntil: null,
    draft: null,
    pinnedMessageIds: const {},
    displayTitle: 'Weekend plans',
  ),
  ConversationSummary(
    conversationId: 'c-saved',
    kind: ConversationKind.saved,
    peerUserId: null,
    lastMessage: 'Shopping list',
    lastActivityMs:
        DateTime.utc(2026, 10, 9).millisecondsSinceEpoch - 3 * 60000,
    unreadCount: 0,
    mutedUntil: null,
    draft: null,
    pinnedMessageIds: const {},
    displayTitle: null,
  ),
];

/// Mounts the application signed in, on the real router, over providers that
/// never reach storage, as `chats_search_page_test.dart` does. The engine's
/// projection is the one [_Engine] feeds, and says nothing until it is told.
Future<_Engine> _pumpApp(
  WidgetTester tester, {
  List<ConversationSummary> summaries = const [],
  Locale locale = const Locale('en'),
  bool offline = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _narrow;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = AuthenticationHarness(
    offline: offline,
    loginResult: Result.success(
      AccountSessionGrant(
        accessToken: 'full-access',
        accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
        accessLifetime: const Duration(minutes: 10),
        userId: userId,
        scope: AccountSessionScope.full,
      ),
    ),
  );
  addTearDown(harness.close);
  final engine = _Engine();
  addTearDown(engine._projections.close);
  final container = ProviderContainer(
    overrides: [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      localDatabaseProvider.overrideWith(
        (ref) => Completer<LocalDatabase>().future,
      ),
      syncProjectionProvider.overrideWith((ref) => engine._projections.stream),
      conversationSummariesProvider.overrideWith(
        (ref, userId) => Stream.value(summaries),
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
        locale: locale,
        themeMode: ThemeMode.light,
      ),
    ),
  );
  await _settle(tester);
  return engine;
}

/// Long enough for the projections to answer. A page still loading shows a
/// spinner, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
