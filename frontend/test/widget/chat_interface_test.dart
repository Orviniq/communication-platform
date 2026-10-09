import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_emoji_picker.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_message_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/chats_list_page.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/system_insets.dart';

void main() {
  testWidgets('renders every honest transport state with text semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final states = ChatDeliveryViewState.values;
    await _pump(
      tester,
      ChatConversationView(
        model: _model(
          messages: [
            for (var index = 0; index < states.length; index++)
              _message(
                index,
                delivery: states[index],
                text: 'state-${states[index].name}',
                outgoing: true,
              ),
          ],
        ),
        onIntent: (_) {},
      ),
    );

    for (final state in states.where(
      (state) => state != ChatDeliveryViewState.received,
    )) {
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape(_deliveryEnglishLabel(state))),
        ),
        findsWidgets,
      );
    }
    expect(find.text('state-failed'), findsOneWidget);
    expect(find.text('Retry as a new encrypted send'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('withholds composer for every blocking security condition', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final gate in ChatSecurityGate.values.where(
      (gate) =>
          gate != ChatSecurityGate.ready && gate != ChatSecurityGate.checking,
    )) {
      await _pump(
        tester,
        ChatConversationView(
          model: _model(securityGate: gate),
          onIntent: (_) {},
        ),
      );
      expect(
        find.byKey(const ValueKey('chat-composer-field')),
        findsNothing,
        reason: gate.name,
      );
      expect(
        find.bySemanticsLabel(RegExp('Messaging withheld')),
        findsWidgets,
        reason: gate.name,
      );
    }
    semantics.dispose();
  });

  testWidgets('holds the composer inert while the trust state is unread', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      ChatConversationView(
        model: _model(securityGate: ChatSecurityGate.checking),
        onIntent: (_) {},
      ),
    );
    // The composer keeps its place so opening a chat does not shuffle its
    // layout, and says nothing about the peer while nothing is known.
    final field = find.byKey(const ValueKey('chat-composer-field'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(find.bySemanticsLabel(RegExp('Messaging withheld')), findsNothing);
    semantics.dispose();
  });

  testWidgets('composer dispatches typed reply, edit, and send intents', (
    tester,
  ) async {
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    await _openMessageSurface(tester, find.text('message-5'));
    await tester.tap(find.text('Reply').last);
    await tester.pumpAndSettle();
    expect(find.text('Replying to Peer'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'reply body',
    );
    await tester.pump();
    expect(_sendButton, findsOneWidget);
    await tester.tap(_sendButton);
    await tester.pump();
    expect(intents.whereType<SendTextIntent>().last.replyToMessageId, _id(5));

    await _openMessageSurface(tester, find.text('message-4'));
    await tester.tap(find.text('Edit').last);
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'edited body',
    );
    await tester.pump();
    expect(_sendButton, findsOneWidget);
    await tester.tap(_sendButton);
    await tester.pumpAndSettle();
    expect(intents.whereType<EditMessageIntent>().last.messageId, _id(4));
  });

  testWidgets('message menu is keyboard reachable and exposes actions', (
    tester,
  ) async {
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: (_) {}),
    );
    final message = find.byKey(ValueKey('message-${_id(5)}'));
    final focus = find
        .descendant(of: message, matching: find.byType(Focus))
        .first;
    Focus.of(tester.element(focus)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Message actions'), findsWidgets);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // The selector opens with the sheet and inside the same route, which is
    // what puts it in the modal focus scope rather than behind it.
    expect(find.bySemanticsLabel('Choose a reaction'), findsOneWidget);
    expect(find.bySemanticsLabel('More emoji'), findsOneWidget);
    expect(
      find.descendant(
        of: find.bySemanticsLabel('Choose a reaction'),
        matching: find.byType(InkResponse),
      ),
      findsNWidgets(chatQuickReactions.length + 1),
    );
    // And Tab reaches it. This is the whole reason the panel is a sibling of
    // the sheet inside one route rather than an overlay entry above it: a modal
    // route traps focus in its own scope, and an entry outside the route would
    // be visible, tappable, and unreachable from the keyboard.
    var reached = false;
    for (var press = 0; press < 6 && !reached; press += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      (primaryFocus?.context as Element?)?.visitAncestorElements((ancestor) {
        final widget = ancestor.widget;
        if (widget is Semantics &&
            widget.properties.label == 'Choose a reaction') {
          reached = true;
          return false;
        }
        return true;
      });
    }
    expect(reached, isTrue, reason: 'Tab never landed inside the selector');
    // Nothing on this surface may send a fixed emoji any more.
    expect(find.text('React'), findsNothing);
  });

  testWidgets('the selector sets a reaction that is not the double-tap one', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    await _openMessageSurface(tester, find.text('message-4'));
    expect(find.bySemanticsLabel('Choose a reaction'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('React with 🔥'));
    await tester.pumpAndSettle();

    expect(
      intents.whereType<SetReactionIntent>().single,
      isA<SetReactionIntent>()
          .having((intent) => intent.messageId, 'messageId', _id(4))
          .having((intent) => intent.emoji, 'emoji', '🔥'),
    );
    // Choosing dismisses the surface it was chosen from.
    expect(find.bySemanticsLabel('Choose a reaction'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the selector removes the reaction this user already set', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    // message-5 carries this user's own thumbs up in the default fixture, so
    // the panel offers to take it away rather than to set it again.
    await _openMessageSurface(tester, find.text('message-5'));
    await tester.tap(find.bySemanticsLabel('Remove your 👍 reaction'));
    await tester.pumpAndSettle();

    expect(
      intents.whereType<SetReactionIntent>().single,
      isA<SetReactionIntent>()
          .having((intent) => intent.messageId, 'messageId', _id(5))
          .having((intent) => intent.emoji, 'emoji', isNull),
    );
    semantics.dispose();
  });

  testWidgets('the selector offers each reaction a tap action, and performing '
      'it sets or takes off the reaction', (tester) async {
    final semantics = tester.ensureSemantics();
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    // message-5 carries this user's own thumbs up in the default fixture.
    await _openMessageSurface(tester, find.text('message-5'));
    const remove = 'Remove your 👍 reaction';
    const fire = 'React with 🔥';
    expect(
      tester.getSemantics(find.bySemanticsLabel(remove)),
      isSemantics(
        label: remove,
        isButton: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(fire)),
      isSemantics(
        label: fire,
        isButton: true,
        isSelected: false,
        hasTapAction: true,
      ),
    );
    // One node announces each reaction, and none the control under it: the
    // panel holds one node with a tap action per control, the expand control
    // included, not a second for the InkResponse beneath each.
    for (final label in [remove, fire]) {
      expect(find.semantics.byLabel(label), findsOneWidget, reason: label);
    }
    expect(
      find.semantics.descendant(
        of: find.semantics.byLabel('Choose a reaction'),
        matching: find.semantics.byAction(SemanticsAction.tap),
      ),
      findsNWidgets(chatQuickReactions.length + 1),
    );

    // By the node's action, as a service that does not touch the screen
    // does it, not by a tap at its centre.
    tester.semantics.tap(find.semantics.byLabel(fire));
    await tester.pumpAndSettle();
    expect(
      intents.whereType<SetReactionIntent>().single,
      isA<SetReactionIntent>()
          .having((intent) => intent.messageId, 'messageId', _id(5))
          .having((intent) => intent.emoji, 'emoji', '🔥'),
    );
    expect(find.bySemanticsLabel('Choose a reaction'), findsNothing);

    intents.clear();
    await _openMessageSurface(tester, find.text('message-5'));
    tester.semantics.tap(find.semantics.byLabel(remove));
    await tester.pumpAndSettle();
    expect(
      intents.whereType<SetReactionIntent>().single,
      isA<SetReactionIntent>()
          .having((intent) => intent.messageId, 'messageId', _id(5))
          .having((intent) => intent.emoji, 'emoji', isNull),
    );
    semantics.dispose();
  });

  testWidgets(
    'a double tap sets and removes the default reaction, opening nothing',
    (tester) async {
      final intents = <ChatIntent>[];
      await _pump(
        tester,
        ChatConversationView(model: _model(), onIntent: intents.add),
      );
      intents.clear();

      await _doubleTap(tester, find.text('message-4'));
      expect(
        intents.whereType<SetReactionIntent>().single,
        isA<SetReactionIntent>()
            .having((intent) => intent.messageId, 'messageId', _id(4))
            .having((intent) => intent.emoji, 'emoji', '👍'),
      );
      expect(find.text('Reply'), findsNothing);
      expect(find.bySemanticsLabel('Choose a reaction'), findsNothing);

      intents.clear();
      await _doubleTap(tester, find.text('message-5'));
      expect(
        intents.whereType<SetReactionIntent>().single.emoji,
        isNull,
        reason:
            'a double tap on a message already carrying this user thumbs up '
            'takes it off',
      );
    },
  );

  testWidgets('the expand control opens the full picker and sets what it '
      'returns', (tester) async {
    final semantics = tester.ensureSemantics();
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    await _openMessageSurface(tester, find.text('message-4'));
    await tester.tap(find.bySemanticsLabel('More emoji'));
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPicker), findsOneWidget);

    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();

    expect(
      intents.whereType<SetReactionIntent>().single,
      isA<SetReactionIntent>()
          .having((intent) => intent.messageId, 'messageId', _id(4))
          .having((intent) => intent.emoji, 'emoji', '😀'),
    );
    expect(find.byType(AppEmojiPicker), findsNothing);
    expect(find.bySemanticsLabel('Choose a reaction'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the expand control offers a tap action, and performing it '
      'opens the full picker', (tester) async {
    final semantics = tester.ensureSemantics();
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    await _openMessageSurface(tester, find.text('message-4'));
    expect(
      tester.getSemantics(find.bySemanticsLabel('More emoji')),
      isSemantics(label: 'More emoji', isButton: true, hasTapAction: true),
    );
    // One node announces the control, and none the tooltip or the control
    // under it: the panel holds one node with a tap action per control.
    expect(find.semantics.byLabel('More emoji'), findsOneWidget);
    expect(
      find.semantics.descendant(
        of: find.semantics.byLabel('Choose a reaction'),
        matching: find.semantics.byAction(SemanticsAction.tap),
      ),
      findsNWidgets(chatQuickReactions.length + 1),
    );

    // By the node's action, as a service that does not touch the screen
    // does it, not by a tap at its centre.
    tester.semantics.tap(find.semantics.byLabel('More emoji'));
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPicker), findsOneWidget);
    expect(intents.whereType<SetReactionIntent>(), isEmpty);
    semantics.dispose();
  });

  testWidgets('a tap on a nested control belongs to that control', (
    tester,
  ) async {
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: intents.add),
    );
    intents.clear();

    // The reply quote on message-5 jumps; it does not open the message surface.
    // The quote repeats message-2's text, so the finder has to be scoped to the
    // bubble carrying it rather than to the text.
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('message-${_id(5)}')),
        matching: find.text('message-2'),
      ),
    );
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(intents.whereType<JumpToMessageIntent>(), isNotEmpty);
    expect(find.text('Reply'), findsNothing);

    // So does the reaction chip, which keeps the toggle it always had. It sits
    // on the newest message, whose chip row starts below the timeline viewport.
    intents.clear();
    final chip = find.text('👍 2');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(intents.whereType<SetReactionIntent>().single.emoji, isNull);
    expect(find.text('Reply'), findsNothing);
  });

  testWidgets('the failed-send retry button keeps its own tap', (tester) async {
    final intents = <ChatIntent>[];
    await _pump(
      tester,
      ChatConversationView(
        model: _model(
          messages: [
            _message(0, delivery: ChatDeliveryViewState.failed, outgoing: true),
          ],
        ),
        onIntent: intents.add,
      ),
    );
    intents.clear();

    await tester.tap(find.text('Retry as a new encrypted send'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(intents.whereType<RetryMessageIntent>(), isNotEmpty);
    expect(find.text('Reply'), findsNothing);
  });

  for (final size in const [
    Size(360, 800), // narrow
    Size(800, 900), // medium
    Size(1440, 900), // wide
  ]) {
    testWidgets('the selector and the picker lay out in Persian RTL at '
        '${size.width}', (tester) async {
      await _pump(
        tester,
        ChatConversationView(model: _model(), onIntent: (_) {}),
        size: size,
        locale: const Locale('fa'),
      );
      await _openMessageSurface(tester, find.text('message-4'));
      // Locale-independent finders: the panel is proved by a glyph only it
      // carries, and the expand control by its semantic icon, so this test
      // does not break the day the Persian wording is revised.
      expect(find.text('🔥'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final expand = find.byWidgetPredicate(
        (widget) => widget is AppIcon && identical(widget.data, AppIcons.add),
      );
      expect(expand, findsOneWidget);
      await tester.tap(expand);
      await tester.pumpAndSettle();

      expect(find.byType(AppEmojiPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<Directionality>(find.byType(Directionality).first)
            .textDirection,
        TextDirection.rtl,
      );
    });

    testWidgets('the inline composer panel lays out in Persian RTL at '
        '${size.width}', (tester) async {
      await _pump(
        tester,
        ChatConversationView(model: _model(), onIntent: (_) {}),
        size: size,
        locale: const Locale('fa'),
      );
      await tester.tap(_composerEmojiButton);
      await tester.pumpAndSettle();

      expect(find.byType(AppEmojiPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the emoji panel inserts at the caret and stays open', (
    tester,
  ) async {
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: (_) {}),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'ab');
    await tester.pump();
    tester.widget<TextField>(field).controller!.selection =
        const TextSelection.collapsed(offset: 1);
    await tester.pump();

    expect(find.byType(AppEmojiPicker), findsNothing);
    await tester.tap(find.bySemanticsLabel('Insert emoji').first);
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPicker), findsOneWidget);

    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();

    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, 'a😀b');
    expect(
      controller.selection,
      TextSelection.collapsed(offset: 1 + '😀'.length),
    );
    // The panel belongs to the composer, so one choice is not the end of the
    // visit. This is the whole difference from the sheet it replaced.
    expect(find.byType(AppEmojiPicker), findsOneWidget);

    await tester.tap(find.text('😃').first);
    await tester.pumpAndSettle();
    expect(controller.text, 'a😀😃b');

    await tester.tap(find.bySemanticsLabel('Close emoji panel').first);
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPicker), findsNothing);
    expect(controller.text, 'a😀😃b');
  });

  testWidgets('the back gesture closes the panel and leaves the draft alone', (
    tester,
  ) async {
    await _pump(
      tester,
      ChatConversationView(model: _model(), onIntent: (_) {}),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'draft worth keeping');
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Insert emoji').first);
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPicker), findsOneWidget);

    // The system back, which the panel answers before the route does.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AppEmojiPicker), findsNothing);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'draft worth keeping',
    );
  });

  testWidgets('a short message sizes the bubble and its reactions to what '
      'they hold', (tester) async {
    await _pump(
      tester,
      ChatConversationView(
        model: _model(
          messages: [
            _message(
              0,
              text: 'ok',
              reactions: const [
                ChatReactionViewModel(
                  emoji: '👍',
                  count: 1,
                  selectedByCurrentUser: false,
                ),
              ],
            ),
          ],
        ),
        onIntent: (_) {},
      ),
    );

    // 430 logical pixels is `_pump`'s default row. The bubble used to be
    // exactly 0.82 of it whatever the message said, which is what made a single
    // reaction chip look like it was floating in a full-width box.
    const rowWidth = 430.0;
    final bubbleWidth = tester
        .getSize(find.byKey(ValueKey('message-${_id(0)}')))
        .width;
    expect(bubbleWidth, lessThan(rowWidth * 0.82));

    final reactions = find
        .ancestor(of: find.text('👍 1'), matching: find.byType(Wrap))
        .first;
    expect(tester.getSize(reactions).width, lessThan(bubbleWidth));
  });

  testWidgets('reactions past the bubble width move to the next run', (
    tester,
  ) async {
    const emojis = [
      '👍',
      '👎',
      '❤️',
      '🔥',
      '🥰',
      '👏',
      '😁',
      '🤔',
      '🤯',
      '😱',
      '🎉',
      '💯',
    ];
    await _pump(
      tester,
      ChatConversationView(
        model: _model(
          messages: [
            _message(
              0,
              text: 'ok',
              reactions: [
                for (final emoji in emojis)
                  ChatReactionViewModel(
                    emoji: emoji,
                    count: 1,
                    selectedByCurrentUser: false,
                  ),
              ],
            ),
          ],
        ),
        onIntent: (_) {},
      ),
    );
    expect(tester.takeException(), isNull);

    final reactions = find
        .ancestor(of: find.text('👍 1'), matching: find.byType(Wrap))
        .first;
    final size = tester.getSize(reactions);
    // One chip is 32 high, so a taller row is a second run rather than an
    // overflow or a horizontal scroll.
    expect(size.height, greaterThan(32));
    expect(size.width, lessThanOrEqualTo(430.0 * 0.82));
  });

  testWidgets('forward picker dispatches immutable targets as a typed intent', (
    tester,
  ) async {
    final intents = <ChatIntent>[];
    var resolvedTargets = 0;
    await _pump(
      tester,
      ChatConversationView(
        model: _model(),
        forwardTargets: () {
          resolvedTargets += 1;
          return [
            ChatListItemViewModel(
              conversationId: '',
              title: 'Saved Messages',
              preview: '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
              unreadCount: 0,
              muted: false,
              pinned: false,
              savedMessages: true,
              peerUserId: null,
            ),
          ];
        },
        onIntent: intents.add,
      ),
    );
    intents.clear();
    // Showing a conversation does not cost a list of everywhere a message
    // could be forwarded to.
    expect(resolvedTargets, 0);

    await _openMessageSurface(tester, find.text('message-5'));
    await tester.tap(find.text('Forward').last);
    await tester.pumpAndSettle();
    expect(resolvedTargets, 1);
    await tester.tap(find.text('Saved Messages').last);
    await tester.pump();
    await tester.tap(find.text('Forward').last);
    await tester.pumpAndSettle();

    final forwarded = intents.whereType<ForwardToConversationsIntent>().single;
    expect(forwarded.message.id, _id(5));
    expect(forwarded.targets.single.savedMessages, isTrue);
  });

  testWidgets('upward pagination keeps the visible reading anchor', (
    tester,
  ) async {
    final allMessages = [
      for (var index = 0; index < 240; index++) _message(index),
    ];
    final page = ValueNotifier<List<ChatMessageViewModel>>(
      allMessages.sublist(210),
    );
    addTearDown(page.dispose);
    await _pump(
      tester,
      ValueListenableBuilder<List<ChatMessageViewModel>>(
        valueListenable: page,
        builder: (context, messages, _) => SizedBox(
          height: 620,
          child: ChatTimelineAdapter(
            model: _model(messages: messages),
            onIntent: (_) {},
            initialPageSize: 80,
          ),
        ),
      ),
    );
    final anchor = find.byKey(ValueKey('message-${_id(235)}'));
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;

    page.value = allMessages.sublist(180);
    await tester.pump();
    final after = tester.getTopLeft(anchor).dy;
    expect((after - before).abs(), lessThan(1.1));
  });

  testWidgets('edits, reactions, and resize preserve a reading anchor', (
    tester,
  ) async {
    final original = [for (var index = 0; index < 60; index++) _message(index)];
    final page = ValueNotifier<List<ChatMessageViewModel>>(original);
    addTearDown(page.dispose);
    await _pump(
      tester,
      ValueListenableBuilder<List<ChatMessageViewModel>>(
        valueListenable: page,
        builder: (context, messages, _) => ChatTimelineAdapter(
          model: _model(messages: messages),
          onIntent: (_) {},
        ),
      ),
    );
    await tester.drag(
      find.byKey(const PageStorageKey('chat-timeline')),
      // The timeline is reversed: dragging content toward the bottom moves the
      // reading position into older history.
      const Offset(0, 900),
    );
    await tester.pumpAndSettle();

    final visible = tester
        .widgetList<ChatMessageBuilder>(find.byType(ChatMessageBuilder))
        .where((builder) {
          final finder = find.byKey(ValueKey('message-${builder.message.id}'));
          if (finder.evaluate().isEmpty) return false;
          final y = tester.getTopLeft(finder).dy;
          return y > 80 && y < 680;
        })
        .first;
    final anchor = find.byKey(ValueKey('message-${visible.message.id}'));
    final before = tester.getTopLeft(anchor).dy;

    page.value = [
      ...original.take(59),
      _message(
        59,
        text: List.filled(20, 'expanded edit').join(' '),
        edited: true,
        reactions: const [
          ChatReactionViewModel(
            emoji: '👍',
            count: 12,
            selectedByCurrentUser: false,
          ),
        ],
      ),
    ];
    await tester.pump();
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1.1));

    tester.view.physicalSize = const Size(600, 900);
    await tester.pump();
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1.1));
  });

  testWidgets('50,000-message fixture keeps mounted widgets bounded', (
    tester,
  ) async {
    final stopwatch = Stopwatch()..start();
    final messages = [
      for (var index = 0; index < 50000; index++) _message(index),
    ];
    await _pump(
      tester,
      ChatTimelineAdapter(
        model: _model(messages: messages),
        onIntent: (_) {},
      ),
      settle: false,
    );
    await tester.pump();
    stopwatch.stop();

    expect(find.byType(ChatMessageBuilder), findsWidgets);
    expect(
      tester
          .widgetList<ChatMessageBuilder>(find.byType(ChatMessageBuilder))
          .length,
      lessThan(40),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  for (final scenario in <_Scenario>[
    const _Scenario('narrow English', Size(360, 800)),
    const _Scenario('medium Persian', Size(800, 900), locale: Locale('fa')),
    const _Scenario('wide dark', Size(1440, 900), themeMode: ThemeMode.dark),
    const _Scenario('narrow high contrast', Size(390, 844), highContrast: true),
    const _Scenario(
      'large text reduced motion',
      Size(430, 900),
      textScale: 2,
      reducedMotion: true,
    ),
  ]) {
    testWidgets('${scenario.name} remains usable without overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        ChatConversationView(model: _model(), onIntent: (_) {}),
        size: scenario.size,
        locale: scenario.locale,
        themeMode: scenario.themeMode,
        highContrast: scenario.highContrast,
        textScale: scenario.textScale,
        reducedMotion: scenario.reducedMotion,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('direct-chat-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-composer-field')), findsOneWidget);
      final direction = tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection;
      expect(
        direction,
        scenario.locale.languageCode == 'fa'
            ? TextDirection.rtl
            : TextDirection.ltr,
      );
    });
  }

  testWidgets('Saved Messages has no peer presence or receipt promise', (
    tester,
  ) async {
    await _pump(
      tester,
      SavedMessagesPage(
        injectedModel: _model(savedMessages: true),
        onIntent: (_) {},
      ),
    );
    expect(find.text('Saved Messages'), findsWidgets);
    expect(find.textContaining('online via'), findsNothing);
    expect(find.textContaining('typing'), findsNothing);
    expect(find.text('Write a note to yourself'), findsOneWidget);
  });

  testWidgets('Chats List exposes loading, empty, error and rows', (
    tester,
  ) async {
    await _pump(
      tester,
      ChatsListPage(
        model: ChatListViewModel(
          items: [
            ChatListItemViewModel(
              conversationId: 'conversation',
              title: 'Peer',
              preview: 'Last encrypted message',
              timestamp: DateTime(2026, 7, 30, 12),
              unreadCount: 3,
              muted: true,
              pinned: true,
              savedMessages: false,
              peerUserId: 'peer',
            ),
          ],
          loading: false,
          failed: false,
        ),
      ),
    );
    expect(find.text('Peer'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await _pump(
      tester,
      ChatsListPage(
        model: ChatListViewModel(
          items: const [],
          loading: false,
          failed: false,
        ),
      ),
    );
    expect(find.text('No chats yet'), findsOneWidget);

    await _pump(
      tester,
      ChatsListPage(
        model: ChatListViewModel(items: const [], loading: false, failed: true),
      ),
    );
    expect(find.text('Chats are unavailable'), findsOneWidget);
  });

  // The rule is written once, in `app_modals.dart`, and proved on the two
  // sheet functions in `sheet_insets_test.dart`; these are the sheets of a
  // conversation, opened the way a person opens them.
  group('sheets keep clear of the system insets and the keyboard', () {
    const phone = Size(430, 900);
    const gestureBar = 48.0;
    final surface = find.byKey(const ValueKey('app-sheet-surface'));

    // The last row, bottom edge to the screen's: the margin and the gesture bar.
    const restingBottom = 900 - gestureBar - AppSpacing.x6;

    /// The tile that carries [label], in a menu or an action sheet.
    Finder row(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(ListTile));

    Future<void> pumpConversation(
      WidgetTester tester, {
      Size size = phone,
      double textScale = 1,
      ChatTimelineViewModel? model,
    }) {
      fakeSystemInsets(tester);
      return _pump(
        tester,
        ChatConversationView(
          model: model ?? _model(),
          forwardTargets: () => [
            ChatListItemViewModel(
              conversationId: '',
              title: 'Saved Messages',
              preview: '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
              unreadCount: 0,
              muted: false,
              pinned: false,
              savedMessages: true,
              peerUserId: null,
            ),
          ],
          onIntent: (_) {},
        ),
        size: size,
        textScale: textScale,
      );
    }

    testWidgets('the message actions rest above the gesture bar', (
      tester,
    ) async {
      await pumpConversation(tester);

      await _openMessageSurface(tester, find.text('message-5'));

      expect(tester.getRect(surface).bottom, phone.height);
      expect(
        tester.getRect(row('Delete')).bottom,
        closeTo(restingBottom, 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the message actions scroll on a short screen at twice the '
        'text size, and the last row scrolls into view', (tester) async {
      // Nothing pinned, so no banner stands over the timeline at this size.
      await pumpConversation(
        tester,
        size: const Size(360, 640),
        textScale: 2,
        model: _model(messages: [for (var i = 0; i < 6; i++) _message(i)]),
      );

      await _openMessageSurface(tester, find.text('message-5'));

      final position = tester
          .state<ScrollableState>(
            find.descendant(of: surface, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getRect(row('Delete')).bottom,
        closeTo(640 - gestureBar - AppSpacing.x6, 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets("the conversation's menu rests above the gesture bar", (
      tester,
    ) async {
      await pumpConversation(tester);

      await tester.tap(find.byTooltip('More conversation actions'));
      await tester.pumpAndSettle();

      expect(tester.getRect(surface).bottom, phone.height);
      expect(
        tester.getRect(row('Clear history')).bottom,
        closeTo(restingBottom, 0.01),
      );
    });

    testWidgets('the pinned messages stay under the status bar and above the '
        'gesture bar', (tester) async {
      await pumpConversation(tester);

      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();

      final sheet = tester.getRect(surface);
      expect(sheet.bottom, phone.height);
      expect(sheet.top, greaterThanOrEqualTo(24));
      final list = find.descendant(
        of: surface,
        matching: find.byType(ListView),
      );
      expect(tester.getRect(list).bottom, lessThanOrEqualTo(restingBottom));
      expect(tester.takeException(), isNull);
    });

    for (final size in [phone, const Size(360, 640)]) {
      testWidgets('the emoji picker keeps its grid above the gesture bar at '
          '${size.width.round()} by ${size.height.round()}', (tester) async {
        await pumpConversation(tester, size: size);
        await _openMessageSurface(tester, find.text('message-5'));

        await tester.tap(find.bySemanticsLabel('More emoji'));
        await tester.pumpAndSettle();

        // The picker's sheet is the second of two: the actions are under it.
        final sheet = tester.getRect(surface.last);
        expect(sheet.bottom, size.height);
        expect(sheet.top, greaterThanOrEqualTo(24));
        expect(
          tester.getRect(find.byType(AppEmojiPicker)).bottom,
          closeTo(size.height - gestureBar - AppSpacing.x6, 0.01),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the forward picker keeps its button above the gesture bar', (
      tester,
    ) async {
      await pumpConversation(tester);

      await _openMessageSurface(tester, find.text('message-5'));
      await tester.tap(find.text('Forward').last);
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.widgetWithText(AppButton, 'Forward')).bottom,
        closeTo(restingBottom, 0.01),
      );
      expect(tester.getRect(surface).top, greaterThanOrEqualTo(24));
      expect(tester.takeException(), isNull);
    });
  });
}

/// The composer's emoji button, found by its icon rather than its wording so
/// the Persian run does not depend on the translation staying put. It is the
/// only place in the timeline that draws this icon.
final _composerEmojiButton = find.byWidgetPredicate(
  (widget) => widget is AppIcon && identical(widget.data, AppIcons.emoji),
);

/// Opens the message surface the way a person does: one tap on the bubble.
///
/// The wait is not padding. `onDoubleTap` holds the gesture arena for
/// `kDoubleTapTimeout` before a single tap can be awarded, and `pumpAndSettle`
/// advances 100 ms per frame only while something is animating - so on its own
/// it returns before the hold expires and nothing has happened yet.
Future<void> _openMessageSurface(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(target);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(430, 900),
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  bool highContrast = false,
  double textScale = 1,
  bool reducedMotion = false,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(
        highContrast: highContrast,
        disableAnimations: reducedMotion,
      );
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        theme: highContrast ? AppTheme.highContrastLight() : AppTheme.light(),
        darkTheme: highContrast ? AppTheme.highContrastDark() : AppTheme.dark(),
        themeMode: themeMode,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: child,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

ChatTimelineViewModel _model({
  Iterable<ChatMessageViewModel>? messages,
  ChatSecurityGate securityGate = ChatSecurityGate.ready,
  bool savedMessages = false,
}) {
  final source =
      messages ??
      [
        for (var index = 0; index < 6; index++)
          _message(
            index,
            outgoing: index.isEven,
            unread: index == 3,
            pinned: index == 2,
            edited: index == 4,
            reactions: index == 5
                ? const [
                    ChatReactionViewModel(
                      emoji: '👍',
                      count: 2,
                      selectedByCurrentUser: true,
                    ),
                  ]
                : const [],
            replyToMessageId: index == 5 ? _id(2) : null,
            replyQuote: index == 5 ? 'message-2' : null,
          ),
      ];
  final list = List<ChatMessageViewModel>.unmodifiable(source);
  return ChatTimelineViewModel(
    state: list.isEmpty
        ? ChatTimelineLoadState.empty
        : ChatTimelineLoadState.data,
    conversationId: 'conversation',
    title: savedMessages ? 'Saved Messages' : 'Peer',
    savedMessages: savedMessages,
    securityGate: securityGate,
    offline: false,
    hasMoreBefore: false,
    loadingBefore: false,
    olderLoadFailed: false,
    typing: false,
    pinnedMessages: [
      for (final message in list)
        if (message.pinned) message,
    ],
    messages: list,
  );
}

ChatMessageViewModel _message(
  int index, {
  ChatDeliveryViewState delivery = ChatDeliveryViewState.accepted,
  String? text,
  bool? outgoing,
  bool unread = false,
  bool pinned = false,
  bool edited = false,
  Iterable<ChatReactionViewModel> reactions = const [],
  String? replyToMessageId,
  String? replyQuote,
}) {
  final isOutgoing = outgoing ?? index.isEven;
  return ChatMessageViewModel(
    id: _id(index),
    authorId: isOutgoing ? 'self' : 'peer',
    authorName: isOutgoing ? 'You' : 'Peer',
    outgoing: isOutgoing,
    kind: ChatTimelineContentKind.text,
    text: text ?? 'message-$index',
    timestamp: DateTime(
      2026,
      7,
      30,
      10,
    ).add(Duration(minutes: math.min(index, 100000))),
    delivery: isOutgoing ? delivery : ChatDeliveryViewState.received,
    firstInAuthorGroup: true,
    lastInAuthorGroup: true,
    edited: edited,
    deleted: false,
    pinned: pinned,
    starred: false,
    unread: unread,
    timestampSkewed: false,
    canEdit: isOutgoing,
    canDeleteForEveryone: isOutgoing,
    replyToMessageId: replyToMessageId,
    replyAuthor: replyToMessageId == null ? null : 'Peer',
    replyQuote: replyQuote,
    reactions: reactions,
  );
}

String _id(int value) => value.toRadixString(16).padLeft(32, '0');

String _deliveryEnglishLabel(ChatDeliveryViewState state) => switch (state) {
  ChatDeliveryViewState.localOnly => 'saved locally only',
  ChatDeliveryViewState.queued => 'queued offline',
  ChatDeliveryViewState.encrypting => 'encrypting',
  ChatDeliveryViewState.sending => 'sending to server',
  ChatDeliveryViewState.accepted => 'accepted by server relay',
  ChatDeliveryViewState.delivered => 'durably delivered to a recipient device',
  ChatDeliveryViewState.read => 'read receipt received',
  ChatDeliveryViewState.failed => 'send failed',
  ChatDeliveryViewState.received => 'received',
};

final Finder _sendButton = find.byWidgetPredicate(
  (widget) =>
      widget is AppIconButton &&
      widget.icon == AppIcons.send &&
      widget.onPressed != null,
);

final class _Scenario {
  const _Scenario(
    this.name,
    this.size, {
    this.locale = const Locale('en'),
    this.themeMode = ThemeMode.light,
    this.highContrast = false,
    this.textScale = 1,
    this.reducedMotion = false,
  });

  final String name;
  final Size size;
  final Locale locale;
  final ThemeMode themeMode;
  final bool highContrast;
  final double textScale;
  final bool reducedMotion;
}
