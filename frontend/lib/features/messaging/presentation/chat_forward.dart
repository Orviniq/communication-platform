import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a message may be forwarded from the conversation [conversationId]:
/// every other conversation on this phone, and Saved Messages.
///
/// Read from the conversation list at the moment the picker opens, which is
/// the only moment it is wanted.
List<ChatListItemViewModel> chatForwardTargets(
  WidgetRef ref, {
  required String currentUserId,
  required String conversationId,
  required bool savedMessages,
  required AppLocalizations strings,
}) {
  final summaries =
      ref.read(conversationSummariesProvider(currentUserId)).value ??
      const <ConversationSummary>[];
  final targets = ChatViewModelMapper.summaries(
    summaries,
    now: DateTime.now(),
    savedMessagesTitle: strings.savedMessagesTitle,
    peerTitle: chatShortIdentity,
  ).where((item) => item.conversationId != conversationId).toList();
  if (!savedMessages && !targets.any((target) => target.savedMessages)) {
    targets.insert(
      0,
      ChatListItemViewModel(
        conversationId: '',
        title: strings.savedMessagesTitle,
        preview: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        unreadCount: 0,
        muted: false,
        pinned: false,
        savedMessages: true,
        peerUserId: null,
      ),
    );
  }
  return targets;
}

/// The forward picker of a direct chat and of a group chat: the targets to
/// tick, and one Forward button that hands the ticked ones to [onForward].
///
/// A group sends no attachment (ADR-089 D1), so the picker of an attachment
/// message lists no group (ADR-090 D5).
Future<void> showChatForwardPicker({
  required BuildContext context,
  required ChatMessageViewModel message,
  required List<ChatListItemViewModel> targets,
  required void Function(Iterable<ChatListItemViewModel> targets) onForward,
}) async {
  final strings = AppLocalizations.of(context);
  final selected = <String>{};
  final forwardTargets = message.attachments.isEmpty
      ? targets
      : targets.where((target) => !target.group).toList(growable: false);
  await showAppSheet<void>(
    context: context,
    semanticLabel: strings.chatForwardAction,
    childScrolls: true,
    child: StatefulBuilder(
      builder: (context, setModalState) => SizedBox(
        height: _min(MediaQuery.sizeOf(context).height * .7, 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.chatForwardAction,
              style: context.tokens.typography.section,
            ),
            const SizedBox(height: AppSpacing.x2),
            Expanded(
              child: forwardTargets.isEmpty
                  ? AppStatePanel.empty(
                      title: strings.chatsEmptyTitle,
                      message: strings.chatsEmptyMessage,
                    )
                  : ListView.builder(
                      itemCount: forwardTargets.length,
                      itemBuilder: (context, index) {
                        final target = forwardTargets[index];
                        final selectionKey = _selectionKey(target);
                        return CheckboxListTile(
                          value: selected.contains(selectionKey),
                          title: Text(target.title),
                          secondary: target.savedMessages
                              ? const AppIcon(AppIcons.saved)
                              : ContactAvatar(
                                  username: target.title,
                                  semanticLabel: target.title,
                                  radius: 18,
                                ),
                          onChanged: (value) {
                            setModalState(() {
                              if (value ?? false) {
                                selected.add(selectionKey);
                              } else {
                                selected.remove(selectionKey);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
            AppButton(
              label: strings.chatForwardAction,
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final chosen = forwardTargets.where(
                        (target) => selected.contains(_selectionKey(target)),
                      );
                      popAppModal(context);
                      onForward(chosen);
                    },
            ),
          ],
        ),
      ),
    ),
  );
}

/// Sends [message] to each of [targets], one after the other.
///
/// Saved Messages and a direct chat take the shared send path. A group takes
/// the group use cases, so the rule of a group send applies: a group that no
/// longer lets this account send is sent nothing. An attachment message is
/// never sent into a group, whatever the picker offered.
///
/// A refused target does not stop the others. The result is a failure when
/// any target refused, for the caller to say so once.
Future<Result<void>> forwardChatMessage(
  WidgetRef ref, {
  required String currentUserId,
  required ChatMessageViewModel message,
  required Iterable<ChatListItemViewModel> targets,
}) async {
  if (message.attachments.isEmpty &&
      (message.text == null || message.text!.trim().isEmpty)) {
    return const Result.failure(
      ValidationFailure(ValidationFailureKind.invalidInput),
    );
  }
  final text = message.text ?? '';
  Result<void> outcome = const Result.success(null);
  for (final target in targets.toList(growable: false)) {
    Result<void> sent;
    try {
      sent = await _forwardTo(
        ref,
        currentUserId: currentUserId,
        message: message,
        text: text,
        target: target,
      );
    } on Object {
      // Composing a send path can throw where a use case would only have
      // returned a failure. It is this target's failure, not the others'.
      sent = const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (sent case FailureResult(failure: final failure)) {
      outcome = Result.failure(failure);
    }
  }
  return outcome;
}

Future<Result<void>> _forwardTo(
  WidgetRef ref, {
  required String currentUserId,
  required ChatMessageViewModel message,
  required String text,
  required ChatListItemViewModel target,
}) async {
  if (target.group) {
    if (message.attachments.isNotEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final groups = ref.read(groupUseCasesProvider.future);
    final deviceId = await ref.read(currentMessagingDeviceIdProvider.future);
    // The conversation id of a group is the group id (ADR-090 D1).
    return (await groups).sendMessage(
      groupId: target.conversationId,
      senderUserId: currentUserId,
      senderDeviceId: deviceId,
      text: text,
      quoteFallback: message.replyQuote,
    );
  }
  final ConversationTarget destination;
  if (target.savedMessages) {
    destination = const SavedConversationTarget();
  } else if (target.peerUserId case final peerUserId?) {
    destination = DirectConversationTarget(peerUserId);
  } else {
    return const Result.failure(
      ValidationFailure(ValidationFailureKind.invalidInput),
    );
  }
  final deviceId = await ref.read(currentMessagingDeviceIdProvider.future);
  final sender = await ref.read(
    sendConversationEventsProvider((
      userId: currentUserId,
      deviceId: deviceId,
    )).future,
  );
  final sent = await sender.forward(
    currentUserId: currentUserId,
    currentDeviceId: deviceId,
    target: destination,
    text: text,
    quoteFallback: message.replyQuote,
    attachments: message.attachments,
    imageMessage: message.kind == ChatTimelineContentKind.image,
  );
  return sent.fold(
    onSuccess: (_) => const Result.success(null),
    onFailure: Result.failure,
  );
}

String _selectionKey(ChatListItemViewModel target) =>
    target.savedMessages ? 'saved' : target.conversationId;

double _min(double left, double right) => left < right ? left : right;
