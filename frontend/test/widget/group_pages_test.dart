import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/create_group_page.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/system_insets.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';

void main() {
  testWidgets('create flow remains usable at narrow RTL and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      CreateGroupPage(
        injectedContacts: const [
          GroupPickerContact(userId: _member, name: 'مریم', verified: true),
        ],
        onCreate: (_, _) async => Result.success(_state()),
      ),
      locale: const Locale('fa'),
      textScaler: const TextScaler.linear(2),
    );

    expect(
      Directionality.of(tester.element(find.byType(Scaffold))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
    final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(memberPicker);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
    await tester.tap(find.byKey(const ValueKey('group-next')));
    await tester.pumpAndSettle();

    expect(find.text('مشخصات گروه'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-name-field')), findsOneWidget);
    // At this width and text size the cost notice pushes Create below the
    // fold; usable means it is still reachable.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('group-create')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('group-fanout-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-create')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin sees removal but never owner-only role actions', (
    tester,
  ) async {
    await _pump(
      tester,
      GroupInfoPage(
        groupId: _groupId,
        injectedState: _state(),
        currentUserId: _admin,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    final memberRow = find.byKey(const ValueKey('group-member-$_member'));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(memberRow);
    await tester.pumpAndSettle();
    expect(find.text('Remove from group'), findsOneWidget);
    expect(find.text('Make admin'), findsNothing);
    expect(find.text('Transfer ownership'), findsNothing);
  });

  // The rule is written once, in `app_modals.dart`, and proved on the two
  // sheet functions in `sheet_insets_test.dart`. The owner's view of a member
  // is the longest this sheet gets: four buttons.
  testWidgets("the owner's member sheet keeps its last button above the "
      'gesture bar', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    fakeSystemInsets(tester);
    await _pump(
      tester,
      GroupInfoPage(
        groupId: _groupId,
        injectedState: _state(),
        currentUserId: _owner,
        onMutate: (_) async => Result.success(_state()),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-member-$_member')));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('app-sheet-surface'));
    expect(tester.getRect(surface).bottom, 800);
    expect(
      tester
          .getRect(find.widgetWithText(AppButton, 'Transfer ownership'))
          .bottom,
      closeTo(800 - 48 - 24, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed group stays readable while composer is withheld', (
    tester,
  ) async {
    final removed = _state(lifecycle: GroupLifecycle.removed);
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: removed,
        injectedMessages: [
          _message(
            '11111111111111111111111111111111',
            sender: _owner,
            text: 'Past message remains readable',
          ),
        ],
        currentUserId: _member,
        onSend: (_, {replyToMessageId, quoteFallback}) async =>
            throw StateError('composer must be disabled'),
      ),
    );

    expect(find.text('Past message remains readable'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer-field')), findsNothing);
    expect(find.textContaining('read-only'), findsWidgets);
  });

  testWidgets('the group paperclip opens the sheet that says attachments '
      'are not built for a group', (tester) async {
    // It used to do nothing at all: the page handled send and retry, and
    // dropped every other intent (ADR-089 D1).
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_, {replyToMessageId, quoteFallback}) async =>
            const Result.success(null),
      ),
    );

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('app-sheet-surface')),
        matching: find.byType(AttachmentSheet),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Group chats cannot send files yet. Files can be sent in direct '
        'chats and in Saved Messages.',
      ),
      findsOneWidget,
    );
    expect(find.text('Not built yet'), findsOneWidget);
    expect(find.text('Photo or image'), findsNothing);
  });

  testWidgets('wide group chat exposes a bounded information panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_, {replyToMessageId, quoteFallback}) async =>
            const Result.success(null),
      ),
    );

    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(find.text('Private Team'), findsWidgets);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending a group message leaves the composer, its focus and the '
      'keyboard where they were', (tester) async {
    // The send is held open on purpose. The composer used to be swapped for a
    // progress bar for as long as `onSend` took, and a text field that leaves
    // the tree takes the keyboard with it.
    final finished = Completer<Result<void>>();
    final sent = <String>[];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (text, {replyToMessageId, quoteFallback}) {
          sent.add(text);
          return finished.future;
        },
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'Keep typing');
    await tester.pump();
    final focus = tester.widget<TextField>(field).focusNode!;
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(_sendButton);
    await tester.pump();

    expect(sent, ['Keep typing']);
    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    finished.complete(const Result.success(null));
    await tester.pumpAndSettle();

    expect(find.byType(ChatComposerBuilder), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('a group send that is refused says so and keeps the composer', (
    tester,
  ) async {
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_, {replyToMessageId, quoteFallback}) async =>
            const Result.failure(
              SecurityFailure(SecurityFailureKind.policyBlocked),
            ),
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'Not allowed');
    await tester.pump();
    await tester.tap(_sendButton);
    await tester.pumpAndSettle();

    expect(
      find.text('The message was not saved. Nothing was sent.'),
      findsOneWidget,
    );
    expect(find.byType(ChatComposerBuilder), findsOneWidget);
  });

  testWidgets('a send that succeeds does not hide an earlier one that failed', (
    tester,
  ) async {
    // Two sends can now be in flight at once, because the composer stays. The
    // one that ends last must not decide whether the failure of the other is
    // still on screen.
    final first = Completer<Result<void>>();
    final second = Completer<Result<void>>();
    final answers = [first, second];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: const [],
        currentUserId: _owner,
        onSend: (_, {replyToMessageId, quoteFallback}) =>
            answers.removeAt(0).future,
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    for (final text in ['First', 'Second']) {
      await tester.enterText(field, text);
      await tester.pump();
      await tester.tap(_sendButton);
      await tester.pump();
    }

    first.complete(
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked)),
    );
    await tester.pump();
    second.complete(const Result.success(null));
    await tester.pumpAndSettle();

    expect(
      find.text('The message was not saved. Nothing was sent.'),
      findsOneWidget,
    );
  });

  testWidgets('a group message is not accepted before its last copy, and its '
      'bubble keeps its width until then', (tester) async {
    const messageId = '22222222222222222222222222222222';
    // A word short enough that the row under it, the time and the mark, is
    // what sizes the bubble. Anything added to that row while the message is
    // on its way shows as a wider bubble that narrows again once it is sent.
    Future<double> bubbleWidth(MessageTransportState transport) async {
      await _pump(
        tester,
        GroupChatPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMessages: [
            _message(
              messageId,
              sender: _owner,
              text: 'Hi',
              transport: transport,
            ),
          ],
          currentUserId: _owner,
          onSend: (_, {replyToMessageId, quoteFallback}) async =>
              const Result.success(null),
        ),
      );
      return tester
          .getSize(find.byKey(const ValueKey('message-$messageId')))
          .width;
    }

    final queued = await bubbleWidth(MessageTransportState.queued);
    expect(find.byTooltip('queued offline'), findsOneWidget);

    // The server holds some copies and not others.
    final sending = await bubbleWidth(MessageTransportState.partiallyAccepted);
    expect(find.byTooltip('sending to server'), findsOneWidget);
    expect(find.byTooltip('accepted by server relay'), findsNothing);

    final sent = await bubbleWidth(MessageTransportState.relayAccepted);
    expect(find.byTooltip('accepted by server relay'), findsOneWidget);

    expect(queued, sent);
    expect(sending, sent);
  });

  testWidgets('a failed group send retries that same message', (tester) async {
    const messageId = '33333333333333333333333333333333';
    final retried = <(String, String)>[];
    await _pump(
      tester,
      GroupChatPage(
        groupId: _groupId,
        injectedState: _state(),
        injectedMessages: [
          _message(
            messageId,
            sender: _owner,
            text: 'Not everyone has this yet',
            transport: MessageTransportState.permanentlyFailed,
          ),
        ],
        currentUserId: _owner,
        onSend: (_, {replyToMessageId, quoteFallback}) async =>
            const Result.success(null),
        onRetry: (messageId, text, {replyToMessageId, quoteFallback}) async {
          retried.add((messageId, text));
          return const Result.success(null);
        },
      ),
    );

    await tester.tap(find.text('Retry as a new encrypted send'));
    // The bubble's double-tap recognizer holds the arena before a tap wins.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(retried, [(messageId, 'Not everyone has this yet')]);
  });

  group('two ticks on an own group message (ADR-091 D1)', () {
    const messageId = '77777777777777777777777777777777';

    Future<void> pumpOne(WidgetTester tester, ConversationMessage message) =>
        _pump(
          tester,
          GroupChatPage(
            groupId: _groupId,
            injectedState: _state(),
            injectedMessages: [message],
            currentUserId: _owner,
            onSend: (_, {replyToMessageId, quoteFallback}) async =>
                const Result.success(null),
            onRetry:
                (messageId, text, {replyToMessageId, quoteFallback}) async =>
                    const Result.success(null),
          ),
        );

    /// The marks in the bubble of [messageId] drawn with [icon].
    Finder mark(AppIconData icon) => find.descendant(
      of: find.byKey(const ValueKey('message-$messageId')),
      matching: find.byWidgetPredicate(
        (widget) => widget is AppIcon && widget.data == icon,
      ),
    );

    testWidgets('a message one member read shows two ticks while a copy is '
        'still owed', (tester) async {
      await pumpOne(
        tester,
        _message(
          messageId,
          sender: _owner,
          text: 'Hi',
          transport: MessageTransportState.partiallyAccepted,
          receipt: MessageReceiptState.read,
        ),
      );

      expect(mark(AppIcons.read), findsOneWidget);
      expect(mark(AppIcons.clock), findsNothing);
      expect(find.byTooltip('read receipt received'), findsOneWidget);
    });

    testWidgets('a failed message a member read keeps its failed mark and '
        'Retry', (tester) async {
      await pumpOne(
        tester,
        _message(
          messageId,
          sender: _owner,
          text: 'Not everyone has this yet',
          transport: MessageTransportState.permanentlyFailed,
          receipt: MessageReceiptState.read,
        ),
      );

      expect(mark(AppIcons.error), findsOneWidget);
      expect(mark(AppIcons.read), findsNothing);
      expect(find.text('Retry as a new encrypted send'), findsOneWidget);
    });

    testWidgets('a delivered state shows the mark of the transport', (
      tester,
    ) async {
      await pumpOne(
        tester,
        _message(
          messageId,
          sender: _owner,
          text: 'Hi',
          transport: MessageTransportState.partiallyAccepted,
          receipt: MessageReceiptState.delivered,
        ),
      );

      expect(mark(AppIcons.clock), findsOneWidget);
      expect(mark(AppIcons.delivered), findsNothing);
    });

    testWidgets('a message from another member shows no tick', (tester) async {
      await pumpOne(
        tester,
        _message(
          messageId,
          sender: _member,
          text: 'Hi',
          receipt: MessageReceiptState.read,
        ),
      );

      for (final tick in [
        AppIcons.accepted,
        AppIcons.delivered,
        AppIcons.read,
      ]) {
        expect(mark(tick), findsNothing);
      }
    });
  });

  group('a group message shows what a direct message shows (ADR-090)', () {
    testWidgets('a reply quotes the name of the member who wrote the replied '
        'message', (tester) async {
      await _pumpThread(tester);

      final reply = find.byKey(const ValueKey('message-$_answerId'));
      expect(
        find.descendant(of: reply, matching: find.text('Admin')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: reply, matching: find.text('Original question')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: reply, matching: find.text('Replied message')),
        findsNothing,
      );
    });

    testWidgets('reactions show their chips', (tester) async {
      await _pumpThread(tester);

      expect(find.text('\u{1F44D} 2'), findsOneWidget);
    });

    testWidgets('an edited message shows its edited label', (tester) async {
      await _pumpThread(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-$_answerId')),
          matching: find.text('edited'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-$_questionId')),
          matching: find.text('edited'),
        ),
        findsNothing,
      );
    });

    testWidgets('a starred message shows its star', (tester) async {
      await _pumpThread(tester);

      Finder star(String messageId) => find.descendant(
        of: find.byKey(ValueKey('message-$messageId')),
        matching: find.byWidgetPredicate(
          (widget) => widget is AppIcon && widget.data == AppIcons.star,
        ),
      );
      expect(star(_answerId), findsOneWidget);
      expect(star(_questionId), findsNothing);
    });

    testWidgets('the message sheet offers no Pin and no Edit, even on an own '
        'message', (tester) async {
      await _pumpThread(tester);

      await _openActions(tester, _ownId);

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Star on this device'), findsOneWidget);
      expect(find.text('Pin'), findsNothing);
      expect(find.text('Unpin'), findsNothing);
      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('the delete dialog offers no Delete for everyone', (
      tester,
    ) async {
      await _pumpThread(tester);

      await _openActions(tester, _ownId);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsNothing);
    });

    testWidgets('a tap on a search result highlights that message', (
      tester,
    ) async {
      await _pumpThread(tester);
      double border(String messageId) =>
          ((tester
                              .widget<AnimatedContainer>(
                                find.byKey(ValueKey('message-$messageId')),
                              )
                              .decoration!
                          as BoxDecoration)
                      .border!
                  as Border)
              .top
              .width;
      expect(border(_questionId), 1);

      await tester.tap(find.byTooltip('Search in chat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        'question',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('conversation-search-hit-$_questionId')),
      );
      await tester.pumpAndSettle();

      expect(border(_questionId), 3);
      expect(border(_answerId), 1);
    });
  });

  group(
    'a group message can be replied to and reacted to (ADR-090 D2, D3)',
    () {
      testWidgets('a reply reaches the send path with the replied message and '
          'its quote', (tester) async {
        final sent = <(String, String?, String?)>[];
        await _pumpThread(
          tester,
          onSend: (text, {replyToMessageId, quoteFallback}) async {
            sent.add((text, replyToMessageId, quoteFallback));
            return const Result.success(null);
          },
        );

        await _openActions(tester, _questionId);
        await tester.tap(find.text('Reply').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer-field')),
          'My answer',
        );
        await tester.pump();
        await tester.tap(_sendButton);
        await tester.pumpAndSettle();

        expect(sent, [('My answer', _questionId, 'Original question')]);
      });

      testWidgets('a plain message carries no reply', (tester) async {
        final sent = <(String, String?, String?)>[];
        await _pumpThread(
          tester,
          onSend: (text, {replyToMessageId, quoteFallback}) async {
            sent.add((text, replyToMessageId, quoteFallback));
            return const Result.success(null);
          },
        );

        await tester.enterText(
          find.byKey(const ValueKey('chat-composer-field')),
          'Hello',
        );
        await tester.pump();
        await tester.tap(_sendButton);
        await tester.pumpAndSettle();

        expect(sent, [('Hello', null, null)]);
      });

      testWidgets('a failed reply retries with its reference and its quote', (
        tester,
      ) async {
        const failedId = '77777777777777777777777777777777';
        final retried = <(String, String, String?, String?)>[];
        await _pump(
          tester,
          GroupChatPage(
            groupId: _groupId,
            injectedState: _state(),
            injectedMessages: [
              _message(_questionId, sender: _admin, text: 'Original question'),
              _message(
                failedId,
                sender: _owner,
                text: 'My answer',
                at: 200,
                replyTo: _questionId,
                transport: MessageTransportState.permanentlyFailed,
              ),
            ],
            currentUserId: _owner,
            onSend: (_, {replyToMessageId, quoteFallback}) async =>
                const Result.success(null),
            onRetry:
                (messageId, text, {replyToMessageId, quoteFallback}) async {
                  retried.add((
                    messageId,
                    text,
                    replyToMessageId,
                    quoteFallback,
                  ));
                  return const Result.success(null);
                },
          ),
        );

        await tester.tap(find.text('Retry as a new encrypted send'));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();

        expect(retried, [
          (failedId, 'My answer', _questionId, 'Original question'),
        ]);
      });

      testWidgets('a reaction from the selector reaches the use case with its '
          'emoji', (tester) async {
        final semantics = tester.ensureSemantics();
        final reacted = <(String, String?)>[];
        await _pumpThread(
          tester,
          onReaction: (messageId, emoji) async {
            reacted.add((messageId, emoji));
            return const Result.success(null);
          },
        );

        await _openActions(tester, _questionId);
        await tester.tap(find.bySemanticsLabel('React with \u{1F525}'));
        await tester.pumpAndSettle();

        expect(reacted, [(_questionId, '\u{1F525}')]);
        semantics.dispose();
      });

      testWidgets('a double tap reaches the use case with a thumbs up', (
        tester,
      ) async {
        final reacted = <(String, String?)>[];
        await _pumpThread(
          tester,
          onReaction: (messageId, emoji) async {
            reacted.add((messageId, emoji));
            return const Result.success(null);
          },
        );

        // The question's own bubble: the answer quotes the same words.
        final question = find.descendant(
          of: find.byKey(const ValueKey('message-$_questionId')),
          matching: find.text('Original question'),
        );
        await tester.tap(question);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(question);
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(reacted, [(_questionId, '\u{1F44D}')]);
      });

      testWidgets('a tap on your own reaction chip removes the reaction', (
        tester,
      ) async {
        final reacted = <(String, String?)>[];
        await _pumpThread(
          tester,
          onReaction: (messageId, emoji) async {
            reacted.add((messageId, emoji));
            return const Result.success(null);
          },
        );

        // Owner, the current user, is one of the two who reacted.
        await tester.tap(find.text('\u{1F44D} 2'));
        // The bubble's double-tap recognizer holds the arena before a tap wins.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(reacted, [(_answerId, null)]);
      });

      testWidgets('a refused reaction says the action could not be completed', (
        tester,
      ) async {
        await _pumpThread(
          tester,
          onReaction: (messageId, emoji) async => const Result.failure(
            SecurityFailure(SecurityFailureKind.policyBlocked),
          ),
        );
        const message =
            'That action could not be completed. '
            'No security guarantee was weakened.';
        expect(find.text(message), findsNothing);

        await tester.tap(find.text('\u{1F44D} 2'));
        // The bubble's double-tap recognizer holds the arena before a tap wins.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(find.text(message), findsOneWidget);
      });

      testWidgets('a reaction on a page with no reaction path is reported as '
          'failed, never as made', (tester) async {
        await _pumpThread(tester);

        await tester.tap(find.text('\u{1F44D} 2'));
        // The bubble's double-tap recognizer holds the arena before a tap wins.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'That action could not be completed. '
            'No security guarantee was weakened.',
          ),
          findsOneWidget,
        );
      });
    },
  );

  testWidgets('group details say what one message costs', (tester) async {
    await _pump(
      tester,
      CreateGroupPage(
        injectedContacts: const [
          GroupPickerContact(userId: _member, name: 'Member', verified: true),
        ],
        onCreate: (_, _) async => Result.success(_state()),
      ),
    );
    final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
    await tester.ensureVisible(memberPicker);
    await tester.tap(memberPicker);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
    await tester.tap(find.byKey(const ValueKey('group-next')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-fanout-notice')), findsOneWidget);
    expect(find.textContaining('about 150 copies'), findsOneWidget);
  });

  group('back from a group never leaves the application', () {
    testWidgets('a new group opens above the Chats list, and back returns to '
        'the list', (tester) async {
      final router = await _pumpGroupRoutes(tester, '/chats/new');
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();

      final memberPicker = find.byKey(const ValueKey('group-picker-$_member'));
      await tester.ensureVisible(memberPicker);
      await tester.tap(memberPicker);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
      await tester.tap(find.byKey(const ValueKey('group-next')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('group-name-field')),
          matching: find.byType(EditableText),
        ),
        'Private Team',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('group-create')));
      await tester.tap(find.byKey(const ValueKey('group-create')));
      await tester.pumpAndSettle();
      expect(find.text('Group chat $_groupId'), findsOneWidget);

      // Nothing of the steps that made it is left between the chat and the
      // list.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Chats list'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });

    testWidgets('Search on Group Info returns to the conversation below it', (
      tester,
    ) async {
      final router = await _pumpGroupRoutes(tester, '/chats');
      unawaited(router.push('/groups/$_groupId'));
      await tester.pumpAndSettle();
      unawaited(router.push('/groups/$_groupId/info'));
      await tester.pumpAndSettle();

      final search = find.byKey(const ValueKey('group-info-search'));
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(find.text('Group chat $_groupId'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Chats list'), findsOneWidget);
    });
  });
}

/// The routes around a group as the application lays them out: the Chats
/// list in a shell branch with New above it on the root navigator, and the
/// group routes outside the shell.
Future<GoRouter> _pumpGroupRoutes(
  WidgetTester tester,
  String initialLocation,
) async {
  final root = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: root,
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chats',
                builder: (context, state) =>
                    const Scaffold(body: Center(child: Text('Chats list'))),
                routes: [
                  GoRoute(
                    path: 'new',
                    parentNavigatorKey: root,
                    builder: (context, state) => Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () => context.push('/groups/new'),
                          child: const Text('New group'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/groups/new',
        builder: (context, state) => CreateGroupPage(
          injectedContacts: const [
            GroupPickerContact(userId: _member, name: 'Member', verified: true),
          ],
          onCreate: (_, _) async => Result.success(_state()),
        ),
      ),
      GoRoute(
        path: '/groups/:groupId',
        builder: (context, state) => Scaffold(
          body: Center(
            child: Text('Group chat ${state.pathParameters['groupId']}'),
          ),
        ),
        routes: [
          GoRoute(
            path: 'info',
            builder: (context, state) => GroupInfoPage(
              groupId: _groupId,
              injectedState: _state(),
              currentUserId: _owner,
              onMutate: (_) async => Result.success(_state()),
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
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

GroupState _state({GroupLifecycle lifecycle = GroupLifecycle.active}) =>
    GroupState(
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
        GroupMember(
          userId: _admin,
          displayName: 'Admin',
          role: GroupRole.admin,
          verified: true,
        ),
        GroupMember(
          userId: _member,
          displayName: 'Member',
          role: GroupRole.member,
          membership: lifecycle == GroupLifecycle.removed
              ? GroupMembershipState.removed
              : GroupMembershipState.active,
        ),
      ],
      controlRevision: 1,
      controlStateHash:
          '1010101010101010101010101010101010101010101010101010101010101010',
      lifecycle: lifecycle,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  AppEnvironment environment = AppEnvironment.development,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appEnvironmentProvider.overrideWithValue(environment)],
      child: MaterialApp(
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, appChild) => AppDesignSystem(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: appChild ?? const SizedBox.shrink(),
          ),
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _questionId = '44444444444444444444444444444444';
const _answerId = '55555555555555555555555555555555';
const _ownId = '66666666666666666666666666666666';

/// A short thread: a question from Admin, Member's edited and starred answer
/// with two reactions, and a message of the current user, Owner.
Future<void> _pumpThread(
  WidgetTester tester, {
  SendGroupMessageCallback? onSend,
  SetGroupReactionCallback? onReaction,
}) => _pump(
  tester,
  GroupChatPage(
    groupId: _groupId,
    injectedState: _state(),
    injectedMessages: [
      _message(_questionId, sender: _admin, text: 'Original question', at: 100),
      _message(
        _answerId,
        sender: _member,
        text: 'An answer',
        at: 200,
        replyTo: _questionId,
        edited: true,
        starred: true,
        reactions: const [
          MessageReaction(reactingUserId: _owner, emoji: '\u{1F44D}'),
          MessageReaction(reactingUserId: _admin, emoji: '\u{1F44D}'),
        ],
      ),
      _message(
        _ownId,
        sender: _owner,
        text: 'Mine',
        at: 300,
        transport: MessageTransportState.relayAccepted,
      ),
    ],
    currentUserId: _owner,
    onSend:
        onSend ??
        (_, {replyToMessageId, quoteFallback}) async =>
            const Result.success(null),
    onReaction: onReaction,
  ),
);

/// Opens the message sheet of one bubble.
Future<void> _openActions(WidgetTester tester, String messageId) async {
  await tester.tap(find.byKey(ValueKey('message-$messageId')));
  // The bubble's double-tap recognizer holds the arena before a tap wins.
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// One row of the group's conversation, as local storage hands it on.
ConversationMessage _message(
  String messageId, {
  required String sender,
  required String text,
  MessageTransportState transport = MessageTransportState.received,
  MessageReceiptState receipt = MessageReceiptState.none,
  int at = 100,
  String? replyTo,
  bool edited = false,
  bool starred = false,
  List<MessageReaction> reactions = const [],
}) => ConversationMessage(
  messageId: messageId,
  conversationId: _groupId,
  senderUserId: sender,
  senderDeviceId: 'device',
  text: text,
  replyToMessageId: replyTo,
  quoteFallback: null,
  createdMs: at,
  orderingMs: at,
  orderingEventId: messageId,
  timestampState: MessageTimestampState.plausible,
  revision: edited ? 1 : 0,
  edited: edited,
  deletedForEveryone: false,
  deletedForMe: false,
  pinned: false,
  starred: starred,
  unread: false,
  transportState: transport,
  receiptState: receipt,
  reactions: reactions,
);

/// Send, once the composer holds a draft to send.
final Finder _sendButton = find.byWidgetPredicate(
  (widget) =>
      widget is AppIconButton &&
      widget.icon == AppIcons.send &&
      widget.onPressed != null,
);
