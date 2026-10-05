import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// A routed destination that a user can reach and that has no implementation
/// behind it.
///
/// It carries the shared [SurfaceMaturity.notBuilt] badge and says so in plain
/// words. It deliberately offers nothing to open: a "not built yet" screen with
/// a button to another "not built yet" screen is half-presence, which is what
/// ADR-044 requires absent features not to be.
enum StructuralPlaceholderKind { chats, settings, thread, newChat }

class StructuralPlaceholderPage extends StatelessWidget {
  const StructuralPlaceholderPage({required this.kind, super.key});

  final StructuralPlaceholderKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = switch (kind) {
      StructuralPlaceholderKind.chats => l10n.chatsPlaceholderTitle,
      StructuralPlaceholderKind.settings => l10n.settingsPlaceholderTitle,
      StructuralPlaceholderKind.thread => l10n.threadPlaceholderTitle,
      StructuralPlaceholderKind.newChat => l10n.newChatPlaceholderTitle,
    };
    final body = switch (kind) {
      StructuralPlaceholderKind.chats => l10n.chatsPlaceholderBody,
      StructuralPlaceholderKind.settings => l10n.settingsPlaceholderBody,
      _ => l10n.placeholderBody,
    };
    final icon = switch (kind) {
      StructuralPlaceholderKind.chats ||
      StructuralPlaceholderKind.thread ||
      StructuralPlaceholderKind.newChat => AppIcons.chats,
      StructuralPlaceholderKind.settings => AppIcons.settings,
    };
    final route = GoRouterState.of(context).uri.path;

    return ColoredBox(
      color: context.tokens.colors.canvas,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.x6),
            child: Semantics(
              container: true,
              header: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppStatusBadge(
                      kind: AppStatusKind.warning,
                      label: SurfaceMaturity.notBuilt.label(l10n),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  AppIcon(icon, color: context.tokens.colors.accent, size: 40),
                  const SizedBox(height: AppSpacing.x4),
                  Text(
                    title,
                    style: context.tokens.typography.title,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  Text(
                    body,
                    style: context.tokens.typography.body.copyWith(
                      color: context.tokens.colors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  Text(
                    l10n.routeLabel(route),
                    key: const ValueKey('current-route-label'),
                    style: context.tokens.typography.compact.copyWith(
                      color: context.tokens.colors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
