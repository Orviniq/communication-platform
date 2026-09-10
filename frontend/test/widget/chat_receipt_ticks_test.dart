import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

/// What the second tick is allowed to mean.
///
/// A reader who has used any other messenger arrives knowing that two ticks
/// means somebody read what they sent, and they will not re-learn it here. The
/// application used to draw two ticks for *delivered*, which a recipient's
/// device sends by itself the moment it stores the message — so a sender was
/// told their message had been seen while the other person was still on the
/// chat list and had not opened anything. These pin the vocabulary that fixed
/// it: arrival is one tick, reading is two, and nothing else draws two.
void main() {
  test('only the read state is allowed the second tick', () {
    expect(AppIcons.read.icon, FLucideIcons.checkCheck);
    expect(AppIcons.delivered.icon, isNot(FLucideIcons.checkCheck));
    expect(AppIcons.accepted.icon, isNot(FLucideIcons.checkCheck));
  });

  testWidgets('a delivered message does not claim it was seen', (tester) async {
    await _pump(tester, ChatDeliveryViewState.delivered);
    expect(_glyph(tester), isNot(FLucideIcons.checkCheck));
  });

  testWidgets('a message accepted by the relay does not either', (
    tester,
  ) async {
    await _pump(tester, ChatDeliveryViewState.accepted);
    expect(_glyph(tester), isNot(FLucideIcons.checkCheck));
  });

  testWidgets('a read message is the one that draws two ticks', (tester) async {
    await _pump(tester, ChatDeliveryViewState.read);
    expect(_glyph(tester), FLucideIcons.checkCheck);
  });

  testWidgets('each state still says which one it is', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, ChatDeliveryViewState.delivered);
    expect(
      find.bySemanticsLabel(
        RegExp(RegExp.escape('durably delivered to a recipient device')),
      ),
      findsWidgets,
      reason: 'the two arrival states share a glyph, so the label carries them',
    );

    await _pump(tester, ChatDeliveryViewState.read);
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape('read receipt received'))),
      findsWidgets,
    );
    semantics.dispose();
  });
}

/// The glyph the one outgoing message on screen draws for its delivery state.
IconData _glyph(WidgetTester tester) {
  final icons = tester
      .widgetList<AppIcon>(find.byType(AppIcon))
      .where(
        (icon) => const {
          'accepted',
          'delivered',
          'read',
        }.contains(icon.data.debugName),
      )
      .toList(growable: false);
  expect(icons, hasLength(1), reason: 'one outgoing message, one indicator');
  return icons.single.data.icon;
}

Future<void> _pump(WidgetTester tester, ChatDeliveryViewState delivery) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: ChatConversationView(model: _model(delivery), onIntent: (_) {}),
    ),
  );
  await tester.pumpAndSettle();
}

ChatTimelineViewModel _model(ChatDeliveryViewState delivery) =>
    ChatTimelineViewModel(
      state: ChatTimelineLoadState.data,
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
      messages: [
        ChatMessageViewModel(
          id: '0'.padLeft(32, '0'),
          authorId: 'self',
          authorName: 'You',
          outgoing: true,
          kind: ChatTimelineContentKind.text,
          text: 'one outgoing message',
          timestamp: DateTime(2026, 9, 10, 10),
          delivery: delivery,
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
          replyToMessageId: null,
          replyAuthor: null,
          replyQuote: null,
          reactions: const [],
        ),
      ],
    );
