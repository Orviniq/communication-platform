import 'package:communication_platform/features/app_shell/presentation/app_shell.dart';
import 'package:communication_platform/features/app_shell/presentation/live_shell_status.dart';
import 'package:flutter/widgets.dart';

/// A full-screen page with the call banner at its top (`ui-specification.md`
/// §0.2). The page covers the shell and the shell's banner with it, so while
/// a call runs it carries the banner itself: below the status bar and above
/// the page's app bar, on every page but the call's own.
///
/// It learns of the call through [LiveShellStatus], as the shell does. The
/// banner takes the top inset and the page sees none, so the page's app bar
/// adds no second one. The page keeps its place whether the banner shows or
/// not, so a call that starts or ends while the page is open leaves the
/// page's state alone: a draft in the composer stays.
class VoiceRoomBannerFrame extends StatelessWidget {
  const VoiceRoomBannerFrame({
    required this.base,
    required this.location,
    required this.child,
    super.key,
  });

  /// The status without the production ProviderScope, as the shell gets it.
  final AppShellStatus base;

  /// The page's own path, `GoRouterState.matchedLocation`. A page lower in
  /// the stack is rebuilt with the top page's location in `uri`, which would
  /// take the banner off the room's page as the call slides over it.
  final String location;

  final Widget child;

  @override
  Widget build(BuildContext context) => LiveShellStatus(
    base: base,
    location: location,
    builder: (status) {
      final banner = status.voiceRoomBannerAt(location);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          banner ?? const SizedBox.shrink(),
          // The same widgets above the page with the banner or without it, so
          // the page is updated in place rather than built again.
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: banner != null,
              child: child,
            ),
          ),
        ],
      );
    },
  );
}
