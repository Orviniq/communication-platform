import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chats_search_page.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart';
import '../support/system_insets.dart';

const _narrow = Size(360, 800);

final _field = find.byKey(const ValueKey('chats-search-field'));
final _scope = find.byKey(const ValueKey('chats-search-scope'));
final _noResults = find.byKey(const ValueKey('chats-search-no-results'));
final _results = find.byKey(
  const PageStorageKey<String>('chats-search-results'),
);

const _scopeText =
    "This searches chat names, the latest message of each chat, and your "
    "contacts' names and usernames. To search older messages, open a "
    'conversation and search inside it. Your search stays on this phone.';

void main() {
  testWidgets('the Chats list holds no search field, and lists every '
      'conversation', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());

    expect(find.byKey(const ValueKey('chats-list-screen')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    for (final title in ['Maryam', 'Reza', 'Weekend plans', 'Saved Messages']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.byTooltip('Search chats'), findsOneWidget);
  });

  testWidgets('the search icon opens the search page over the shell, and its '
      'field takes the focus', (tester) async {
    await _pumpApp(tester);
    await _openSearch(tester);

    expect(find.byType(ChatsSearchPage), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byType(ChatsSearchPage))).uri.path,
      '/chats/search',
    );
    expect(find.byKey(const ValueKey('shell-narrow')), findsNothing);
    expect(_editor(tester).widget.focusNode.hasFocus, isTrue);
  });

  testWidgets('an empty query states the scope and lists nothing', (
    tester,
  ) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    expect(_scope, findsOneWidget);
    expect(find.text(_scopeText), findsOneWidget);
    expect(_results, findsNothing);
    expect(find.text('Chats'), findsNothing);
    expect(find.text('Contacts'), findsNothing);
  });

  testWidgets('a chat is found by its name and by its latest message, without '
      'regard to case', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    await _type(tester, 'MARYAM');
    expect(_chatRow('c-maryam'), findsOneWidget);
    expect(_chatRow('c-reza'), findsNothing);

    await _type(tester, 'Pizza Tonight');
    expect(_chatRow('c-reza'), findsOneWidget);
    expect(_chatRow('c-maryam'), findsNothing);

    // A group's name, and Saved Messages by the note it holds.
    await _type(tester, 'weekend');
    expect(_chatRow('c-group'), findsOneWidget);
    await _type(tester, 'shopping');
    expect(_chatRow('c-saved'), findsOneWidget);
  });

  testWidgets('a contact is found by its username, and by its display name '
      'only when it is verified', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    await _type(tester, 'SARA_');
    expect(_contactRow('u-sara'), findsOneWidget);
    expect(find.text('Chats'), findsNothing);
    expect(find.text('Contacts'), findsOneWidget);

    await _type(tester, 'parisa');
    expect(_contactRow('u-sara'), findsOneWidget);

    // Nima's profile names him Parvin, but nobody verified him.
    await _type(tester, 'parvin');
    expect(_contactRow('u-nima'), findsNothing);
    expect(_noResults, findsOneWidget);
    await _type(tester, 'nima');
    expect(_contactRow('u-nima'), findsOneWidget);
  });

  testWidgets('a contact whose direct chat was found shows under Chats only', (
    tester,
  ) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    // Maryam's chat carries her verified name; her contact matches it too.
    await _type(tester, 'maryam');
    expect(_chatRow('c-maryam'), findsOneWidget);
    expect(_contactRow('u-maryam'), findsNothing);
    expect(find.text('Contacts'), findsNothing);

    // Her username is not on her chat, so the contact is the only way there.
    await _type(tester, 'maryam_a');
    expect(_chatRow('c-maryam'), findsNothing);
    expect(_contactRow('u-maryam'), findsOneWidget);
  });

  testWidgets('both sections show in order, each under a header', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    await _type(tester, 'pa');
    final chats = find.text('Chats');
    final contacts = find.text('Contacts');
    expect(chats, findsOneWidget);
    expect(contacts, findsOneWidget);
    expect(_chatRow('c-reza'), findsOneWidget);
    expect(_contactRow('u-sara'), findsOneWidget);
    expect(
      tester.getRect(chats).bottom,
      lessThan(tester.getRect(_chatRow('c-reza')).top),
    );
    expect(
      tester.getRect(_chatRow('c-reza')).bottom,
      lessThanOrEqualTo(tester.getRect(contacts).top),
    );
    expect(
      tester.getRect(contacts).bottom,
      lessThan(tester.getRect(_contactRow('u-sara')).top),
    );
    for (final header in [chats, contacts]) {
      expect(tester.getSemantics(header), isSemantics(isHeader: true));
    }
    semantics.dispose();
  });

  testWidgets('a query that finds nothing says so, with the scope', (
    tester,
  ) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);

    await _type(tester, 'zzz');
    expect(_noResults, findsOneWidget);
    expect(find.text('Nothing found on this phone'), findsOneWidget);
    expect(find.text(_scopeText), findsOneWidget);
    expect(_results, findsNothing);
  });

  testWidgets('the clear control shows only with a query, and clears it', (
    tester,
  ) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    final clear = find.byKey(const ValueKey('chats-search-clear'));
    expect(clear, findsNothing);

    await _type(tester, 'maryam');
    expect(clear, findsOneWidget);
    expect(find.byTooltip('Clear search'), findsOneWidget);

    await tester.tap(clear);
    await _settle(tester);
    expect(_editor(tester).textEditingValue.text, isEmpty);
    expect(clear, findsNothing);
    expect(_scope, findsOneWidget);
  });

  testWidgets('a tap on a chat opens it, and back returns to the query and '
      'its results', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'pizza');

    await tester.tap(_chatRow('c-reza'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('direct-chat-screen')), findsOneWidget);
    expect(_location(tester), '/chats/conversation/c-reza');
    expect(
      tester.widget<DirectChatPage>(find.byType(DirectChatPage)).peerUserId,
      'u-reza',
    );

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(find.byType(ChatsSearchPage), findsOneWidget);
    expect(_editor(tester).textEditingValue.text, 'pizza');
    expect(_chatRow('c-reza'), findsOneWidget);
  });

  testWidgets('a tap on a group opens the group', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'weekend');

    await tester.tap(_chatRow('c-group'));
    await _settle(tester);
    expect(find.byType(GroupChatPage), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(_editor(tester).textEditingValue.text, 'weekend');
  });

  testWidgets('a tap on a contact opens /chats/direct/<userId>, and back '
      'returns to the query and its results', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'sara_');

    await tester.tap(_contactRow('u-sara'));
    await _settle(tester);
    expect(_location(tester), '/chats/direct/u-sara');
    expect(find.byKey(const ValueKey('direct-chat-screen')), findsOneWidget);
    expect(
      tester.widget<DirectChatPage>(find.byType(DirectChatPage)).peerUserId,
      'u-sara',
    );

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);
    expect(find.byType(ChatsSearchPage), findsOneWidget);
    expect(_editor(tester).textEditingValue.text, 'sara_');
    expect(_contactRow('u-sara'), findsOneWidget);
  });

  testWidgets('a long press on a chat opens no menu', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'maryam');

    await tester.longPress(_chatRow('c-maryam'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('app-sheet-surface')), findsNothing);
    expect(find.text('Delete chat'), findsNothing);
  });

  testWidgets('back from the search page returns to the Chats list at the '
      'same place', (tester) async {
    await _pumpApp(tester, summaries: _manySummaries());
    _chatsPosition(tester).jumpTo(1500);
    await tester.pump();
    final offset = _chatsPosition(tester).pixels;
    expect(offset, 1500);

    await _openSearch(tester);
    await _type(tester, 'peer-2');
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);

    expect(find.byKey(const ValueKey('chats-list-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-narrow')), findsOneWidget);
    expect(_chatsPosition(tester).pixels, offset);
  });

  testWidgets('a reopened search starts empty: no query is kept', (
    tester,
  ) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'maryam');
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _settle(tester);

    await _openSearch(tester);
    expect(_editor(tester).textEditingValue.text, isEmpty);
    expect(_scope, findsOneWidget);
  });

  testWidgets('the page reaches no directory service', (tester) async {
    final directory = _RecordingDirectory();
    await _pumpApp(
      tester,
      summaries: _summaries(),
      contacts: _contacts(),
      directory: directory,
    );
    await _openSearch(tester);
    for (final query in ['maryam', 'sara_', 'zzz', '']) {
      await _type(tester, query);
    }

    expect(directory.builds, 0);
    expect(directory.calls, isEmpty);
  });

  testWidgets('the field asks the keyboard not to learn the query', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openSearch(tester);

    expect(_editor(tester).widget.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('a screen reader names the field, and keeps the name while a '
      'query is typed', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpApp(tester);
    await _openSearch(tester);

    expect(
      tester.getSemantics(_field),
      isSemantics(
        label:
            'Search chats and contacts\n'
            'Search names, usernames and latest messages',
        isTextField: true,
        isFocused: true,
      ),
    );
    await _type(tester, 'maryam');
    expect(
      tester.getSemantics(_field),
      isSemantics(
        label: 'Search chats and contacts',
        value: 'maryam',
        isTextField: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('every control keeps the minimum touch target', (tester) async {
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'pa');

    for (final control in [
      find.byTooltip('Back'),
      find.byKey(const ValueKey('chats-search-clear')),
      _field,
      _chatRow('c-reza'),
      _contactRow('u-sara'),
    ]) {
      final size = tester.getSize(control);
      expect(size.width, greaterThanOrEqualTo(AppFocus.minimumTarget));
      expect(size.height, greaterThanOrEqualTo(AppFocus.minimumTarget));
    }
  });

  testWidgets('a result row offers a screen reader one node to activate', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpApp(tester, summaries: _summaries(), contacts: _contacts());
    await _openSearch(tester);
    await _type(tester, 'sara');

    const label = 'Parisa, @sara_m, Identity verified';
    expect(
      tester.getSemantics(_contactRow('u-sara')),
      isSemantics(label: label, isButton: true, hasTapAction: true),
    );
    expect(find.semantics.byLabel(label), findsOneWidget);

    tester.semantics.tap(find.semantics.byLabel(label));
    await _settle(tester);
    expect(_location(tester), '/chats/direct/u-sara');
    semantics.dispose();
  });

  testWidgets('the last result rests above the gesture bar at the end of the '
      'scroll', (tester) async {
    fakeSystemInsets(tester);
    await _pumpApp(tester, summaries: _manySummaries());
    await _openSearch(tester);
    await _type(tester, 'message');

    final position = tester
        .state<ScrollableState>(
          find.descendant(of: _results, matching: find.byType(Scrollable)),
        )
        .position;
    // A lazy list learns its extent as it lays rows out.
    do {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    } while (position.pixels < position.maxScrollExtent);
    final last = _chatRow('c-39');
    expect(last, findsOneWidget);
    expect(
      tester.getRect(last).bottom,
      closeTo(_narrow.height - 48 - AppSpacing.x2, 0.01),
    );
    // The list itself runs to the bottom edge, under the gesture bar.
    expect(tester.getRect(_results).bottom, _narrow.height);
  });

  testWidgets('a mute that ends while the results are on screen leaves its '
      'row', (tester) async {
    final until = DateTime.now().toUtc().add(const Duration(seconds: 2));
    await _pumpApp(
      tester,
      summaries: [_summary('c-muted', peer: 'u-muted', mutedUntil: until)],
    );
    await _openSearch(tester);
    await _type(tester, 'u-muted');
    final muted = find.descendant(
      of: _chatRow('c-muted'),
      matching: find.byWidgetPredicate(
        (widget) => widget is AppIcon && widget.data == AppIcons.muted,
      ),
    );
    expect(muted, findsOneWidget);

    // The clock the rows are read at is the real one; the timer that moves
    // it is the test's.
    await tester.runAsync(
      () => Future<void>.delayed(
        until.difference(DateTime.now().toUtc()) +
            const Duration(milliseconds: 100),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(muted, findsNothing);
  });

  group('at twice the text size, 360 by 800, nothing overflows', () {
    for (final locale in const [Locale('en'), Locale('fa')]) {
      testWidgets(locale.languageCode, (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        fakeSystemInsets(tester);
        await _pumpApp(
          tester,
          summaries: _summaries(),
          contacts: _contacts(),
          locale: locale,
        );
        await _openSearch(tester);
        expect(tester.takeException(), isNull);
        expect(
          Directionality.of(tester.element(_field)),
          locale.languageCode == 'fa' ? TextDirection.rtl : TextDirection.ltr,
        );

        // Both sections, then nothing found, then the keyboard over both.
        for (final query in ['pa', 'zzz']) {
          await _type(tester, query);
          expect(tester.takeException(), isNull, reason: query);
        }
        fakeOpenKeyboard(tester);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await _type(tester, 'pa');
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// Opens the search from the Chats list's app bar.
Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('chats-search-action')));
  await _settle(tester);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await _settle(tester);
}

EditableTextState _editor(WidgetTester tester) => tester.state(
  find.descendant(of: _field, matching: find.byType(EditableText)),
);

Finder _chatRow(String conversationId) =>
    find.byKey(ValueKey('chats-search-chat-$conversationId'));

Finder _contactRow(String userId) =>
    find.byKey(ValueKey('chats-search-contact-$userId'));

/// The path of the direct chat on top, as its route was pushed.
String _location(WidgetTester tester) =>
    GoRouterState.of(tester.element(find.byType(DirectChatPage))).uri.path;

ScrollPosition _chatsPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('chats-list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

ConversationSummary _summary(
  String id, {
  String? peer,
  ConversationKind kind = ConversationKind.direct,
  String? lastMessage,
  String? title,
  int minutesAgo = 0,
  DateTime? mutedUntil,
}) => ConversationSummary(
  conversationId: id,
  kind: kind,
  peerUserId: peer,
  lastMessage: lastMessage,
  lastActivityMs:
      DateTime.utc(2026, 10, 9).millisecondsSinceEpoch - minutesAgo * 60000,
  unreadCount: 0,
  mutedUntil: mutedUntil,
  draft: null,
  pinnedMessageIds: const {},
  displayTitle: title,
);

/// Four conversations: two direct ones with contacts, a group and Saved
/// Messages.
List<ConversationSummary> _summaries() => [
  _summary('c-maryam', peer: 'u-maryam', lastMessage: 'See you soon'),
  _summary(
    'c-reza',
    peer: 'u-reza',
    lastMessage: 'Pizza tonight at the park?',
    minutesAgo: 1,
  ),
  _summary(
    'c-group',
    kind: ConversationKind.group,
    title: 'Weekend plans',
    lastMessage: 'Who brings the ball?',
    minutesAgo: 2,
  ),
  _summary(
    'c-saved',
    kind: ConversationKind.saved,
    lastMessage: 'Shopping list',
    minutesAgo: 3,
  ),
];

/// Forty direct conversations, `c-00` to `c-39`, newest first.
List<ConversationSummary> _manySummaries() => [
  for (var index = 0; index < 40; index += 1)
    _summary(
      'c-${index.toString().padLeft(2, '0')}',
      peer: 'peer-${index.toString().padLeft(2, '0')}',
      lastMessage: 'message $index',
      minutesAgo: index,
    ),
];

List<ContactProjection> _contacts() => [
  _contact('u-maryam', 'maryam_a', name: 'Maryam', verified: true),
  _contact('u-reza', 'reza_k', name: 'Reza', verified: true),
  _contact('u-sara', 'sara_m', name: 'Parisa', verified: true),
  _contact('u-nima', 'nima', name: 'Parvin'),
];

ContactProjection _contact(
  String userId,
  String username, {
  String? name,
  bool verified = false,
}) => ContactProjection(
  userId: userId,
  username: username,
  trustState: verified
      ? ContactTrustState.verified
      : ContactTrustState.unverified,
  authenticatedProfile: name == null
      ? null
      : AuthenticatedProfile(
          displayName: name,
          avatarSeed: 2,
          version: 1,
          authorDeviceId: 'device',
        ),
);

/// A directory that records every use: the provider building it, and every
/// call into either of its ports.
final class _RecordingDirectory {
  var builds = 0;
  final calls = <Symbol>[];

  DirectoryService build() {
    builds += 1;
    return DirectoryService(remote: _Recorder(calls), local: _Recorder(calls));
  }
}

final class _Recorder implements DirectoryRemotePort, ContactLocalPort {
  _Recorder(this.calls);

  final List<Symbol> calls;

  @override
  Never noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('the search page called the directory');
  }
}

/// Mounts the application signed in, on the real router, over providers that
/// never reach storage, as `full_screen_pages_test.dart` does: the database
/// never opens, and the projections the pages under test draw are answered
/// here.
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  List<ConversationSummary> summaries = const [],
  List<ContactProjection> contacts = const [],
  _RecordingDirectory? directory,
  Locale locale = const Locale('en'),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _narrow;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = AuthenticationHarness();
  addTearDown(harness.close);
  final recorder = directory ?? _RecordingDirectory();
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
      contactListProvider.overrideWith((ref, userId) => Stream.value(contacts)),
      // A verified peer, so a direct chat opens as it does for a contact.
      contactProvider.overrideWith(
        (ref, userId) => Stream.value(
          ContactProjection(
            userId: userId,
            username: userId,
            trustState: ContactTrustState.verified,
          ),
        ),
      ),
      // The id a direct chat opened by its peer derives, answered here rather
      // than by the crypto core.
      conversationIdentityProvider.overrideWith(
        (ref, request) => 'c-direct-${request.peerUserId}',
      ),
      directoryServiceProvider.overrideWith((ref) => recorder.build()),
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
  return container;
}

/// Long enough for a route transition and for the projections to answer. A
/// page still loading shows a spinner, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
