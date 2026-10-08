import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/settings/presentation/settings_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The shortcut §15.2 asks for: which contacts have been checked out of band,
/// and which have not.
///
/// It shows the same trust state the conversation screens gate on, from the
/// same local projection, and it never renders an unverified contact's cached
/// profile name — the backend username and the deterministic local avatar are
/// what an unverified row is entitled to (ADR-021).
final class SafetyNumbersPage extends ConsumerWidget {
  const SafetyNumbersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ownUserId = ref.watch(authenticationControllerProvider).userId;
    return Scaffold(
      key: const ValueKey('safety-numbers-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings/security'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.securitySafetyNumbersTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: ownUserId == null
              ? AppStatePanel.empty(
                  title: l10n.contactsEmptyTitle,
                  message: l10n.contactsEmptyMessage,
                )
              : ref
                    .watch(contactListProvider(ownUserId))
                    .when(
                      loading: () => AppStatePanel.loading(
                        title: l10n.contactsLoadingTitle,
                      ),
                      error: (_, _) => AppStatePanel.error(
                        title: l10n.contactsEmptyTitle,
                        message: l10n.contactsEmptyMessage,
                      ),
                      data: (contacts) => contacts.isEmpty
                          ? AppStatePanel.empty(
                              title: l10n.contactsEmptyTitle,
                              message: l10n.contactsEmptyMessage,
                            )
                          : ListView(
                              padding: AppInsets.belowAppBar(
                                context,
                                AppSpacing.x4,
                              ),
                              children: [
                                SettingsNote(l10n.safetyNumbersReviewBody),
                                for (final contact in contacts)
                                  _ContactTrustRow(contact: contact),
                              ],
                            ),
                    ),
        ),
      ),
    );
  }
}

final class _ContactTrustRow extends StatelessWidget {
  const _ContactTrustRow({required this.contact});

  final ContactProjection contact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final verified = contact.isVerified;
    final state = _stateLabel(l10n, contact.trustState);
    return Card(
      child: ListTile(
        key: ValueKey('safety-number-${contact.userId}'),
        leading: ContactAvatar(
          username: contact.username,
          semanticLabel: contact.username,
          authenticatedSeed: contact.authenticatedAvatarSeed,
        ),
        title: Text(contact.presentationName),
        subtitle: Text(state),
        // Colour is never the only carrier: the icon differs by shape too.
        trailing: AppIcon(
          verified ? AppIcons.success : AppIcons.warning,
          decorative: true,
          color: verified
              ? context.tokens.colors.success
              : context.tokens.colors.warning,
        ),
        onTap: () => context.push('/contacts/${contact.userId}/safety'),
      ),
    );
  }

  static String _stateLabel(AppLocalizations l10n, ContactTrustState state) =>
      switch (state) {
        ContactTrustState.verified => l10n.safetyVerifiedState,
        ContactTrustState.unverified => l10n.safetyUnverifiedState,
        ContactTrustState.masterKeyChanged => l10n.safetyMasterChangedState,
        ContactTrustState.invalidDevice => l10n.safetyInvalidDeviceState,
        ContactTrustState.deviceLogFork => l10n.safetyForkState,
        ContactTrustState.identityUnavailable =>
          l10n.safetyIdentityUnavailableState,
      };
}
