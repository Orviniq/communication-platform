import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_list_row.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class ChatsListPage extends StatefulWidget {
  const ChatsListPage({
    this.model,
    this.onOpenConversation,
    this.compact = false,
    super.key,
  });

  final ChatListViewModel? model;
  final ValueChanged<ChatListItemViewModel>? onOpenConversation;
  final bool compact;

  @override
  State<ChatsListPage> createState() => _ChatsListPageState();
}

class _ChatsListPageState extends State<ChatsListPage> with ChatListMuteClock {
  @override
  Widget build(BuildContext context) {
    final injected = widget.model;
    if (injected != null) return _scaffold(context, injected);
    // App-shell and route harnesses may intentionally render without the
    // production ProviderScope. Keep that presentation-only surface useful
    // while the real bootstrap continues to provide the runtime container.
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return _scaffold(
        context,
        ChatListViewModel(items: const [], loading: false, failed: false),
      );
    }
    return Consumer(builder: (context, ref, _) => _projected(context, ref));
  }

  Widget _projected(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authenticationControllerProvider);
    final currentUserId = auth.userId;
    if (currentUserId == null) {
      return _scaffold(
        context,
        ChatListViewModel(items: [], loading: false, failed: false),
      );
    }
    final summaries = ref.watch(conversationSummariesProvider(currentUserId));
    trackMuteExpiry(summaries.value ?? const <ConversationSummary>[]);
    final contacts = ref.watch(contactListProvider(currentUserId));
    final strings = AppLocalizations.of(context);
    final model = summaries.when(
      data: (items) => ChatListViewModel(
        items: chatListItems(
          items,
          contacts: contacts.value ?? const <ContactProjection>[],
          now: mutedAsOf,
          strings: strings,
        ),
        loading: false,
        failed: false,
      ),
      loading: () =>
          ChatListViewModel(items: const [], loading: true, failed: false),
      error: (_, _) =>
          ChatListViewModel(items: const [], loading: false, failed: true),
    );
    return _scaffold(context, model, ref: ref);
  }

  Widget _scaffold(
    BuildContext context,
    ChatListViewModel model, {
    WidgetRef? ref,
  }) {
    final strings = AppLocalizations.of(context);
    // The list, and nothing above it: the engine's status is the title's.
    final body = _results(context, model, strings, ref);
    if (widget.compact) return body;
    return Scaffold(
      key: const ValueKey('chats-list-screen'),
      appBar: AppBar(
        // Without a ProviderScope there is no engine to ask, and the title is
        // its own name.
        title: ref == null
            ? Text(
                strings.chatsTitle,
                key: const ValueKey('chats-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : const _ChatsTitle(key: ValueKey('chats-title')),
        actions: [
          // Search is a page of its own (ui-specification.md §6.5): the list
          // keeps its whole height for the conversations.
          AppIconButton(
            key: const ValueKey('chats-search-action'),
            icon: AppIcons.search,
            semanticLabel: strings.chatsSearchAction,
            onPressed: () => unawaited(context.push('/chats/search')),
            kind: AppButtonKind.ghost,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _results(
    BuildContext context,
    ChatListViewModel model,
    AppLocalizations strings,
    WidgetRef? ref,
  ) {
    final items = model.items;
    return switch ((model.loading, model.failed, items.isEmpty)) {
      (true, _, _) => AppStatePanel.loading(title: strings.chatsLoadingTitle),
      (_, true, _) => AppStatePanel.error(
        title: strings.chatsErrorTitle,
        message: strings.chatsErrorMessage,
        actionLabel: strings.retryAction,
        onAction: () {
          final userId = ref?.read(authenticationControllerProvider).userId;
          if (userId != null) {
            ref?.invalidate(conversationSummariesProvider(userId));
          }
        },
      ),
      (_, _, true) => AppStatePanel.empty(
        title: strings.chatsEmptyTitle,
        message: strings.chatsEmptyMessage,
        actionLabel: strings.chatsStartAction,
        onAction: () => context.go('/chats/new'),
      ),
      _ => ListView.builder(
        key: const PageStorageKey('chats-list'),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return ChatListRow(
            item: item,
            onTap: () => _open(item),
            onMenu: () => _showConversationMenu(
              context,
              item,
              (action) => _handleConversationAction(item, action, ref),
            ),
          );
        },
      ),
    };
  }

  void _open(ChatListItemViewModel item) {
    final callback = widget.onOpenConversation;
    if (callback != null) {
      callback(item);
      return;
    }
    // Saved Messages and groups are routes outside the Chats branch. A `go` to
    // one replaced the whole stack, so back left the application; a push
    // keeps the list below, and back returns to it at the same place.
    final location = chatListItemLocation(item);
    if (item.savedMessages || item.group) {
      unawaited(context.push(location));
    } else {
      context.go(location);
    }
  }

  Future<void> _handleConversationAction(
    ChatListItemViewModel item,
    _ConversationAction action,
    WidgetRef? ref,
  ) async {
    if (ref == null) return;
    final strings = AppLocalizations.of(context);
    final manager = await ref.read(manageLocalConversationStateProvider.future);
    switch (action) {
      case _ConversationAction.mute:
        await manager.mute(
          conversationId: item.conversationId,
          until: item.muted
              ? null
              : DateTime.now().toUtc().add(const Duration(hours: 8)),
        );
      case _ConversationAction.markRead:
        await manager.markRead(item.conversationId);
      case _ConversationAction.markUnread:
        final currentUserId = ref.read(authenticationControllerProvider).userId;
        if (currentUserId != null) {
          await manager.markUnread(
            conversationId: item.conversationId,
            currentUserId: currentUserId,
          );
        }
      case _ConversationAction.pin:
        await manager.setPinned(
          conversationId: item.conversationId,
          pinned: !item.pinned,
        );
      case _ConversationAction.delete:
        if (!mounted) return;
        await showAppDialog<void>(
          context: context,
          title: strings.chatsDeleteTitle,
          body: strings.chatsDeleteLocalOnlyMessage,
          actions: [
            AppButton(
              label: strings.chatCancelAction,
              kind: AppButtonKind.ghost,
              onPressed: () => popAppModal(context),
            ),
            AppButton(
              label: strings.chatDeleteForMeAction,
              kind: AppButtonKind.danger,
              onPressed: () {
                popAppModal(context);
                unawaited(manager.deleteConversationForMe(item.conversationId));
              },
            ),
          ],
        );
    }
  }
}

/// The Chats list's menu for one conversation: pin, mute, read state and
/// delete.
Future<void> _showConversationMenu(
  BuildContext context,
  ChatListItemViewModel item,
  ValueChanged<_ConversationAction> onAction,
) async {
  final strings = AppLocalizations.of(context);
  await showAppSheet<void>(
    context: context,
    semanticLabel: strings.chatsConversationActionsLabel,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatMenuRow(
          label: item.pinned ? strings.chatUnpinAction : strings.chatPinAction,
          icon: AppIcons.pin,
          onTap: () {
            popAppModal(context);
            onAction(_ConversationAction.pin);
          },
        ),
        ChatMenuRow(
          label: item.muted
              ? strings.chatsUnmuteAction
              : strings.chatsMuteAction,
          icon: AppIcons.muted,
          onTap: () {
            popAppModal(context);
            onAction(_ConversationAction.mute);
          },
        ),
        if (!item.savedMessages)
          ChatMenuRow(
            label: item.unreadCount > 0
                ? strings.chatsMarkReadAction
                : strings.chatsMarkUnreadAction,
            icon: AppIcons.delivered,
            onTap: () {
              popAppModal(context);
              onAction(
                item.unreadCount > 0
                    ? _ConversationAction.markRead
                    : _ConversationAction.markUnread,
              );
            },
          ),
        ChatMenuRow(
          label: strings.chatsDeleteAction,
          icon: AppIcons.delete,
          danger: true,
          onTap: () {
            popAppModal(context);
            onAction(_ConversationAction.delete);
          },
        ),
      ],
    ),
  );
}

enum _ConversationAction { pin, mute, markRead, markUnread, delete }

/// How long the engine must stay in a state other than settled, without a
/// break, before the title says so.
const _statusDelay = Duration(seconds: 1);

final _connectionPhase = syncProjectionProvider.select(
  (projection) => projection.value?.connectionPhase,
);

/// The Chats title, which is also where the delivery engine says what it is
/// doing (ADR-087, moving the line of ADR-060 D11 out of the list).
///
/// "Chats" while the session is settled. Once the engine has been in a state
/// other than settled for [_statusDelay] without a break, the title is that
/// state instead (connecting, syncing or waiting to reconnect), and it is the
/// name again the moment the engine settles. An ordinary cycle is over well
/// within the delay and moves nothing; a stalled engine is still there after
/// it, and that is the day the title exists for. The delay runs from the moment
/// the session stops being settled, and a change between two other states does
/// not restart it. Once the title has left its name, such a change shows at
/// once.
///
/// It reads the live phase and nothing else. How the session was opened
/// (`offlineFullScope`) does not change when the connection returns, so it
/// cannot say what the connection is doing.
class _ChatsTitle extends ConsumerStatefulWidget {
  const _ChatsTitle({super.key});

  @override
  ConsumerState<_ChatsTitle> createState() => _ChatsTitleState();
}

class _ChatsTitleState extends ConsumerState<_ChatsTitle> {
  late final ProviderSubscription<SyncConnectionPhase?> _phase;
  Timer? _clock;
  ChatDeliveryIndicator _state = ChatDeliveryIndicator.settled;
  bool _showsStatus = false;

  @override
  void initState() {
    super.initState();
    _follow(ref.read(_connectionPhase));
    // Not a watch in `build`: Riverpod pauses a watch while a conversation
    // covers this page, and the delay would then run from the moment the page
    // is uncovered rather than from the moment the engine stopped settling.
    _phase = ref.listenManual(
      _connectionPhase,
      (_, phase) => setState(() => _follow(phase)),
    );
  }

  @override
  void dispose() {
    _phase.close();
    _clock?.cancel();
    super.dispose();
  }

  void _follow(SyncConnectionPhase? phase) {
    _state = _deliveryIndicator(phase);
    if (_state == ChatDeliveryIndicator.settled) {
      _clock?.cancel();
      _clock = null;
      _showsStatus = false;
    } else if (!_showsStatus) {
      _clock ??= Timer(_statusDelay, () {
        _clock = null;
        setState(() => _showsStatus = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _showsStatus ? _state : ChatDeliveryIndicator.settled;
    final text = Text(
      _statusText(state, AppLocalizations.of(context)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (state == ChatDeliveryIndicator.settled) return text;
    // Only the status is a live region, so a screen reader announces each
    // change of it once. The name is not one: it would be announced again each
    // time the engine settled.
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state != ChatDeliveryIndicator.waiting) ...[
            const _StatusGlyph(),
            const SizedBox(width: AppSpacing.x2),
          ],
          Flexible(child: text),
        ],
      ),
    );
  }
}

/// What stands before "Connecting…" and "Syncing…": a small spinner, or its
/// still image when animations are off.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph();

  static const _size = 16.0;

  @override
  Widget build(BuildContext context) {
    final color = context.tokens.colors.accent;
    return ExcludeSemantics(
      child: MediaQuery.disableAnimationsOf(context)
          ? AppIcon(AppIcons.connecting, color: color, size: _size)
          : SizedBox.square(
              dimension: _size,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
    );
  }
}

/// Reduces the engine's connection phase to the four states a screen may show.
///
/// The phases this collapses are not equally interesting to a person. Every
/// terminal one — revoked, circuit open, origin rejected — is a condition the
/// session-level surfaces already own and speak about properly, so this reports
/// them as waiting rather than inventing a second, vaguer voice for them here.
ChatDeliveryIndicator _deliveryIndicator(SyncConnectionPhase? phase) =>
    switch (phase) {
      null || SyncConnectionPhase.online => ChatDeliveryIndicator.settled,
      SyncConnectionPhase.connecting => ChatDeliveryIndicator.connecting,
      SyncConnectionPhase.draining => ChatDeliveryIndicator.syncing,
      SyncConnectionPhase.stopped ||
      SyncConnectionPhase.offline ||
      SyncConnectionPhase.reconnectWaiting ||
      SyncConnectionPhase.revoked ||
      SyncConnectionPhase.protocolCircuitOpen ||
      SyncConnectionPhase.originRejected => ChatDeliveryIndicator.waiting,
    };

/// The words the title shows for a delivery state.
///
/// A settled session says nothing about the engine: the title is its own name.
/// An indicator that is always on screen is one nobody reads, and this one
/// exists precisely to be noticed on the day it stops changing.
String _statusText(ChatDeliveryIndicator state, AppLocalizations strings) =>
    switch (state) {
      ChatDeliveryIndicator.settled => strings.chatsTitle,
      ChatDeliveryIndicator.connecting => strings.chatsDeliveryConnectingNotice,
      ChatDeliveryIndicator.syncing => strings.chatsDeliverySyncingNotice,
      ChatDeliveryIndicator.waiting => strings.chatsDeliveryWaitingNotice,
    };
