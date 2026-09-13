import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/contacts/presentation/contact_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class ContactsNewPage extends ConsumerStatefulWidget {
  const ContactsNewPage({
    this.ownUserId,
    this.contacts,
    this.directoryService,
    super.key,
  });

  final String? ownUserId;
  final Stream<List<ContactProjection>>? contacts;
  final DirectoryService? directoryService;

  @override
  ConsumerState<ContactsNewPage> createState() => _ContactsNewPageState();
}

class _ContactsNewPageState extends ConsumerState<ContactsNewPage> {
  static const _pageSize = 20;
  final _search = TextEditingController();
  var _visible = _pageSize;
  var _refreshing = false;
  var _offline = false;

  @override
  void initState() {
    super.initState();
    if (widget.contacts == null || widget.directoryService != null) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final DirectoryService service =
        widget.directoryService ??
        await ref.read(directoryServiceProvider.future);
    final result = await service.refresh();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _offline = switch (result) {
        FailureResult(failure: TransportFailure()) => true,
        _ => false,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final ownUserId =
        widget.ownUserId ?? ref.watch(authenticationControllerProvider).userId;
    final injected = widget.contacts;
    if (injected != null) {
      return StreamBuilder<List<ContactProjection>>(
        stream: injected,
        builder: (context, snapshot) =>
            _scaffold(context, snapshot.data, waiting: !snapshot.hasData),
      );
    }
    if (ownUserId == null) {
      return _scaffold(context, const [], waiting: false);
    }
    final contacts = ref.watch(contactListProvider(ownUserId));
    return contacts.when(
      data: (value) => _scaffold(context, value, waiting: false),
      loading: () => _scaffold(context, null, waiting: true),
      error: (_, _) => _scaffold(context, const [], waiting: false),
    );
  }

  Widget _scaffold(
    BuildContext context,
    List<ContactProjection>? contacts, {
    required bool waiting,
  }) {
    final strings = AppLocalizations.of(context);
    final normalized = _search.text.trim().toLowerCase();
    final filtered = (contacts ?? const <ContactProjection>[])
        .where(
          (contact) =>
              normalized.isEmpty ||
              contact.username.contains(normalized) ||
              (contact.canUseAuthenticatedProfile &&
                  contact.presentationName.toLowerCase().contains(normalized)),
        )
        .toList(growable: false);
    final shown = filtered.take(_visible).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/chats'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(strings.contactsNewTitle),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          key: const PageStorageKey('contacts-new-list'),
          padding: const EdgeInsets.all(AppSpacing.x4),
          children: [
            if (_offline)
              Notice(
                key: const ValueKey('contacts-offline-cache'),
                kind: AppStatusKind.warning,
                message: strings.contactsOfflineMessage,
              ),
            ActionRow(
              label: strings.contactsNewGroup,
              icon: AppIcons.add,
              onTap: () => context.push('/groups/new'),
            ),
            ActionRow(
              label: strings.contactsNewVoiceRoom,
              icon: AppIcons.voiceRooms,
              onTap: null,
            ),
            const SizedBox(height: AppSpacing.x4),
            AppField(
              label: strings.contactsSearchLabel,
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() => _visible = _pageSize),
            ),
            const SizedBox(height: AppSpacing.x4),
            if (waiting && contacts == null)
              AppStatePanel.loading(title: strings.contactsLoadingTitle)
            else if (filtered.isEmpty)
              AppStatePanel.empty(
                title: strings.contactsEmptyTitle,
                message: strings.contactsEmptyMessage,
              )
            else ...[
              for (final contact in shown)
                _ContactRow(
                  contact: contact,
                  onTap: () => context.push('/chats/direct/${contact.userId}'),
                ),
              if (shown.length < filtered.length)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.x4),
                  child: AppButton(
                    key: const ValueKey('contacts-load-more'),
                    label: strings.contactsLoadMore,
                    onPressed: () => setState(() => _visible += _pageSize),
                    kind: AppButtonKind.outline,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.onTap});

  final ContactProjection contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label:
          '${contact.presentationName}, ${contact.isVerified ? strings.contactsVerified : strings.contactsUnverified}',
      child: ListTile(
        minTileHeight: 64,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
        leading: ContactAvatar(
          username: contact.username,
          authenticatedSeed: contact.authenticatedAvatarSeed,
          semanticLabel: contact.presentationName,
        ),
        title: Text(contact.presentationName),
        subtitle: contact.presentationName == contact.username
            ? Text(strings.contactsUsernameFallback)
            : Text('@${contact.username}', textDirection: TextDirection.ltr),
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
