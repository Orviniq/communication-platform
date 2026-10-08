import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/contacts/presentation/contact_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({this.service, super.key});

  final ProfileService? service;

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _name = TextEditingController();
  var _avatarSeed = 0;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final strings = AppLocalizations.of(context);
    final draft = ProfileDraft(
      displayName: _name.text,
      avatarSeed: _avatarSeed,
    );
    if (!draft.isValid) {
      setState(() => _error = strings.profileInvalidName);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ProfileService service =
        widget.service ?? await ref.read(profileServiceProvider.future);
    final result = await service.publishOwn(draft);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = switch (result) {
        FailureResult() => strings.authGenericErrorMessage,
        _ => null,
      };
    });
    if (result case Success()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.profileSavedMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final publishing = ref.watch(profilePublishingProvider);
    return Scaffold(
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          onPressed: () => context.pop(),
          kind: AppButtonKind.ghost,
        ),
        title: Text(strings.profileEditTitle),
      ),
      body: ListView(
        padding: AppInsets.belowAppBar(context, AppSpacing.x6),
        children: [
          Text(strings.profileVisibilityNote),
          // The screen states what this build can do rather than offering a
          // Save that fails with a generic error. Before ADR-045 it claimed a
          // "development-only fake transport" in every build, including the one
          // handed to users, where no profile adapter exists at all.
          switch (publishing) {
            ProfilePublishing.notBuilt => const _ProfileNotBuiltNotice(),
            ProfilePublishing.developmentStandIn => Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x4),
              child: Notice(
                key: const ValueKey('development-profile-transport-warning'),
                kind: AppStatusKind.warning,
                message: strings.profileTemporaryTransport,
              ),
            ),
            ProfilePublishing.available => const SizedBox.shrink(),
          },
          const SizedBox(height: AppSpacing.x6),
          Center(
            child: ContactAvatar(
              username: _name.text.isEmpty ? 'profile' : _name.text,
              authenticatedSeed: _avatarSeed,
              semanticLabel: strings.profileAvatarStyleLabel,
              radius: 48,
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          AppField(
            label: strings.profileDisplayNameLabel,
            controller: _name,
            maxLength: 64,
            error: _error,
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: AppSpacing.x4),
          Text(strings.profileAvatarStyleLabel),
          const SizedBox(height: AppSpacing.x2),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              for (var seed = 0; seed < 8; seed += 1)
                Semantics(
                  selected: _avatarSeed == seed,
                  label: '${strings.profileAvatarStyleLabel} ${seed + 1}',
                  child: ChoiceChip(
                    key: ValueKey('profile-avatar-$seed'),
                    label: ContactAvatar(
                      username: _name.text.isEmpty ? 'profile' : _name.text,
                      authenticatedSeed: seed,
                      semanticLabel:
                          '${strings.profileAvatarStyleLabel} ${seed + 1}',
                      radius: 18,
                    ),
                    selected: _avatarSeed == seed,
                    onSelected: (_) => setState(() => _avatarSeed = seed),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x6),
          AppButton(
            key: const ValueKey('profile-save'),
            label: _saving
                ? strings.profileSavingAction
                : strings.profileSaveAction,
            onPressed: _saving || !publishing.canPublish ? null : _save,
            leading: AppIcons.success,
          ),
        ],
      ),
    );
  }
}

/// States that this build composes no profile adapter, using the shared
/// not-built vocabulary rather than inventing a fourth word for it.
class _ProfileNotBuiltNotice extends StatelessWidget {
  const _ProfileNotBuiltNotice();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.x4),
      child: Semantics(
        container: true,
        child: Container(
          key: const ValueKey('profile-not-built-notice'),
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            color: context.tokens.colors.surfaceRaised,
            borderRadius: AppRadii.card,
            border: Border.all(color: context.tokens.colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppStatusBadge(
                kind: AppStatusKind.warning,
                label: SurfaceMaturity.notBuilt.label(strings),
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(
                strings.profileNotBuiltNotice,
                style: context.tokens.typography.body,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
