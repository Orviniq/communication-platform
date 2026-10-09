import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_list_row.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/chats_search.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Chats search: the chats and the contacts on this phone that a query
/// finds by name, by username or by a chat's latest message.
///
/// [PRIVACY] It reads two projections that are already on this phone, the
/// conversation summaries and the contact list, and nothing else. It calls no
/// service, so it does not refresh the directory, and it sends the query
/// nowhere and stores it nowhere: the field holds it while the page is open,
/// and it goes with the page. It keeps no search history.
class ChatsSearchPage extends ConsumerStatefulWidget {
  const ChatsSearchPage({super.key});

  @override
  ConsumerState<ChatsSearchPage> createState() => _ChatsSearchPageState();
}

class _ChatsSearchPageState extends ConsumerState<ChatsSearchPage>
    with ChatListMuteClock {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final userId = ref.watch(authenticationControllerProvider).userId;
    final summaries = userId == null
        ? const AsyncValue<List<ConversationSummary>>.data([])
        : ref.watch(conversationSummariesProvider(userId));
    final contacts = userId == null
        ? const AsyncValue<List<ContactProjection>>.data([])
        : ref.watch(contactListProvider(userId));
    trackMuteExpiry(summaries.value ?? const <ConversationSummary>[]);
    final chats = chatListItems(
      summaries.value ?? const <ConversationSummary>[],
      contacts: contacts.value ?? const <ContactProjection>[],
      now: mutedAsOf,
      strings: strings,
    );
    // The query belongs to the field. Rebuilding the page for it would
    // re-map every conversation on every keystroke, for a list that had not
    // changed.
    return Scaffold(
      key: const ValueKey('chats-search-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/chats'),
          kind: AppButtonKind.ghost,
        ),
        titleSpacing: 0,
        title: _SearchField(controller: _query),
        actions: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _query,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: AppSpacing.x2)
                : AppIconButton(
                    key: const ValueKey('chats-search-clear'),
                    icon: AppIcons.close,
                    semanticLabel: strings.chatsClearSearchAction,
                    onPressed: _query.clear,
                    kind: AppButtonKind.ghost,
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _query,
        builder: (context, value, _) => _body(
          context,
          strings,
          query: value.text,
          chats: chats,
          summaries: summaries,
          contacts: contacts,
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations strings, {
    required String query,
    required List<ChatListItemViewModel> chats,
    required AsyncValue<List<ConversationSummary>> summaries,
    required AsyncValue<List<ContactProjection>> contacts,
  }) {
    if (query.trim().isEmpty) {
      return ListView(
        key: const ValueKey('chats-search-scope'),
        padding: AppInsets.belowAppBar(context, AppSpacing.x4),
        children: [
          Text(
            strings.chatsSearchScopeNotice,
            style: context.tokens.typography.body.copyWith(
              color: context.tokens.colors.textMuted,
            ),
          ),
        ],
      );
    }
    if (summaries.hasError && !summaries.hasValue) {
      return AppStatePanel.error(
        title: strings.chatsErrorTitle,
        message: strings.chatsErrorMessage,
      );
    }
    // A projection that has not answered yet would read as "nothing found".
    if (!summaries.hasValue || (contacts.isLoading && !contacts.hasValue)) {
      return AppStatePanel.loading(title: strings.chatsLoadingTitle);
    }
    final results = chatsSearch(
      query: query,
      chats: chats,
      // An unreadable contact list finds no contact, as Contacts/New shows
      // none; the chats still answer.
      contacts: contacts.value ?? const <ContactProjection>[],
    );
    if (results.isEmpty) {
      return AppStatePanel.empty(
        key: const ValueKey('chats-search-no-results'),
        title: strings.chatsNoSearchResultsTitle,
        message: strings.chatsSearchScopeNotice,
      );
    }
    final entries = <_Entry>[
      if (results.chats.isNotEmpty) ...[
        _HeaderEntry(strings.chatsSearchChatsHeader),
        for (final chat in results.chats) _ChatEntry(chat),
      ],
      if (results.contacts.isNotEmpty) ...[
        _HeaderEntry(strings.chatsSearchContactsHeader),
        for (final contact in results.contacts) _ContactEntry(contact),
      ],
    ];
    return ListView.builder(
      key: const PageStorageKey('chats-search-results'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      // Down to the screen's edge, with the last row resting above the
      // gesture bar.
      padding:
          AppInsets.belowAppBar(context, 0) +
          const EdgeInsets.only(bottom: AppSpacing.x2),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        _HeaderEntry(:final label) => _SectionHeader(label),
        // A tap pushes, so back returns here with the query and the results.
        // The search has no menu: what a long press offers belongs to the
        // list.
        _ChatEntry(:final chat) => ChatListRow(
          key: ValueKey('chats-search-chat-${chat.conversationId}'),
          item: chat,
          onTap: () => unawaited(context.push(chatListItemLocation(chat))),
        ),
        _ContactEntry(:final contact) => _ContactResultRow(
          key: ValueKey('chats-search-contact-${contact.userId}'),
          contact: contact,
          onTap: () =>
              unawaited(context.push('/chats/direct/${contact.userId}')),
        ),
      },
    );
  }
}

