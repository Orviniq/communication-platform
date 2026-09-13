import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/groups/presentation/group_member_picker.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class AddGroupMembersPage extends ConsumerStatefulWidget {
  const AddGroupMembersPage({required this.groupId, super.key});

  final String groupId;

  @override
  ConsumerState<AddGroupMembersPage> createState() =>
      _AddGroupMembersPageState();
}

class _AddGroupMembersPageState extends ConsumerState<AddGroupMembersPage> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authenticationControllerProvider);
    final userId = auth.userId;
    if (userId == null) return groupErrorPage(context);
    final group = ref.watch(groupProvider(widget.groupId));
    final contacts = ref.watch(contactListProvider(userId));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    if (group case AsyncData(value: final state?)) {
      if (contacts case AsyncData(value: final contactValues)) {
        if (device case AsyncData(value: final deviceId)) {
          if (useCases case AsyncData(value: final resolved)) {
            final existing = state.members
                .map((member) => member.userId)
                .toSet();
            final eligible = contactValues
                .where((contact) => !existing.contains(contact.userId))
                .map(GroupPickerContact.fromContact)
                .toList(growable: false);
            return Scaffold(
              appBar: AppBar(
                title: Text(AppLocalizations.of(context).groupAddMembersAction),
              ),
              body: GroupResponsiveBody(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  children: [
                    GroupMemberPicker(
                      contacts: eligible,
                      selectedUserIds: _selected,
                      maximumSelection:
                          GroupState.maximumMembers -
                          state.activeMembers.length,
                      onSelectionChanged: (value) => setState(() {
                        _selected
                          ..clear()
                          ..addAll(value);
                      }),
                    ),
                    const SizedBox(height: AppSpacing.x6),
                    AppButton(
                      label: AppLocalizations.of(context).groupAddMembersAction,
                      onPressed: _selected.isEmpty
                          ? null
                          : () async {
                              final members = [
                                for (final contact in eligible)
                                  if (_selected.contains(contact.userId))
                                    GroupMember(
                                      userId: contact.userId,
                                      displayName: contact.name,
                                      role: GroupRole.member,
                                      verified: contact.verified,
                                    ),
                              ];
                              final result = await resolved.mutate(
                                groupId: widget.groupId,
                                actorUserId: userId,
                                actorDeviceId: deviceId,
                                operation: AddGroupMembersOperation(members),
                              );
                              if (mounted && result is Success<GroupState>) {
                                this.context.pop();
                              }
                            },
                    ),
                  ],
                ),
              ),
            );
          }
        }
      }
    }
    return groupLoadingPage(context);
  }
}
