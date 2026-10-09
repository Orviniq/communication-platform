import 'dart:async';

import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// The conversations [summaries] describe, as the Chats list shows them.
///
/// One mapping for every surface that lists conversations, so a conversation
/// carries the same title wherever it appears: a direct conversation is named
/// after its peer's presentation name from [contacts], or a short form of the
/// peer's identity when the peer is not a contact.
List<ChatListItemViewModel> chatListItems(
  List<ConversationSummary> summaries, {
  required List<ContactProjection> contacts,
  required DateTime now,
  required AppLocalizations strings,
}) {
  final names = {
    for (final contact in contacts) contact.userId: contact.presentationName,
  };
  return ChatViewModelMapper.summaries(
    summaries,
    now: now,
    savedMessagesTitle: strings.savedMessagesTitle,
    peerTitle: (id) => names[id] ?? chatShortIdentity(id),
  );
}

/// Where a tap on [item] leads: Saved Messages, a group, or a direct
/// conversation.
String chatListItemLocation(ChatListItemViewModel item) {
  if (item.savedMessages) {
    return '/saved-messages?conversationId=${item.conversationId}';
  }
  if (item.group) return '/groups/${item.conversationId}';
  return '/chats/conversation/${item.conversationId}'
      '?peer=${item.peerUserId ?? ''}';
}

/// The reading of the clock a list's muted state is decided against.
///
/// `DateTime.now()` inside `build` made every conversation's view model
/// depend on the frame it happened to be built in, which is not something a
/// mapper that has to be idempotent may do. Held here instead, and refreshed
/// on a schedule the list can state: exactly when the earliest mute on
/// screen expires, and never otherwise.
mixin ChatListMuteClock<T extends StatefulWidget> on State<T> {
  DateTime _mutedAsOf = DateTime.now();
  DateTime? _scheduledMuteExpiry;
  Timer? _muteExpiry;

  /// The instant the rows' muted state is read at.
  DateTime get mutedAsOf => _mutedAsOf;

  @override
  void dispose() {
    _muteExpiry?.cancel();
    super.dispose();
  }

  /// Schedules the one refresh the mute clock owes, and no others.
  ///
  /// Idempotent, so calling it from `build` costs a walk of the list and
  /// nothing else when the answer has not moved. A list with nothing muted
  /// holds no timer at all.
  void trackMuteExpiry(List<ConversationSummary> summaries) {
    DateTime? earliest;
    for (final summary in summaries) {
      final until = summary.mutedUntil;
      if (until == null || !until.isAfter(_mutedAsOf)) continue;
      if (earliest == null || until.isBefore(earliest)) earliest = until;
    }
    if (earliest == _scheduledMuteExpiry) return;
    _scheduledMuteExpiry = earliest;
    _muteExpiry?.cancel();
    _muteExpiry = null;
    if (earliest == null) return;
    final wait = earliest.difference(DateTime.now());
    _muteExpiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (!mounted) return;
      setState(() {
        _mutedAsOf = DateTime.now();
        _scheduledMuteExpiry = null;
      });
    });
  }
}

/// One conversation, as a row of the Chats list.
///
/// Shared by the Chats list and the search page, so a conversation looks the
/// same in both. [onMenu] opens the list's conversation menu, on a long press
/// or a secondary click; a row without it offers neither.
class ChatListRow extends StatelessWidget {
  const ChatListRow({
    required this.item,
    required this.onTap,
    this.onMenu,
    super.key,
  });

  final ChatListItemViewModel item;
  final VoidCallback onTap;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final semanticLabel = strings.chatsItemSemantics(
      item.title,
      item.preview,
      item.unreadCount,
    );
    final onMenu = this.onMenu;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        onSecondaryTapUp: onMenu == null ? null : (_) => onMenu(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4,
              vertical: AppSpacing.x2,
            ),
            child: Row(
              children: [
                if (item.savedMessages)
                  CircleAvatar(
                    backgroundColor: context.tokens.colors.accentSoft,
                    child: const AppIcon(AppIcons.saved),
                  )
                else
                  ContactAvatar(
                    username: item.title,
                    semanticLabel: item.title,
                  ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tokens.typography.body.copyWith(
                                fontWeight: item.unreadCount > 0
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          Text(
                            MaterialLocalizations.of(context).formatTimeOfDay(
                              TimeOfDay.fromDateTime(item.timestamp),
                            ),
                            style: context.tokens.typography.label.copyWith(
                              color: context.tokens.colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.preview.isEmpty
                                  ? strings.chatsNoMessagesPreview
                                  : item.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tokens.typography.compact.copyWith(
                                color: context.tokens.colors.textMuted,
                              ),
                            ),
                          ),
                          if (item.muted)
                            AppIcon(
                              AppIcons.muted,
                              color: context.tokens.colors.textMuted,
                              size: 16,
                            ),
                          if (item.pinned)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: AppSpacing.x1,
                              ),
                              child: AppIcon(
                                AppIcons.pin,
                                color: context.tokens.colors.textMuted,
                                size: 16,
                              ),
                            ),
                          if (item.unreadCount > 0)
                            Container(
                              margin: const EdgeInsetsDirectional.only(
                                start: AppSpacing.x2,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 24,
                                minHeight: 24,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.x1,
                              ),
                              decoration: BoxDecoration(
                                color: context.tokens.colors.accent,
                                borderRadius: AppRadii.pill,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${item.unreadCount}',
                                style: context.tokens.typography.label.copyWith(
                                  color: context.tokens.colors.canvas,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
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
