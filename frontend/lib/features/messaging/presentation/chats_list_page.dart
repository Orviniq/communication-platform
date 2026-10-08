import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
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

class _ChatsListPageState extends State<ChatsListPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// The reading of the clock the muted state is decided against.
  ///
  /// `DateTime.now()` inside `build` made every conversation's view model
  /// depend on the frame it happened to be built in, which is not something a
  /// mapper that has to be idempotent may do. Held here instead, and refreshed
  /// on a schedule the list can state: exactly when the earliest mute on
  /// screen expires, and never otherwise.
  DateTime _mutedAsOf = DateTime.now();
  DateTime? _scheduledMuteExpiry;
  Timer? _muteExpiry;

  @override
  void dispose() {
    _muteExpiry?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Schedules the one refresh the mute clock owes, and no others.
  ///
  /// Idempotent, so calling it from `build` costs a walk of the list and
  /// nothing else when the answer has not moved. A list with nothing muted
  /// holds no timer at all.
  void _trackMuteExpiry(List<ConversationSummary> summaries) {
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
    _trackMuteExpiry(summaries.value ?? const <ConversationSummary>[]);
    final contacts = ref.watch(contactListProvider(currentUserId));
    // A jammed engine and a slow network used to look identical from here,
    // because nothing in this application read the phase the engine has been
    // writing all along.
    final delivery = _deliveryIndicator(
      ref.watch(syncProjectionProvider).value?.connectionPhase,
    );
    final names = {
      for (final contact in contacts.value ?? const <ContactProjection>[])
        contact.userId: contact.presentationName,
    };
    final strings = AppLocalizations.of(context);
    final model = summaries.when(
      data: (items) => ChatListViewModel(
        items: ChatViewModelMapper.summaries(
          items,
          now: _mutedAsOf,
          savedMessagesTitle: strings.savedMessagesTitle,
          peerTitle: (id) => names[id] ?? chatShortIdentity(id),
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
        // The query belongs to the field. Rebuilding the page for it re-mapped
        // every conversation summary on every keystroke, to filter a list that
        // had not changed.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _search,
          builder: (context, value, _) =>
              _searchField(context, strings, value.text.trim()),
        ),
        Expanded(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _search,
            builder: (context, value, _) => _results(
              context,
              model,
              strings,
              value.text.trim().toLowerCase(),
              ref,
            ),
          ),
        ),
      ],
    );
    if (widget.compact) return body;
    return Scaffold(
      key: const ValueKey('chats-list-screen'),
      appBar: AppBar(
        title: Text(strings.chatsTitle),
        actions: [
          AppIconButton(
            icon: AppIcons.search,
            semanticLabel: strings.chatsSearchAction,
            onPressed: _searchFocus.requestFocus,
            kind: AppButtonKind.ghost,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _searchField(
    BuildContext context,
    AppLocalizations strings,
    String query,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.x4,
      AppSpacing.x3,
      AppSpacing.x4,
      AppSpacing.x2,
    ),
    child: TextField(
      key: const ValueKey('chats-search-field'),
      controller: _search,
      focusNode: _searchFocus,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: strings.chatsSearchHint,
        prefixIcon: Padding(
          padding: const EdgeInsets.all(AppSpacing.x3),
          child: AppIcon(AppIcons.search),
        ),
        suffixIcon: query.isEmpty
            ? null
            : AppIconButton(
                icon: AppIcons.close,
                semanticLabel: strings.chatsClearSearchAction,
                onPressed: _search.clear,
                kind: AppButtonKind.ghost,
              ),
        filled: true,
        fillColor: context.tokens.colors.surfaceRaised,
        border: const OutlineInputBorder(
          borderRadius: AppRadii.control,
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  Widget _results(
    BuildContext context,
    ChatListViewModel model,
    AppLocalizations strings,
    String query,
    WidgetRef? ref,
  ) {
    final items = model.items
        .where(
          (item) =>
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              item.preview.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return switch ((model.loading, model.failed, items.isEmpty, query)) {
      (true, _, _, _) => AppStatePanel.loading(
        title: strings.chatsLoadingTitle,
      ),
      (_, true, _, _) => AppStatePanel.error(
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
      (_, _, true, '') => AppStatePanel.empty(
        title: strings.chatsEmptyTitle,
        message: strings.chatsEmptyMessage,
        actionLabel: strings.chatsStartAction,
        onAction: () => context.go('/chats/new'),
      ),
      // This list filters on title and last-message preview and nothing
      // else, so it says so. Borrowing the in-conversation notice here
      // promised a search of this device's history that the list has
      // never performed (ADR-052).
      (_, _, true, _) => AppStatePanel.empty(
        title: strings.chatsNoSearchResultsTitle,
        message: strings.chatsListSearchScopeNotice,
      ),
      _ => ListView.builder(
        key: const PageStorageKey('chats-list'),
        itemCount: items.length + (query.isEmpty ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == items.length) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Text(
                strings.chatsListSearchScopeNotice,
                textAlign: TextAlign.center,
                style: context.tokens.typography.label.copyWith(
                  color: context.tokens.colors.textMuted,
                ),
              ),
            );
          }
          final item = items[index];
          return _ConversationRow(
            item: item,
            onTap: () => _open(item),
            onAction: (action) => _handleConversationAction(item, action, ref),
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
    if (item.savedMessages) {
      unawaited(
        context.push('/saved-messages?conversationId=${item.conversationId}'),
      );
    } else if (item.group) {
      unawaited(context.push('/groups/${item.conversationId}'));
    } else {
      context.go(
        '/chats/conversation/${item.conversationId}'
        '?peer=${item.peerUserId ?? ''}',
      );
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

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.item,
    required this.onTap,
    required this.onAction,
  });

  final ChatListItemViewModel item;
  final VoidCallback onTap;
  final ValueChanged<_ConversationAction> onAction;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final semanticLabel = strings.chatsItemSemantics(
      item.title,
      item.preview,
      item.unreadCount,
    );
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showMenu(context),
        onSecondaryTapUp: (_) => _showMenu(context),
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

  Future<void> _showMenu(BuildContext context) async {
    final strings = AppLocalizations.of(context);
    await showAppSheet<void>(
      context: context,
      semanticLabel: strings.chatsConversationActionsLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChatMenuRow(
            label: item.pinned
                ? strings.chatUnpinAction
                : strings.chatPinAction,
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
