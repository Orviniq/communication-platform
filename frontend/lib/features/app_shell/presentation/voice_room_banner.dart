import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The bar that leads back to the call in progress (`ui-specification.md`
/// §0.2): the room's name, its microphone, and a tap that opens the call.
///
/// The shell draws it on a tab root, and `VoiceRoomBannerFrame` at the top of
/// each full-screen page. It takes the insets its place leaves to it: none in
/// the shell, and the status bar's at the top of a page, where its colour runs
/// up under the status bar and its control stays below it.
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
    void openCall() => context.go('/voice-rooms/$roomId/call');
    return Material(
      color: colors.accentSoft,
      child: SafeArea(
        bottom: false,
        child: Semantics(
          key: const ValueKey('active-voice-banner'),
          button: true,
          label: '$label, $microphone',
          // `excludeSemantics` drops the InkWell's own tap action with the
          // rest of what is under this node, so the node carries it: a
          // service that acts through actions, Switch Access for one, has
          // nothing to activate on a button without it.
          onTap: openCall,
          excludeSemantics: true,
          child: InkWell(
            onTap: openCall,
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
      ),
    );
  }
}
