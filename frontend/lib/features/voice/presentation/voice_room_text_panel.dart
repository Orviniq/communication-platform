import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_room_text_budget.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_components.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// Sends one line, answering whether it went.
typedef SendRoomTextCallback = Future<bool> Function(String text);

/// The call's ephemeral room text (`voice-room-states.md` §5.6).
///
/// It says plainly that it is temporary and best-effort, and while the
/// signalling connection is down it says loudly that it has stopped updating
/// and takes no line. The composer refuses a line no published bucket can
/// carry ([VoiceRoomTextBudget]): a frame off its buckets would be dropped in
/// silence, and the line would look sent.
///
/// [draft] belongs to the screen, so a resize that moves this panel between
/// a tab and a side panel keeps what was typed.
class VoiceRoomTextPanel extends StatefulWidget {
  const VoiceRoomTextPanel({
    required this.entries,
    required this.people,
    required this.draft,
    required this.signalBuckets,
    required this.stale,
    required this.onSend,
    super.key,
  });

  final List<VoiceRoomTextEntry> entries;
  final VoiceRoomPeople people;
  final TextEditingController draft;
  final Set<int> signalBuckets;
  final bool stale;
  final SendRoomTextCallback onSend;

  @override
  State<VoiceRoomTextPanel> createState() => _VoiceRoomTextPanelState();
}

class _VoiceRoomTextPanelState extends State<VoiceRoomTextPanel> {
  var _sending = false;
  var _notSent = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Column(
      key: const ValueKey('voice-room-text-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x4,
            AppSpacing.x3,
            AppSpacing.x4,
            AppSpacing.x2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  strings.voiceCallChatTab,
                  style: context.tokens.typography.section,
                ),
              ),
              const SizedBox(height: AppSpacing.x1),
              Text(
                strings.voiceChatNote,
                style: context.tokens.typography.compact.copyWith(
                  color: colors.textMuted,
                ),
              ),
              if (widget.stale) ...[
                const SizedBox(height: AppSpacing.x2),
                VoiceNotice(
                  key: const ValueKey('voice-room-text-stale'),
                  message: strings.voiceChatStale,
                  kind: AppStatusKind.warning,
                  icon: AppIcons.reconnecting,
                  live: true,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: widget.entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.x4),
                    child: Text(
                      strings.voiceChatEmpty,
                      textAlign: TextAlign.center,
                      style: context.tokens.typography.compact.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x2,
                  ),
                  itemCount: widget.entries.length,
                  itemBuilder: (context, index) => _Line(
                    entry: widget.entries[widget.entries.length - 1 - index],
                    people: widget.people,
                  ),
                ),
        ),
        if (widget.stale)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: Text(
              strings.voiceChatUnavailable,
              textAlign: TextAlign.center,
              style: context.tokens.typography.compact.copyWith(
                color: colors.textMuted,
              ),
            ),
          )
        else
          _composer(context, strings),
      ],
    );
  }

  Widget _composer(BuildContext context, AppLocalizations strings) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.draft,
        builder: (context, value, _) {
          final check = VoiceRoomTextBudget.check(
            value.text,
            widget.signalBuckets,
          );
          final String? problem = switch (check) {
            VoiceRoomTextTooLong(:final excessScalars) =>
              strings.voiceChatTooLong(excessScalars),
            VoiceRoomTextUnsendable() => strings.voiceChatUnsendable,
            _ when _notSent => strings.voiceChatNotSent,
            _ => null,
          };
          final sendable = check is VoiceRoomTextSendable && !_sending;
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4,
              AppSpacing.x2,
              AppSpacing.x4,
              AppSpacing.x3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (problem != null) ...[
                  VoiceNotice(
                    key: const ValueKey('voice-room-text-problem'),
                    message: problem,
                    kind: AppStatusKind.danger,
                    live: true,
                  ),
                  const SizedBox(height: AppSpacing.x2),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('voice-room-text-field'),
                        controller: widget.draft,
                        minLines: 1,
                        maxLines: 4,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          hintText: strings.voiceChatHint,
                        ),
                        onChanged: (_) {
                          if (_notSent) {
                            setState(() => _notSent = false);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    AppIconButton(
                      key: const ValueKey('voice-room-text-send'),
                      icon: AppIcons.send,
                      semanticLabel: strings.voiceChatSendAction,
                      kind: AppButtonKind.primary,
                      onPressed: sendable ? () => _send(value.text) : null,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );

  Future<void> _send(String text) async {
    setState(() {
      _sending = true;
      _notSent = false;
    });
    final sent = await widget.onSend(text);
    if (!mounted) {
      return;
    }
    if (sent) {
      widget.draft.clear();
    }
    setState(() {
      _sending = false;
      _notSent = !sent;
    });
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.entry, required this.people});

  final VoiceRoomTextEntry entry;
  final VoiceRoomPeople people;

  @override
  Widget build(BuildContext context) {
    final sender = entry.isOwn
        ? AppLocalizations.of(context).voiceRoomYou
        : people.nameOf(entry.senderUserId);
    return Semantics(
      container: true,
      label: '$sender: ${entry.text}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoiceUserText(
              sender,
              style: context.tokens.typography.label.copyWith(
                color: entry.isOwn
                    ? context.tokens.colors.accent
                    : context.tokens.colors.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.x1),
            VoiceUserText(entry.text, style: context.tokens.typography.body),
          ],
        ),
      ),
    );
  }
}
