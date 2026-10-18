import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_undelivered_hint.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line under the newest own direct message that no receipt has answered
/// for an hour (ADR-093 D19): when it shows, when it does not, and that it
/// waits on a clock the test owns.
///
/// A group chat has its own page and its own test, in
/// `group_message_actions_test.dart`, beside the direct chat that shows the
/// line for the same stored message.
const _hint = 'Not delivered yet. If @alice has not verified you, ask them to.';

final _sentAt = DateTime.utc(2026, 10, 18, 9);
final _line = find.byKey(const ValueKey('chat-undelivered-hint'));

void main() {
  test('the delay is one hour', () {
    expect(chatUndeliveredHintDelay, const Duration(hours: 1));
  });

  group('when the line shows', () {
    testWidgets('not before one hour, and from the moment the hour is up', (
      tester,
    ) async {
      final clock = _Clock(_sentAt);
      await _pump(tester, [_message('a')], clock: clock);
      expect(_line, findsNothing);

      clock.now = _sentAt.add(const Duration(minutes: 59, seconds: 59));
      await tester.pump(const Duration(minutes: 59, seconds: 59));
      expect(_line, findsNothing, reason: 'a second short of the hour');

      clock.now = _sentAt.add(const Duration(hours: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(_line, findsOneWidget);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('a message that is already an hour old shows it at once', (
      tester,
    ) async {
      await _pump(tester, [
        _message('a'),
      ], clock: _Clock(_sentAt.add(const Duration(hours: 5))));
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('it stands under the newest own message, once', (tester) async {
      await _pump(tester, [
        _message('a', at: _sentAt.subtract(const Duration(hours: 3))),
        _message('b', at: _sentAt.subtract(const Duration(hours: 2))),
        _message('c'),
      ], clock: _Clock(_sentAt.add(const Duration(hours: 2))));

      expect(_line, findsOneWidget);
      final newest = tester.getRect(find.byKey(const ValueKey('message-c')));
      final older = tester.getRect(find.byKey(const ValueKey('message-b')));
      final hint = tester.getRect(_line);
      expect(hint.top, greaterThanOrEqualTo(newest.bottom));
      expect(hint.top, greaterThan(older.bottom));
    });

    testWidgets('a short identity is named without the @', (tester) async {
      await _pump(
        tester,
        [_message('a')],
        clock: _Clock(_sentAt.add(const Duration(hours: 2))),
        peer: '1a2b3c4d…',
      );
      expect(
        find.text(
          'Not delivered yet. If 1a2b3c4d… has not verified you, ask them to.',
        ),
        findsOneWidget,
      );
    });
  });

  group('when it does not', () {
    final late = _Clock(_sentAt.add(const Duration(hours: 2)));

    for (final delivery in const [
      ChatDeliveryViewState.delivered,
      ChatDeliveryViewState.read,
      ChatDeliveryViewState.queued,
      ChatDeliveryViewState.encrypting,
      ChatDeliveryViewState.sending,
      ChatDeliveryViewState.localOnly,
      ChatDeliveryViewState.failed,
    ]) {
      testWidgets('not under a ${delivery.name} message', (tester) async {
        await _pump(tester, [_message('a', delivery: delivery)], clock: late);
        expect(_line, findsNothing);
      });
    }

    testWidgets('a receipt on the newest message takes the line away', (
      tester,
    ) async {
      await _pump(tester, [_message('a')], clock: late);
      expect(_line, findsOneWidget);

      await _pump(tester, [
        _message('a', delivery: ChatDeliveryViewState.delivered),
      ], clock: late);
      expect(_line, findsNothing);
    });

    testWidgets('an older message the peer has not answered is not the '
        'newest: a receipt on a later one says the peer receives', (
      tester,
    ) async {
      await _pump(tester, [
        _message('a', at: _sentAt.subtract(const Duration(hours: 2))),
        _message('b', delivery: ChatDeliveryViewState.delivered),
      ], clock: late);
      expect(_line, findsNothing);
    });

    testWidgets('a message of the peer is not an own message', (tester) async {
      await _pump(tester, [_message('a', outgoing: false)], clock: late);
      expect(_line, findsNothing);
    });

    testWidgets('a deleted message carries no line', (tester) async {
      await _pump(tester, [_message('a', deleted: true)], clock: late);
      expect(_line, findsNothing);
    });

    testWidgets('Saved Messages has none', (tester) async {
      await _pump(
        tester,
        [_message('a')],
        clock: late,
        savedMessages: true,
        peerUserId: null,
      );
      expect(_line, findsNothing);
    });

    testWidgets('a view that names no peer has none', (tester) async {
      await _pump(tester, [_message('a')], clock: late, peer: null);
      expect(_line, findsNothing);
    });
  });

  group('the clock', () {
    testWidgets('holds no timer when there is nothing to wait for', (
      tester,
    ) async {
      await _pump(tester, [
        _message('a', delivery: ChatDeliveryViewState.delivered),
      ], clock: _Clock(_sentAt));
      // A pending timer fails the test when it ends.
      expect(_line, findsNothing);
    });

    testWidgets('holds one for the moment the hour is up, and gives it up '
        'with the screen', (tester) async {
      await _pump(tester, [_message('a')], clock: _Clock(_sentAt));
      expect(_line, findsNothing);

      // Leaving the chat cancels the timer: nothing is pending at the end.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the line fits', () {
    for (final (locale, scale) in const [
      (Locale('en'), 2.0),
      (Locale('fa'), 1.0),
      (Locale('fa'), 2.0),
    ]) {
      testWidgets('${locale.languageCode} at ${(scale * 100).round()} % text', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pump(
          tester,
          [_message('a')],
          clock: _Clock(_sentAt.add(const Duration(hours: 2))),
          locale: locale,
        );
        expect(_line, findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('in Persian the line is in Persian', (tester) async {
      await _pump(
        tester,
        [_message('a')],
        clock: _Clock(_sentAt.add(const Duration(hours: 2))),
        locale: const Locale('fa'),
      );
      expect(
        (tester.widget<Text>(_line)).data,
        contains('هنوز تحویل نشده است'),
      );
    });
  });
}

final class _Clock {
  _Clock(this.now);

  DateTime now;
}

ChatMessageViewModel _message(
  String id, {
  DateTime? at,
  ChatDeliveryViewState delivery = ChatDeliveryViewState.accepted,
  bool outgoing = true,
  bool deleted = false,
}) => ChatMessageViewModel(
  id: id,
  authorId: outgoing ? 'self' : 'peer',
  authorName: outgoing ? 'You' : 'Peer',
  outgoing: outgoing,
  kind: ChatTimelineContentKind.text,
  text: 'text $id',
  timestamp: at ?? _sentAt,
  delivery: outgoing ? delivery : ChatDeliveryViewState.received,
  firstInAuthorGroup: true,
  lastInAuthorGroup: true,
  edited: false,
  deleted: deleted,
  pinned: false,
  starred: false,
  unread: false,
  timestampSkewed: false,
  canEdit: outgoing,
  canDeleteForEveryone: outgoing,
  replyToMessageId: null,
  replyAuthor: null,
  replyQuote: null,
  reactions: const [],
);

Future<void> _pump(
  WidgetTester tester,
  List<ChatMessageViewModel> messages, {
  required _Clock clock,
  String? peer = '@alice',
  String? peerUserId = 'u-alice',
  bool savedMessages = false,
  Locale locale = const Locale('en'),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: ChatConversationView(
        model: ChatTimelineViewModel(
          state: ChatTimelineLoadState.data,
          conversationId: 'conversation',
          title: 'Peer',
          savedMessages: savedMessages,
          securityGate: ChatSecurityGate.ready,
          offline: false,
          hasMoreBefore: false,
          loadingBefore: false,
          olderLoadFailed: false,
          typing: false,
          pinnedMessages: const [],
          messages: messages,
        ),
        peerUserId: peerUserId,
        undeliveredHintPeer: peer,
        now: () => clock.now,
        onIntent: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}
