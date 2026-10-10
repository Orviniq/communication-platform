import 'dart:async';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_emoji_picker.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatComposerBuilder extends StatefulWidget {
  const ChatComposerBuilder({
    required this.securityGate,
    required this.offline,
    required this.savedMessages,
    required this.onIntent,
    this.initialDraft,
    this.attachments = ChatAttachmentAvailability.notBuilt,
    super.key,
  });

  final ChatSecurityGate securityGate;
  final bool offline;
  final bool savedMessages;
  final String? initialDraft;
  final ChatIntentCallback onIntent;

  /// Whether attachments are available here. The paperclip sends
  /// [OpenAttachmentIntent] unless they are [ChatAttachmentAvailability.unavailable],
  /// and the conversation decides what the sheet offers.
  final ChatAttachmentAvailability attachments;

  @override
  State<ChatComposerBuilder> createState() => ChatComposerBuilderState();
}

class ChatComposerBuilderState extends State<ChatComposerBuilder>
    with WidgetsBindingObserver {
  /// How long the composer waits before writing a draft down.
  ///
  /// Long enough that an ordinary run of typing is one write rather than one
  /// per character, short enough that a pause is already saved before the user
  /// has decided to leave. It bounds how stale the stored draft can be only
  /// while the field is being typed into: every way out of the composer
  /// flushes first, so the debounce never decides what survives.
  static const draftDebounce = Duration(milliseconds: 500);

  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  ChatComposerMode _mode = ChatComposerMode.compose;
  ChatMessageViewModel? _contextMessage;
  bool _emojiPanelOpen = false;
  Timer? _draftTimer;

  /// The draft local storage is known to be holding.
  ///
  /// Kept so that a flush with nothing new to say writes nothing, which is
  /// what makes the flush safe to call from five places that can all happen at
  /// once — a blur, a pop and a lifecycle change arrive together when somebody
  /// swipes back out of a conversation.
  String? _persistedDraft;

  @override
  void initState() {
    super.initState();
    _persistedDraft = _draftOf(widget.initialDraft);
    _controller = TextEditingController(text: widget.initialDraft)
      ..addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant ChatComposerBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The stored draft is read once and can land a frame after the composer
    // has been built. Adopting it then is what lets that read be a one-shot
    // rather than a subscription the composer would be feeding its own
    // keystrokes back into; adopting it only into an untouched empty field is
    // what stops it overwriting anything typed since.
    if (widget.initialDraft != oldWidget.initialDraft &&
        oldWidget.initialDraft == null &&
        _controller.text.isEmpty) {
      _persistedDraft = _draftOf(widget.initialDraft);
      _controller.value = TextEditingValue(
        text: widget.initialDraft ?? '',
        selection: TextSelection.collapsed(
          offset: widget.initialDraft?.length ?? 0,
        ),
      );
    }
  }

  @override
  void dispose() {
    // Before the controller goes, because its text is what is being saved.
    _flushDraft();
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  /// The draft a field holds, or null when it holds nothing worth keeping.
  static String? _draftOf(String? text) =>
      text == null || text.trim().isEmpty ? null : text;

  /// Writes the draft down now, if it differs from what is already stored.
  ///
  /// Every exit from the composer runs through here: losing focus, the route
  /// popping, the application leaving the foreground, the widget being
  /// disposed, and sending. A debounce that dropped the last few characters
  /// when somebody backgrounded the application would be a worse bug than the
  /// writes it was introduced to remove.
  void _flushDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final draft = _draftOf(_controller.text);
    if (draft == _persistedDraft) return;
    _persistedDraft = draft;
    widget.onIntent(SaveDraftIntent(draft));
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _flushDraft();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flushDraft();
  }

  void handleIntent(ChatIntent intent) {
    switch (intent) {
      case ReplyToMessageIntent(:final message):
        setState(() {
          _mode = ChatComposerMode.reply;
          _contextMessage = message;
          _emojiPanelOpen = false;
        });
        _focusNode.requestFocus();
      case BeginEditMessageIntent(:final message):
        setState(() {
          _mode = ChatComposerMode.edit;
          _contextMessage = message;
          _controller.text = message.text ?? '';
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
          _emojiPanelOpen = false;
        });
        _focusNode.requestFocus();
      default:
        break;
    }
  }

  /// A keystroke costs a timer, and nothing else.
  ///
  /// It used to cost a `setState` and a write to the `conversations` row —
  /// which invalidated the conversation list, which rebuilt the page around
  /// this composer, which re-derived the whole loaded window. Typing twenty
  /// characters did that twenty times. The Send button's appearance is the
  /// only thing on this screen that follows the text, and it listens to the
  /// controller itself.
  void _onTextChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(draftDebounce, _flushDraft);
  }

  void _cancelContext() {
    setState(() {
      _mode = ChatComposerMode.compose;
      _contextMessage = null;
      _controller.clear();
      _emojiPanelOpen = false;
    });
  }

  /// Swaps the emoji panel for the soft keyboard, or back.
  ///
  /// The two never stack: opening drops focus so the keyboard retracts and the
  /// panel takes the space it leaves, and closing asks for focus back. The
  /// draft and the caret belong to the controller, which neither transition
  /// touches.
  void _toggleEmojiPanel() {
    final opening = !_emojiPanelOpen;
    if (opening) {
      _focusNode.unfocus();
    }
    setState(() => _emojiPanelOpen = opening);
    if (!opening) {
      _focusNode.requestFocus();
    }
  }

  void _closeEmojiPanel() {
    if (!_emojiPanelOpen) return;
    setState(() => _emojiPanelOpen = false);
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.securityGate != ChatSecurityGate.ready) return;
    final contextMessage = _contextMessage;
    if (_mode == ChatComposerMode.edit && contextMessage != null) {
      widget.onIntent(
        EditMessageIntent(messageId: contextMessage.id, text: text),
      );
    } else {
      widget.onIntent(
        SendTextIntent(
          text: text,
          replyToMessageId: _mode == ChatComposerMode.reply
              ? contextMessage?.id
              : null,
          quoteFallback: _mode == ChatComposerMode.reply
              ? contextMessage?.text
              : null,
        ),
      );
    }
    setState(() {
      _controller.clear();
      _mode = ChatComposerMode.compose;
      _contextMessage = null;
      _emojiPanelOpen = false;
    });
    // The message has left; the draft it used to be must not outlive it by
    // half a second, or a conversation reopened inside that window shows the
    // text back as though it had never been sent.
    _flushDraft();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final gate = widget.securityGate;
    if (gate != ChatSecurityGate.ready && gate != ChatSecurityGate.checking) {
      return _WithheldComposer(gate: gate);
    }
    // While trust is still being read the composer stays in place and inert
    // rather than being swapped for a banner. The answer usually lands within a
    // frame or two, and a control that disappears and comes back reads as a
    // fault; one that is briefly unavailable does not.
    final ready = gate == ChatSecurityGate.ready;
    return PopScope(
      // Back closes the panel before it leaves the conversation, the way it
      // dismisses a keyboard rather than the screen behind one.
      canPop: !_emojiPanelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _closeEmojiPanel();
          return;
        }
        _flushDraft();
      },
      child: Material(
        color: context.tokens.colors.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: context.tokens.colors.border),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.offline)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      color: context.tokens.colors.warning.withValues(
                        alpha: 0.14,
                      ),
                      padding: const EdgeInsets.all(AppSpacing.x2),
                      child: Text(
                        strings.chatOfflineQueueNotice,
                        style: context.tokens.typography.compact,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                if (_contextMessage != null)
                  _ComposerContextStrip(
                    mode: _mode,
                    message: _contextMessage!,
                    onCancel: _cancelContext,
                  ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.x2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      AppIconButton(
                        icon: AppIcons.attach,
                        semanticLabel: strings.chatAttachAction,
                        onPressed:
                            ready &&
                                widget.attachments !=
                                    ChatAttachmentAvailability.unavailable
                            ? () =>
                                  widget.onIntent(const OpenAttachmentIntent())
                            : null,
                        kind: AppButtonKind.ghost,
                      ),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 144),
                          child: TextField(
                            key: const ValueKey('chat-composer-field'),
                            controller: _controller,
                            focusNode: _focusNode,
                            enabled: ready,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: TextInputAction.newline,
                            keyboardType: TextInputType.multiline,
                            maxLength: 16384,
                            buildCounter:
                                (
                                  context, {
                                  required currentLength,
                                  required isFocused,
                                  maxLength,
                                }) => currentLength > 15000
                                ? Text(
                                    '$currentLength / $maxLength',
                                    // A spliced numeric expression, and the
                                    // only place in this file where two
                                    // independent runs share one paragraph.
                                    // Under an RTL ambient direction the two
                                    // numbers are EN, the separator is
                                    // neutral, and UAX #9 N1 resolves it to
                                    // the base direction, which reverses the
                                    // pair: `20 / 500` renders as
                                    // `500 / 20`. The expression reads left to
                                    // right in either locale, so it says so.
                                    textDirection: TextDirection.ltr,
                                    style: context.tokens.typography.label,
                                  )
                                : null,
                            decoration: InputDecoration(
                              hintText: widget.savedMessages
                                  ? strings.savedMessagesComposerHint
                                  : strings.chatComposerHint,
                              filled: true,
                              fillColor: context.tokens.colors.surfaceRaised,
                              border: const OutlineInputBorder(
                                borderRadius: AppRadii.control,
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onSubmitted: (_) {
                              if (HardwareKeyboard.instance.isControlPressed) {
                                _submit();
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x1),
                      // The emoji button stays put. It used to be swapped out for
                      // Send as soon as the draft had a character in it, which
                      // meant an emoji could only ever be inserted into an empty
                      // field - and "insert at the caret" had nothing to insert
                      // into. Send appears beside it instead of in place of it.
                      AppIconButton(
                        icon: _emojiPanelOpen
                            ? AppIcons.keyboard
                            : AppIcons.emoji,
                        semanticLabel: _emojiPanelOpen
                            ? strings.chatEmojiPanelCloseAction
                            : strings.chatEmojiAction,
                        onPressed: ready ? _toggleEmojiPanel : null,
                        kind: AppButtonKind.ghost,
                      ),
                      // Send follows the text without the composer following
                      // it. The controller is a listenable, so the button is
                      // the only thing that rebuilds when a character lands.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _controller,
                        builder: (context, value, _) =>
                            value.text.trim().isEmpty
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(width: AppSpacing.x1),
                                  AppIconButton(
                                    icon: AppIcons.send,
                                    semanticLabel:
                                        _mode == ChatComposerMode.edit
                                        ? strings.chatSaveEditAction
                                        : strings.chatSendAction,
                                    onPressed: ready ? _submit : null,
                                    kind: AppButtonKind.primary,
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                // The panel is part of the composer, not a sheet over it: it
                // stays open across as many selections as the user wants, and
                // the field it is typing into stays visible directly above it.
                // Insertion at the caret and grapheme-wise backspace are the
                // package's own, driven by the controller handed to it.
                if (_emojiPanelOpen)
                  AppEmojiPicker(controller: _controller, showBackspace: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerContextStrip extends StatelessWidget {
  const _ComposerContextStrip({
    required this.mode,
    required this.message,
    required this.onCancel,
  });

  final ChatComposerMode mode;
  final ChatMessageViewModel message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = mode == ChatComposerMode.edit
        ? strings.chatEditingMessage
        : strings.chatReplyingTo(message.authorName);
    return Semantics(
      container: true,
      label: label,
      child: Container(
        width: double.infinity,
        color: context.tokens.colors.surfaceRaised,
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.x4,
          top: AppSpacing.x2,
          bottom: AppSpacing.x2,
        ),
        child: Row(
          children: [
            AppIcon(
              mode == ChatComposerMode.edit ? AppIcons.edit : AppIcons.reply,
              color: context.tokens.colors.accent,
              size: 18,
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context.tokens.typography.label.copyWith(
                      color: context.tokens.colors.accent,
                    ),
                  ),
                  Text(
                    message.text ?? strings.chatDeletedMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tokens.typography.compact,
                  ),
                ],
              ),
            ),
            AppIconButton(
              icon: AppIcons.close,
              semanticLabel: strings.chatCancelContextAction,
              onPressed: onCancel,
              kind: AppButtonKind.ghost,
            ),
          ],
        ),
      ),
    );
  }
}

class _WithheldComposer extends StatelessWidget {
  const _WithheldComposer({required this.gate});

  final ChatSecurityGate gate;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final message = switch (gate) {
      // Neither gate withholds a message, so neither reaches this widget.
      ChatSecurityGate.checking || ChatSecurityGate.ready => '',
      ChatSecurityGate.unverifiedIdentity =>
        strings.chatWithheldUnverifiedIdentity,
      ChatSecurityGate.unverifiedDevice => strings.chatWithheldUnverifiedDevice,
      ChatSecurityGate.masterKeyChanged => strings.chatWithheldMasterChanged,
      ChatSecurityGate.deviceLogFork => strings.chatWithheldLogFork,
      ChatSecurityGate.postQuantumUnavailable => strings.chatWithheldPq,
      ChatSecurityGate.groupUpdating => strings.groupWithheldUpdating,
      ChatSecurityGate.groupRemoved => strings.groupWithheldRemoved,
      ChatSecurityGate.groupQueueGap => strings.groupWithheldQueueGap,
      ChatSecurityGate.groupConflict => strings.groupWithheldConflict,
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Material(
        color: context.tokens.colors.surface,
        child: SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.x4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.tokens.colors.danger),
              ),
            ),
            child: Row(
              children: [
                AppIcon(AppIcons.security, color: context.tokens.colors.danger),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Text(
                    message,
                    style: context.tokens.typography.compact.copyWith(
                      color: context.tokens.colors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
