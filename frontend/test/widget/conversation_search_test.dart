import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/conversation_search.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/system_insets.dart';

/// The one in-conversation search surface, which direct, saved and group
/// conversations all open.
///
/// What is asserted here is what the surface *claims*: that it searches this
/// phone only, that it says so, and that it never quietly shows fewer results
/// than it found without saying that either.
void main() {
  testWidgets('an empty query states the scope rather than listing anything', (
    tester,
  ) async {
    await _open(tester, messages: _history(3));

    expect(find.text('Search this device\'s history'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversation-search-scope-notice')),
      findsOneWidget,
    );
    expect(
      find.textContaining('The server never sees them'),
      findsWidgets,
      reason: 'the privacy scope is stated on the surface, not in a document',
    );
  });

  testWidgets('a query that matches nothing says so in the same scope', (
    tester,
  ) async {
    await _open(tester, messages: _history(3));

    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-field')),
      'nothing here matches',
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing found on this phone'), findsOneWidget);
  });

  testWidgets('matches are listed with a count and open the message', (
    tester,
  ) async {
    String? jumped;
    await _open(tester, messages: _history(3), onJump: (id) => jumped = id);

    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-field')),
      'message 2',
    );
    await tester.pumpAndSettle();

    expect(find.text('1 matches on this phone'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conversation-search-hit-m2')));
    await tester.pumpAndSettle();
    expect(jumped, 'm2');
  });

  testWidgets('a truncated result set says it is truncated', (tester) async {
    await _open(tester, messages: _history(200));

    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-field')),
      'message',
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Showing the first 30 matches. Type more of the message to '
        'narrow it down.',
      ),
      findsOneWidget,
      reason: 'a silently capped result set misdescribes its own scope',
    );
  });

  testWidgets('the surface is translated and right-to-left in Persian', (
    tester,
  ) async {
    await _open(tester, messages: _history(2), locale: const Locale('fa'));

    expect(find.text('جست‌وجوی پیام‌های محلی'), findsOneWidget);
    expect(find.textContaining('Search local messages'), findsNothing);
    final directionality = tester.widget<Directionality>(
      find.byType(Directionality).first,
    );
    expect(directionality.textDirection, TextDirection.rtl);
  });

  testWidgets('it is readable at the largest supported text scale', (
    tester,
  ) async {
    await _open(
      tester,
      messages: _history(3),
      textScaler: const TextScaler.linear(2),
    );

    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-field')),
      'message',
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // The rule is written once, in `app_modals.dart`, and proved on the two
  // sheet functions in `sheet_insets_test.dart`. This sheet asks for the
  // keyboard the moment it opens, on a screen short enough for it to matter.
  testWidgets('on a short screen it sits between the status bar and the '
      'keyboard, with its field in view', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    fakeSystemInsets(tester);
    fakeOpenKeyboard(tester);
    await _open(tester, messages: _history(3));

    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-field')),
      'message',
    );
    await tester.pumpAndSettle();

    final sheet = tester.getRect(
      find.byKey(const ValueKey('app-sheet-surface')),
    );
    expect(sheet.bottom, closeTo(640 - 300, 0.01));
    expect(sheet.top, greaterThanOrEqualTo(24));
    final field = tester.getRect(
      find.byKey(const ValueKey('conversation-search-field')),
    );
    expect(field.top, greaterThanOrEqualTo(sheet.top));
    expect(find.byKey(const ValueKey('conversation-search-hit-m1')), findsOne);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _open(
  WidgetTester tester, {
  required List<ChatMessageViewModel> messages,
  ValueChanged<String>? onJump,
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
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
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showConversationSearch(
                context: context,
                messages: messages,
                onJumpToMessage: onJump ?? (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

List<ChatMessageViewModel> _history(int count) => [
  for (var index = 1; index <= count; index += 1)
    ChatMessageViewModel(
      id: 'm$index',
      authorId: 'author',
      authorName: 'Author',
      outgoing: false,
      kind: ChatTimelineContentKind.text,
      text: 'message $index',
      timestamp: DateTime.utc(2026),
      delivery: ChatDeliveryViewState.delivered,
      firstInAuthorGroup: true,
      lastInAuthorGroup: true,
      edited: false,
      deleted: false,
      pinned: false,
      starred: false,
      unread: false,
      timestampSkewed: false,
      canEdit: false,
      canDeleteForEveryone: false,
    ),
];
