import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// The strip above a conversation's timeline that counts its pinned messages.
///
/// A tap jumps to the first of them; View all opens the list. A direct chat
/// and a group show the same strip (ADR-096 D6).
class ChatPinnedBanner extends StatelessWidget {
  const ChatPinnedBanner({
    required this.count,
    required this.onJump,
    required this.onExpand,
    super.key,
  });

  final int count;
  final VoidCallback onJump;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = strings.chatPinnedBanner(count);
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: Material(
        color: context.tokens.colors.accentSoft,
        child: InkWell(
          onTap: onJump,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            child: Row(
              children: [
                AppIcon(AppIcons.pin, color: context.tokens.colors.accent),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: Text(
                    label,
                    style: context.tokens.typography.compact.copyWith(
                      color: context.tokens.colors.accent,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onExpand,
                  child: Text(strings.chatPinnedExpandAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lists [pinned] in a sheet. A row jumps to its message, and Unpin is
/// offered on a message the user may unpin: every message of a direct chat,
/// and in a group only to the owner and the admins (ADR-096 D6).
Future<void> showChatPinnedMessages({
  required BuildContext context,
  required List<ChatMessageViewModel> pinned,
  required ValueChanged<ChatIntent> onIntent,
}) {
  final strings = AppLocalizations.of(context);
  return showAppSheet<void>(
    context: context,
    semanticLabel: strings.chatPinnedMessagesTitle,
    childScrolls: true,
    child: SizedBox(
      height: mathMin(MediaQuery.sizeOf(context).height * .65, 520),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.chatPinnedMessagesTitle,
            style: context.tokens.typography.section,
          ),
          const SizedBox(height: AppSpacing.x3),
          Expanded(
            child: ListView.builder(
              itemCount: pinned.length,
              itemBuilder: (context, index) {
                final message = pinned[index];
                return ListTile(
                  leading: const AppIcon(AppIcons.pin),
                  title: Text(
                    message.text ?? strings.chatDeletedMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: message.canPin
                      ? TextButton(
                          onPressed: () => onIntent(
                            SetPinIntent(messageId: message.id, pinned: false),
                          ),
                          child: Text(strings.chatUnpinAction),
                        )
                      : null,
                  onTap: () {
                    popAppModal(context);
                    onIntent(JumpToMessageIntent(message.id));
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

double mathMin(double left, double right) => left < right ? left : right;
