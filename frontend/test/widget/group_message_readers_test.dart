import 'dart:async';

import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who read an own group message, in the message sheet and in the list behind
/// its row (ADR-091 D7), over a fake source of readers.
const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';

/// Reads a message and is not in the group's roster: this phone names nobody
/// it does not know, so the list says "Unknown member".
const _stranger = '00000000-0000-0000-0000-0000000000ff';

const _ownId = '66666666666666666666666666666666';
const _incomingId = '44444444444444444444444444444444';

void main() {
  final strings = lookupAppLocalizations(const Locale('en'));
  late _FakeReaders readers;

  setUp(() {
    readers = _FakeReaders();
    addTearDown(() => unawaited(readers.close()));
  });

  Future<void> openGroup(
    WidgetTester tester, {
    bool withReaders = true,
    Locale locale = const Locale('en'),
    TextScaler textScaler = TextScaler.noScaling,
    Size size = const Size(430, 900),
    bool ownDeleted = false,
    GroupMemberNames? names,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
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
        home: GroupChatPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMemberNames: names ?? _names(),
          injectedMessages: [
            _message(_incomingId, sender: _admin, text: 'From Admin', at: 100),
            _message(
              _ownId,
              sender: _owner,
              text: 'Mine',
              at: 200,
              deleted: ownDeleted,
            ),
          ],
          currentUserId: _owner,
          onSend: (_, {replyToMessageId, quoteFallback}) async =>
              const Result.success(null),
          watchReaders: withReaders ? readers.watch : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder readersRow() => find.byKey(const ValueKey('chat-readers-row'));

  Finder entry(String userId) => find.byKey(ValueKey('chat-reader-$userId'));

  /// The text of one list entry, in the order the entry draws them: the
  /// name, then the time. The avatar's initials are not part of it.
  List<String> entryTexts(WidgetTester tester, String userId) {
    final initials = tester
        .widgetList<Text>(
          find.descendant(
            of: find.descendant(
              of: entry(userId),
              matching: find.byType(ContactAvatar),
            ),
            matching: find.byType(Text),
          ),
        )
        .toSet();
    return [
      for (final text in tester.widgetList<Text>(
        find.descendant(of: entry(userId), matching: find.byType(Text)),
      ))
        if (!initials.contains(text)) text.data!,
    ];
  }

  Future<void> openSheet(WidgetTester tester, String messageId) async {
    await tester.tap(find.byKey(ValueKey('message-$messageId')));
    // The bubble's double-tap recognizer holds the arena before a tap wins.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  Future<void> openList(WidgetTester tester) async {
    await openSheet(tester, _ownId);
    await tester.tap(readersRow());
    await tester.pumpAndSettle();
  }

  /// A read time as the list writes it for a read today.
  String timeOf(WidgetTester tester, int ms) => MaterialLocalizations.of(
    tester.element(find.byType(Scaffold).first),
  ).formatTimeOfDay(TimeOfDay.fromDateTime(_local(ms)));

  /// A read time as the list writes it for a read on an earlier day.
  String dateAndTimeOf(WidgetTester tester, int ms) {
    final material = MaterialLocalizations.of(
      tester.element(find.byType(Scaffold).first),
    );
    return strings.chatReadDateAndTime(
      material.formatMediumDate(_local(ms)),
      timeOf(tester, ms),
    );
  }

  group('the sheet of a group message', () {
    testWidgets('an own message nobody read says "Not seen yet"', (
      tester,
    ) async {
      await openGroup(tester);

      await openSheet(tester, _ownId);

      expect(find.text(strings.chatNotSeenYet), findsOneWidget);
      expect(find.textContaining('Seen by'), findsNothing);
      expect(readers.watched, [_ownId]);
    });

    testWidgets('an own message two members read says "Seen by 2"', (
      tester,
    ) async {
      readers.set(_ownId, [
        const MessageReader(userId: _member, readAtMs: 3000),
        const MessageReader(userId: _admin, readAtMs: 2000),
      ]);
      await openGroup(tester);

      await openSheet(tester, _ownId);

      expect(find.text(strings.chatSeenByCount(2)), findsOneWidget);
      expect(find.text('Seen by 2'), findsOneWidget);
      expect(find.text(strings.chatNotSeenYet), findsNothing);
    });

    testWidgets('the count changes while the sheet is open', (tester) async {
      await openGroup(tester);
      await openSheet(tester, _ownId);
      expect(find.text('Not seen yet'), findsOneWidget);

      readers.set(_ownId, [
        const MessageReader(userId: _admin, readAtMs: 2000),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Seen by 1'), findsOneWidget);
      expect(find.text('Not seen yet'), findsNothing);

      readers.set(_ownId, [
        const MessageReader(userId: _member, readAtMs: 3000),
        const MessageReader(userId: _admin, readAtMs: 2000),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Seen by 2'), findsOneWidget);
      expect(find.text('Seen by 1'), findsNothing);
    });

    testWidgets('the sheet of an incoming message has no reader row, and no '
        'query is opened for it', (tester) async {
      readers.set(_incomingId, [
        const MessageReader(userId: _member, readAtMs: 3000),
      ]);
      await openGroup(tester);

      await openSheet(tester, _incomingId);

      expect(find.text(strings.chatReplyAction), findsOneWidget);
      expect(readersRow(), findsNothing);
      expect(find.textContaining('Seen by'), findsNothing);
      expect(find.text(strings.chatNotSeenYet), findsNothing);
      expect(readers.watched, isEmpty);
    });

    testWidgets('a deleted own message has no reader row', (tester) async {
      await openGroup(tester, ownDeleted: true);

      await openSheet(tester, _ownId);

      expect(find.text(strings.chatReplyAction), findsOneWidget);
      expect(readersRow(), findsNothing);
      expect(readers.watched, isEmpty);
    });

    testWidgets('a page given no readers shows no row on an own message', (
      tester,
    ) async {
      await openGroup(tester, withReaders: false);

      await openSheet(tester, _ownId);

      expect(find.text(strings.chatReplyAction), findsOneWidget);
      expect(readersRow(), findsNothing);
    });

    testWidgets('the row is one button with the count in its label', (
      tester,
    ) async {
      readers.set(_ownId, [
        const MessageReader(userId: _member, readAtMs: 3000),
        const MessageReader(userId: _admin, readAtMs: 2000),
      ]);
      final handle = tester.ensureSemantics();
      await openGroup(tester);

      await openSheet(tester, _ownId);

      expect(
        tester.getSemantics(readersRow()),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Seen by 2',
          hint: strings.chatReadersOpenHint,
        ),
      );
      handle.dispose();
    });
  });

  group('the reader list', () {
    testWidgets('shows each member with the time, the newest first', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final earlier = DateTime.now()
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      readers.set(_ownId, [
        MessageReader(userId: _member, readAtMs: now),
        MessageReader(userId: _admin, readAtMs: earlier),
      ]);
      await openGroup(tester);

      await openList(tester);

      expect(find.text(strings.chatReadersTitle), findsOneWidget);
      expect(entryTexts(tester, _member), ['Member', timeOf(tester, now)]);
      expect(entryTexts(tester, _admin), [
        'Admin',
        dateAndTimeOf(tester, earlier),
      ]);
      expect(
        tester.getTopLeft(entry(_member)).dy,
        lessThan(tester.getTopLeft(entry(_admin)).dy),
      );
      // The sheet of the message gave way to the list.
      expect(readersRow(), findsNothing);
      expect(find.text(strings.chatReplyAction), findsNothing);
    });

    testWidgets('a read today shows the time alone, and an earlier day adds '
        'its date', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final yesterday = DateTime.now()
          .subtract(const Duration(days: 1, hours: 1))
          .millisecondsSinceEpoch;
      readers.set(_ownId, [
        MessageReader(userId: _member, readAtMs: now),
        MessageReader(userId: _admin, readAtMs: yesterday),
      ]);
      await openGroup(tester);

      await openList(tester);

      final todayText = entryTexts(tester, _member).last;
      final yesterdayText = entryTexts(tester, _admin).last;
      expect(todayText, timeOf(tester, now));
      expect(todayText, isNot(contains(',')));
      expect(yesterdayText, dateAndTimeOf(tester, yesterday));
      expect(yesterdayText, endsWith(timeOf(tester, yesterday)));
      expect(yesterdayText, contains(','));
    });

    testWidgets('an unknown time says so, and a member this phone cannot name '
        'shows "Unknown member"', (tester) async {
      readers.set(_ownId, [
        const MessageReader(userId: _stranger, readAtMs: null),
      ]);
      await openGroup(tester);

      await openList(tester);

      expect(entryTexts(tester, _stranger), [
        strings.groupUnknownMember,
        strings.chatReadTimeUnknown,
      ]);
      expect(find.text('Time unknown'), findsOneWidget);
    });

    testWidgets('with no reader it says "Not seen yet"', (tester) async {
      await openGroup(tester);

      await openList(tester);

      expect(find.text(strings.chatNotSeenYet), findsOneWidget);
      expect(find.byKey(ValueKey('chat-reader-$_member')), findsNothing);
    });

    testWidgets('changes while it is open', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      readers.set(_ownId, [
        MessageReader(userId: _admin, readAtMs: now - 5000),
      ]);
      await openGroup(tester);
      await openList(tester);
      expect(entry(_admin), findsOneWidget);
      expect(entry(_member), findsNothing);

      readers.set(_ownId, [
        MessageReader(userId: _member, readAtMs: now),
        MessageReader(userId: _admin, readAtMs: now - 5000),
      ]);
      await tester.pumpAndSettle();

      expect(entry(_member), findsOneWidget);
      expect(entry(_admin), findsOneWidget);
      expect(
        tester.getTopLeft(entry(_member)).dy,
        lessThan(tester.getTopLeft(entry(_admin)).dy),
      );

      // A third reader, newest of all, takes the top.
      readers.set(_ownId, [
        MessageReader(userId: _stranger, readAtMs: now + 60000),
        MessageReader(userId: _member, readAtMs: now),
        MessageReader(userId: _admin, readAtMs: now - 5000),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(entry(_stranger)).dy,
        lessThan(tester.getTopLeft(entry(_member)).dy),
      );
    });

    testWidgets('keeps its width in Persian, right to left, at 200 % text', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final earlier = DateTime.now()
          .subtract(const Duration(days: 9))
          .millisecondsSinceEpoch;
      const longName =
          'یک نام بسیار بسیار طولانی برای عضوی از گروه که باید در چند خط '
          'شکسته شود و از لبهٔ برگه بیرون نزند';
      readers.set(_ownId, [
        MessageReader(userId: _member, readAtMs: now),
        MessageReader(userId: _admin, readAtMs: earlier),
        const MessageReader(userId: _stranger, readAtMs: null),
      ]);
      await openGroup(
        tester,
        locale: const Locale('fa'),
        textScaler: const TextScaler.linear(2),
        size: const Size(360, 800),
        names: _names(adminName: longName),
      );

      await openSheet(tester, _ownId);
      expect(readersRow(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(readersRow());
      await tester.pumpAndSettle();

      expect(
        Directionality.of(tester.element(entry(_member))),
        TextDirection.rtl,
      );
      // The list scrolls inside the sheet, so each entry is brought into
      // view and must sit inside the list's width, whatever it holds.
      // The timeline has a list of its own; this one shrinks to its entries.
      final list = find.byWidgetPredicate(
        (widget) => widget is ListView && widget.shrinkWrap,
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final sheet = tester.getRect(list);
      for (final userId in [_member, _admin, _stranger]) {
        await tester.scrollUntilVisible(
          entry(userId),
          80,
          scrollable: scrollable,
        );
        final rect = tester.getRect(entry(userId));
        expect(rect.left, greaterThanOrEqualTo(sheet.left));
        expect(rect.right, lessThanOrEqualTo(sheet.right));
        expect(tester.takeException(), isNull);
      }
      expect(
        find.descendant(of: entry(_admin), matching: find.text(longName)),
        findsOneWidget,
      );
    });

    testWidgets('each entry is one node with the name and the time', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      readers.set(_ownId, [
        MessageReader(userId: _member, readAtMs: now),
        const MessageReader(userId: _stranger, readAtMs: null),
      ]);
      final handle = tester.ensureSemantics();
      await openGroup(tester);

      await openList(tester);

      final known = strings.chatReaderSemantics('Member', timeOf(tester, now));
      final unknown = strings.chatReaderSemantics(
        strings.groupUnknownMember,
        strings.chatReadTimeUnknown,
      );
      expect(tester.getSemantics(entry(_member)).label, known);
      expect(tester.getSemantics(entry(_stranger)).label, unknown);
      expect(find.semantics.byLabel(known), findsOneWidget);
      expect(find.semantics.byLabel(unknown), findsOneWidget);
      // Neither the name, the time nor the avatar is a node of its own.
      expect(find.semantics.byLabel('Member'), findsNothing);
      expect(find.semantics.byLabel(timeOf(tester, now)), findsNothing);
      expect(find.semantics.byLabel(strings.chatReadTimeUnknown), findsNothing);
      handle.dispose();
    });
  });

  group('a direct chat', () {
    testWidgets('gives the sheet of an own message no reader row', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) =>
              AppDesignSystem(child: child ?? const SizedBox.shrink()),
          home: ChatConversationView(
            model: _directTimeline(),
            onIntent: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await openSheet(tester, _ownId);

      expect(find.text(strings.chatReplyAction), findsOneWidget);
      expect(readersRow(), findsNothing);
      expect(find.textContaining('Seen by'), findsNothing);
      expect(find.text(strings.chatNotSeenYet), findsNothing);
    });
  });
}

/// The wall-clock time of [ms], as the page shows it.
DateTime _local(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();

/// A source of readers a test sets and changes, and which records each
/// message a query was opened for.
final class _FakeReaders {
  final _lists = <String, List<MessageReader>>{};
  final _changes = StreamController<String>.broadcast();

  /// The ids of the messages a query was opened for, in order.
  final watched = <String>[];

  Stream<List<MessageReader>> watch(String messageId) async* {
    watched.add(messageId);
    yield _lists[messageId] ?? const [];
    await for (final changed in _changes.stream) {
      if (changed == messageId) yield _lists[messageId] ?? const [];
    }
  }

  void set(String messageId, List<MessageReader> readers) {
    _lists[messageId] = readers;
    _changes.add(messageId);
  }

  Future<void> close() => _changes.close();
}

ChatTimelineViewModel _directTimeline() => ChatTimelineViewModel(
  state: ChatTimelineLoadState.data,
  conversationId:
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  title: 'Someone',
  savedMessages: false,
  securityGate: ChatSecurityGate.ready,
  offline: false,
  hasMoreBefore: false,
  loadingBefore: false,
  olderLoadFailed: false,
  typing: false,
  pinnedMessages: const [],
  messages: [
    ChatMessageViewModel(
      id: _ownId,
      authorId: _owner,
      authorName: 'You',
      outgoing: true,
      kind: ChatTimelineContentKind.text,
      text: 'Mine',
      timestamp: DateTime(2026, 10, 14, 10),
      delivery: ChatDeliveryViewState.read,
      firstInAuthorGroup: true,
      lastInAuthorGroup: true,
      edited: false,
      deleted: false,
      pinned: false,
      starred: false,
      unread: false,
      timestampSkewed: false,
      canEdit: true,
      canDeleteForEveryone: true,
    ),
  ],
);

/// What this phone calls the three members of the roster.
GroupMemberNames _names({String adminName = 'Admin'}) => GroupMemberNames({
  _owner: const GroupMemberName(name: 'Owner', verified: true),
  _admin: GroupMemberName(name: adminName, verified: true),
  _member: const GroupMemberName(name: 'Member', verified: true),
});

/// The roster as a control event decodes it on a receiving phone: user ids and
/// roles, and no name.
GroupState _state() => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Private Team', description: ''),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
  members: [
    GroupMember(
      userId: _owner,
      displayName: '',
      role: GroupRole.owner,
      verified: true,
    ),
    GroupMember(
      userId: _admin,
      displayName: '',
      role: GroupRole.admin,
      verified: true,
    ),
    GroupMember(
      userId: _member,
      displayName: '',
      role: GroupRole.member,
      verified: true,
    ),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
);

/// One row of the group's conversation, as local storage hands it on. A
/// message of [_owner] is an own message, already accepted by the relay.
ConversationMessage _message(
  String messageId, {
  required String sender,
  required String text,
  int at = 100,
  bool deleted = false,
}) => ConversationMessage(
  messageId: messageId,
  conversationId: _groupId,
  senderUserId: sender,
  senderDeviceId: 'device',
  text: text,
  replyToMessageId: null,
  quoteFallback: null,
  createdMs: at,
  orderingMs: at,
  orderingEventId: messageId,
  timestampState: MessageTimestampState.plausible,
  revision: 0,
  edited: false,
  deletedForEveryone: deleted,
  deletedForMe: false,
  pinned: false,
  starred: false,
  unread: false,
  transportState: sender == _owner
      ? MessageTransportState.relayAccepted
      : MessageTransportState.received,
  receiptState: MessageReceiptState.none,
  reactions: const [],
);
