import 'dart:async';

import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// How long an own direct message may wait for a delivery receipt before the
/// chat asks the sender to look into it (ADR-093 D19).
///
/// The Android catch-up a closed app relies on runs at most every fifteen
/// minutes and Doze stretches the gaps, so a recipient whose phone is merely
/// asleep has had several chances to answer within an hour.
const chatUndeliveredHintDelay = Duration(hours: 1);

/// The message the undelivered hint stands under, or null when there is none.
///
/// Only the newest own message counts: the cause belongs to the peer and not to
/// one message, so one line says it. That message must be accepted by the relay
/// and have no receipt; a receipt means the peer receives, and a queued,
/// sending or failed message has its own mark.
ChatMessageViewModel? chatUndeliveredHintTarget(
  List<ChatMessageViewModel> messages,
) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (!message.outgoing) continue;
    if (message.deleted || message.delivery != ChatDeliveryViewState.accepted) {
      return null;
    }
    return message;
  }
  return null;
}

/// The moment [message] has gone [chatUndeliveredHintDelay] without a receipt.
///
/// Counted from the message's own time: the timeline does not read the relay's
/// acceptance. A message that waited longer than the delay in the queue shows
/// the hint when it is accepted, and loses it when its receipt arrives.
DateTime chatUndeliveredHintDue(ChatMessageViewModel message) =>
    message.timestamp.add(chatUndeliveredHintDelay);

/// The line under the newest own direct message that no receipt has answered
/// for an hour: "Not delivered yet. If @username has not verified you, ask them
/// to." (ADR-093 D19).
///
/// The page decides that the conversation is a direct chat by giving a [peer];
/// a group and Saved Messages give none. The widget holds no timer unless a
/// qualifying message is younger than the delay, and then holds one, for the
/// moment it turns old enough.
class ChatUndeliveredHint extends StatefulWidget {
  const ChatUndeliveredHint({
    required this.messages,
    required this.peer,
    required this.now,
    super.key,
  });

  final List<ChatMessageViewModel> messages;

  /// How the peer is named: `@username`, or the short identity without the
  /// `@`. Null where the conversation is not a direct chat.
  final String? peer;
  final DateTime Function() now;

  @override
  State<ChatUndeliveredHint> createState() => _ChatUndeliveredHintState();
}

class _ChatUndeliveredHintState extends State<ChatUndeliveredHint> {
  Timer? _due;
  DateTime? _scheduledFor;

  @override
  void dispose() {
    _due?.cancel();
    super.dispose();
  }

  void _schedule(DateTime? due) {
    if (due == _scheduledFor) return;
    _due?.cancel();
    _due = null;
    _scheduledFor = due;
    if (due == null) return;
    final wait = due.difference(widget.now());
    _due = Timer(wait.isNegative ? Duration.zero : wait, () {
      _due = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final target = peer == null
        ? null
        : chatUndeliveredHintTarget(widget.messages);
    final due = target == null ? null : chatUndeliveredHintDue(target);
    final shows = due != null && !widget.now().isBefore(due);
    // A message that is old enough needs no timer; a younger one needs the one
    // that wakes this widget when it is not.
    _schedule(shows ? null : due);
    if (!shows || peer == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.x12,
          end: AppSpacing.x4,
          bottom: AppSpacing.x2,
        ),
        child: Text(
          AppLocalizations.of(
            context,
          ).chatUndeliveredHint(chatNameForSentence(context, peer)),
          key: const ValueKey('chat-undelivered-hint'),
          style: context.tokens.typography.compact.copyWith(
            color: context.tokens.colors.textMuted,
          ),
        ),
      ),
    );
  }
}
