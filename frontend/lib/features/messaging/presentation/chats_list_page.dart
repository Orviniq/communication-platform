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
        ChatListViewModel(
          items: const [],
          loading: false,
          offline: false,
          failed: false,
        ),
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
        ChatListViewModel(
          items: [],
          loading: false,
          offline: false,
          failed: false,
        ),
      );
    }
    final summaries = ref.watch(conversationSummariesProvider(currentUserId));
    trackMuteExpiry(summaries.value ?? const <ConversationSummary>[]);
    final contacts = ref.watch(contactListProvider(currentUserId));
    // A jammed engine and a slow network used to look identical from here,
    // because nothing in this application read the phase the engine has been
    // writing all along.
    final delivery = _deliveryIndicator(
      ref.watch(syncProjectionProvider).value?.connectionPhase,
    );
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
        offline: auth.access == AuthenticationRouteAccess.offlineFullScope,
        failed: false,
        delivery: delivery,
      ),
      loading: () => ChatListViewModel(
        items: const [],
        loading: true,
        offline: auth.access == AuthenticationRouteAccess.offlineFullScope,
        failed: false,
        delivery: delivery,
      ),
      error: (_, _) => ChatListViewModel(
        items: const [],
        loading: false,
        offline: auth.access == AuthenticationRouteAccess.offlineFullScope,
        failed: true,
        delivery: delivery,
      ),
    );
    return _scaffold(context, model, ref: ref);
  }

  Widget _scaffold(
    BuildContext context,
    ChatListViewModel model, {
    WidgetRef? ref,
  }) {
    final strings = AppLocalizations.of(context);
    final body = Column(
      children: [
        if (model.offline)
          _InlineNotice(
            key: const ValueKey('chats-offline-notice'),
            label: strings.chatsOfflineCachedNotice,
            kind: AppStatusKind.warning,
          )
        else if (_deliveryNotice(model.delivery, strings) case final label?)
          _InlineNotice(
            key: const ValueKey('chats-delivery-notice'),
            label: label,
            kind: AppStatusKind.neutral,
          ),
        Expanded(child: _results(context, model, strings, ref)),
      ],
    );
    if (widget.compact) return body;
    return Scaffold(
      key: const ValueKey('chats-list-screen'),
      appBar: AppBar(
        title: Text(strings.chatsTitle),
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

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.label, required this.kind, super.key});

  final String label;
  final AppStatusKind kind;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.x2),
    child: AppStatusBadge(kind: kind, label: label),
  );
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

/// The line for a delivery state, or nothing at all when there is nothing to
/// say.
///
/// A settled session renders no notice. An indicator that is always on screen
/// is one nobody reads, and this one exists precisely to be noticed on the day
/// it stops changing.
String? _deliveryNotice(
  ChatDeliveryIndicator indicator,
  AppLocalizations strings,
) => switch (indicator) {
  ChatDeliveryIndicator.settled => null,
  ChatDeliveryIndicator.connecting => strings.chatsDeliveryConnectingNotice,
  ChatDeliveryIndicator.syncing => strings.chatsDeliverySyncingNotice,
  ChatDeliveryIndicator.waiting => strings.chatsDeliveryWaitingNotice,
};
