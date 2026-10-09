import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// How many matches one search shows at once.
///
/// A conversation's local history has no upper bound, and a list that renders
/// every match in a fifty-thousand-message conversation is a list nobody reads
/// and a frame nobody sees. The cap is stated on screen when it bites, because
/// a silently truncated result set is a search that quietly lies about its own
/// scope — which is the same failure ADR-052 corrected in the chat-list hint.
const conversationSearchResultLimit = 30;

/// Every message in [messages] whose text contains [query], case-insensitively.
///
/// Pure, and deliberately so: the scope claim this surface makes — *the whole
/// of this conversation's local history, and nothing else* — is a property of
/// what is passed in, and a test can assert it without a widget. Nothing here
/// touches storage, the network or the crypto core; the caller has already
/// decrypted and projected this conversation, and a match is a substring of a
/// string that is already on the screen.
List<ChatMessageViewModel> conversationSearchMatches({
  required String query,
  required List<ChatMessageViewModel> messages,
  int limit = conversationSearchResultLimit,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return const <ChatMessageViewModel>[];
  }
  final matches = <ChatMessageViewModel>[];
  for (final message in messages) {
    final text = message.text;
    if (text != null && text.toLowerCase().contains(needle)) {
      matches.add(message);
      if (matches.length == limit) {
        break;
      }
    }
  }
  return List.unmodifiable(matches);
}

/// The in-conversation search surface, shared by direct, saved and group
/// conversations.
///
/// One implementation on purpose. Before this existed, a direct conversation
/// had a search and a group conversation had a disabled button offering one,
/// which is a control that can never succeed — the thing the UI specification's
/// core rules forbid. Sharing it also means the scope notice, the empty states
/// and the result cap can never disagree between two surfaces that promise the
/// same thing.
Future<void> showConversationSearch({
  required BuildContext context,
  required List<ChatMessageViewModel> messages,
  required ValueChanged<String> onJumpToMessage,
}) {
  final strings = AppLocalizations.of(context);
  return showAppSheet<void>(
    context: context,
    semanticLabel: strings.chatSearchAction,
    childScrolls: true,
    child: _ConversationSearchSheet(
      messages: messages,
      onJumpToMessage: onJumpToMessage,
    ),
  );
}

class _ConversationSearchSheet extends StatefulWidget {
  const _ConversationSearchSheet({
    required this.messages,
    required this.onJumpToMessage,
  });

  final List<ChatMessageViewModel> messages;
  final ValueChanged<String> onJumpToMessage;

  @override
  State<_ConversationSearchSheet> createState() =>
      _ConversationSearchSheetState();
}

class _ConversationSearchSheetState extends State<_ConversationSearchSheet> {
  /// Owned here rather than by the caller: the sheet's exit animation
  /// rebuilds this field after the route pops, so a controller disposed
  /// when the future completes is a controller used after disposal.
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final query = _controller.text.trim();
    final results = conversationSearchMatches(
      query: query,
      messages: widget.messages,
    );
    final truncated = results.length == conversationSearchResultLimit;
    final height = MediaQuery.sizeOf(context).height * .7;
    return SizedBox(
      height: height < 560 ? height : 560,
      child: Column(
        children: [
          TextField(
            key: const ValueKey('conversation-search-field'),
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: strings.chatSearchInputLabel,
              prefixIcon: const Padding(
                padding: EdgeInsets.all(AppSpacing.x3),
                child: AppIcon(AppIcons.search),
              ),
              suffixIcon: query.isEmpty
                  ? null
                  : AppIconButton(
                      icon: AppIcons.close,
                      semanticLabel: strings.chatsClearSearchAction,
                      kind: AppButtonKind.ghost,
                      onPressed: () {
                        _controller.clear();
                        setState(() {});
                      },
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x2),
            child: Text(
              strings.chatsDeviceSearchScopeNotice,
              key: const ValueKey('conversation-search-scope-notice'),
              style: context.tokens.typography.label.copyWith(
                color: context.tokens.colors.textMuted,
              ),
            ),
          ),
          if (results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  truncated
                      ? strings.chatSearchTruncatedNotice(results.length)
                      : strings.chatSearchResultCount(results.length),
                  key: const ValueKey('conversation-search-result-count'),
                  style: context.tokens.typography.label.copyWith(
                    color: context.tokens.colors.textMuted,
                  ),
                ),
              ),
            ),
          Expanded(
            child: query.isEmpty
                ? AppStatePanel.empty(
                    title: strings.chatSearchEmptyQueryTitle,
                    message: strings.chatsDeviceSearchScopeNotice,
                  )
                : results.isEmpty
                ? AppStatePanel.empty(
                    title: strings.chatsNoSearchResultsTitle,
                    message: strings.chatsDeviceSearchScopeNotice,
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final message = results[index];
                      return ListTile(
                        key: ValueKey('conversation-search-hit-${message.id}'),
                        title: Text(
                          message.text ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(message.authorName),
                        onTap: () {
                          popAppModal(context);
                          widget.onJumpToMessage(message.id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