sealed class _Entry {
  const _Entry();
}

final class _HeaderEntry extends _Entry {
  const _HeaderEntry(this.label);

  final String label;
}

final class _ChatEntry extends _Entry {
  const _ChatEntry(this.chat);

  final ChatListItemViewModel chat;
}

final class _ContactEntry extends _Entry {
  const _ContactEntry(this.contact);

  final ContactProjection contact;
}

/// The query, in the app bar. It takes the focus as the page opens, so the
/// keyboard comes up with it.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    const none = InputBorder.none;
    // The field's name for a screen reader. It merges into the field's own
    // node and stays there, while the hint, which says what the field
    // searches, goes as soon as a query is typed.
    return Semantics(
      label: strings.chatsSearchFieldLabel,
      child: TextField(
        key: const ValueKey('chats-search-field'),
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        // Asks the keyboard not to learn the query either: the page keeps no
        // history of its own, and an incognito request is all it can make of
        // a keyboard it does not own.
        enableIMEPersonalizedLearning: false,
        style: context.tokens.typography.body,
        decoration: InputDecoration(
          hintText: strings.chatsSearchFieldHint,
          hintStyle: context.tokens.typography.body.copyWith(
            color: context.tokens.colors.textMuted,
          ),
          hintMaxLines: 1,
          border: none,
          enabledBorder: none,
          focusedBorder: none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
          constraints: const BoxConstraints(minHeight: AppFocus.minimumTarget),
        ),
      ),
    );
  }
}

/// A heading above one section of the results.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.x4,
      AppSpacing.x4,
      AppSpacing.x4,
      AppSpacing.x2,
    ),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: context.tokens.typography.section.copyWith(
          color: context.tokens.colors.textMuted,
        ),
      ),
    ),
  );
}

/// A contact the query found: its avatar, its name and its username.
class _ContactResultRow extends StatelessWidget {
  const _ContactResultRow({
    required this.contact,
    required this.onTap,
    super.key,
  });

  final ContactProjection contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final trust = contact.isVerified
        ? strings.contactsVerified
        : strings.contactsUnverified;
    return Semantics(
      button: true,
      label: '${contact.presentationName}, @${contact.username}, $trust',
      // The tile's own tap action goes with `excludeSemantics`, so the node
      // carries it.
      onTap: onTap,
      excludeSemantics: true,
      child: ListTile(
        minTileHeight: 64,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
        leading: ContactAvatar(
          username: contact.username,
          authenticatedSeed: contact.authenticatedAvatarSeed,
          semanticLabel: contact.presentationName,
        ),
        title: Text(
          contact.presentationName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '@${contact.username}',
          textDirection: TextDirection.ltr,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: contact.isVerified
            ? AppIcon(
                AppIcons.security,
                decorative: false,
                semanticLabel: strings.contactsVerified,
                color: context.tokens.colors.success,
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}
