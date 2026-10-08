import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The bar that leads back to the call in progress (`ui-specification.md`
/// §0.2): the room's name, its microphone, and a tap that opens the call.
class VoiceRoomBanner extends StatelessWidget {
  const VoiceRoomBanner({
    required this.roomId,
    required this.roomName,
    required this.muted,
    super.key,
  });

  final String roomId;

  /// Null until this device has read the room's name.
  final String? roomName;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (roomName) {
      final name? => l10n.returnToVoiceRoom(name),
      null => l10n.voiceCallReturnBanner,
    };
    final microphone = muted ? l10n.voiceTileMuted : l10n.voiceTileMicOn;
    final colors = context.tokens.colors;
    return Semantics(
      key: const ValueKey('active-voice-banner'),
      button: true,
      label: '$label, $microphone',
      excludeSemantics: true,
      child: Material(
        color: colors.accentSoft,
        child: InkWell(
          onTap: () => context.go('/voice-rooms/$roomId/call'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppFocus.minimumTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(
                    muted ? AppIcons.microphoneOff : AppIcons.microphone,
                    color: colors.accent,
                    size: 18,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Flexible(
                    child: Text(
                      label,
                      style: context.tokens.typography.compact.copyWith(
                        color: colors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
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
