import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the composer tells typing (ADR-098 D3): whether it holds text after
/// each change of it, and nothing for a change that is not somebody writing.
void main() {
  final field = find.byKey(const ValueKey('chat-composer-field'));

  testWidgets('each change of the text says whether any is left; a moved '
      'caret says nothing', (tester) async {
    final reported = <bool>[];
    await _pump(tester, onTyping: reported.add);

    await tester.enterText(field, 'h');
    await tester.enterText(field, 'hi');
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .userUpdateTextEditingValue(
          const TextEditingValue(
            text: 'hi',
            selection: TextSelection.collapsed(offset: 0),
          ),
          SelectionChangedCause.tap,
        );
    await tester.pump();
    await tester.enterText(field, '   ');
    await tester.enterText(field, '');
    await tester.pump(const Duration(seconds: 1));

    expect(reported, [true, true, false, false]);
  });

  testWidgets('a stored draft arriving is not somebody typing', (tester) async {
    final reported = <bool>[];
    await _pump(tester, onTyping: reported.add, initialDraft: 'left here');
    await tester.pump(const Duration(seconds: 1));

    expect(reported, isEmpty);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required ValueChanged<bool> onTyping,
  String? initialDraft,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: ChatConversationView(
        model: ChatTimelineViewModel(
          state: ChatTimelineLoadState.empty,
          conversationId: 'conversation',
          title: 'Peer',
          savedMessages: false,
          securityGate: ChatSecurityGate.ready,
          offline: false,
          hasMoreBefore: false,
          loadingBefore: false,
          olderLoadFailed: false,
          typing: false,
          pinnedMessages: const [],
          messages: const [],
        ),
        initialDraft: initialDraft,
        onIntent: (intent) {
          if (intent case ComposerTextChangedIntent(:final hasText)) {
            onTyping(hasText);
          }
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}
