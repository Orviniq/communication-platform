import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

/// Dismisses the sheet or dialog that [showAppSheet] or [showAppDialog] pushed.
///
/// Both push onto the root navigator, so the dismissal has to leave by the same
/// door. A bare `Navigator.pop(context)` resolves to the *nearest* navigator
/// instead, and a call site that built the modal's contents is almost always
/// sitting inside a shell branch — so the bare form pops the page underneath and
/// leaves the modal standing over whatever it lands on, with every button in it
/// now wired to a widget that is no longer mounted.
///
/// Safe to call from inside the modal as well: the root navigator is the
/// nearest one from there too.
void popAppModal<T extends Object?>(BuildContext context, [T? result]) =>
    Navigator.of(context, rootNavigator: true).pop<T>(result);

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required String title,
  required String body,
  required List<Widget> actions,
  bool dismissible = true,
}) => showFDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  useRootNavigator: true,
  builder: (dialogContext, style, animation) => FDialog(
    animation: animation,
    semanticsLabel: title,
    builder: (context, dialogStyle) => Padding(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: context.tokens.typography.section),
          const SizedBox(height: AppSpacing.x3),
          Text(body, style: context.tokens.typography.body),
          const SizedBox(height: AppSpacing.x6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: actions,
          ),
        ],
      ),
    ),
  ),
);

/// A dialog whose body is a widget rather than a paragraph.
///
/// [showAppDialog] covers the common shape — a statement and some buttons — and
/// cannot express a dialog the user has to type *into*. The chrome is the same
/// chrome, written once here so the two cannot drift apart: same surface, same
/// padding, same title treatment, same trailing action row.
///
/// [content] scrolls. A dialog that has to state four consequences before it
/// asks for a password does not fit a phone at a large text scale, and one
/// whose actions are pushed off the bottom cannot be cancelled either.
///
/// [dismissible] is offered because a form is not a statement: a stray tap on
/// the barrier discards whatever was typed, and a caller asking for something
/// irreversible may reasonably want the two explicit doors instead.
///
/// [actions] may be empty, for the dialog whose buttons depend on what has been
/// typed into it and therefore have to live inside [content] with that state.
/// The row and the space above it then go with them, rather than leaving a gap
/// where a caller can see something was meant to be.
Future<T?> showAppContentDialog<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  List<Widget> actions = const [],
  bool dismissible = true,
}) => showFDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  useRootNavigator: true,
  builder: (dialogContext, style, animation) => FDialog(
    animation: animation,
    semanticsLabel: title,
    builder: (context, dialogStyle) => Padding(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: context.tokens.typography.section),
          const SizedBox(height: AppSpacing.x3),
          Flexible(child: SingleChildScrollView(child: content)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.x6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x2,
              children: actions,
            ),
          ],
        ],
      ),
    ),
  ),
);

Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String semanticLabel,
  required Widget child,
  bool dismissible = true,
}) => showFSheet<T>(
  context: context,
  useRootNavigator: true,
  side: FLayout.btt,
  barrierLabel: semanticLabel,
  barrierDismissible: dismissible,
  useSafeArea: true,
  builder: (context) => Semantics(
    container: true,
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: semanticLabel,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: child,
        ),
      ),
    ),
  ),
);

/// A sheet with a second surface floating above it, anchored to the thing the
/// sheet is about.
///
/// [showAppSheet] cannot express this. Its content is laid out inside the sheet,
/// at the bottom of the screen, so a panel built there cannot sit beside the row
/// the user pressed. The obvious alternative - an `OverlayEntry` above the sheet
/// route - puts the panel outside the route, where a modal route's focus scope
/// cannot reach it and a screen reader does not traverse it, which would fail
/// two of the accessibility rules in `responsive-ui.md`. So both surfaces live
/// in one route: the sheet keeps the bottom, and [anchored] is positioned in the
/// space above it, as close to [anchor] as it fits.
///
/// [anchor] is in global coordinates and may be null, which parks [anchored]
/// directly above the sheet. Dismissal is the barrier, the back gesture, or
/// [popAppModal] - the same three doors as [showAppSheet]. It has no
/// drag-to-dismiss, which the Forui sheet does.
Future<T?> showAppAnchoredSheet<T>({
  required BuildContext context,
  required String semanticLabel,
  required Widget child,
  required Widget anchored,
  Rect? anchor,
  bool dismissible = true,
}) {
  final colors = context.tokens.colors;
  final minimumTop = MediaQuery.paddingOf(context).top + AppSpacing.x2;
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: dismissible,
    barrierLabel: semanticLabel,
    barrierColor: colors.scrim,
    transitionDuration: AppMotion.effective(context, AppMotion.route),
    pageBuilder: (context, animation, secondaryAnimation) => Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: Column(
        children: [
          Expanded(
            child: CustomSingleChildLayout(
              delegate: _AnchoredAboveLayout(
                anchor: anchor,
                gap: AppSpacing.x2,
                minimumTop: minimumTop,
              ),
              child: anchored,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: context.tokens.colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(18),
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.x6),
                child: child,
              ),
            ),
          ),
        ],
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = animation.drive(CurveTween(curve: AppMotion.enter));
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Places a child just above [anchor], clamped into the space it is given.
///
/// The layout region is the part of the screen the sheet does not occupy, and
/// it starts at the top of the screen, so the global coordinates [anchor]
/// carries need no translation. A message near the bottom of the timeline
/// therefore ends up with its panel resting on the sheet rather than behind it.
class _AnchoredAboveLayout extends SingleChildLayoutDelegate {
  const _AnchoredAboveLayout({
    required this.anchor,
    required this.gap,
    required this.minimumTop,
  });

  final Rect? anchor;
  final double gap;
  final double minimumTop;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final horizontal = math.max(0, size.width - childSize.width) / 2;
    final lowest = math.max(0.0, size.height - childSize.height);
    final highest = math.min(minimumTop, lowest);
    final preferred = anchor == null
        ? lowest
        : anchor!.top - childSize.height - gap;
    return Offset(horizontal, preferred.clamp(highest, lowest));
  }

  @override
  bool shouldRelayout(_AnchoredAboveLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.gap != gap ||
      oldDelegate.minimumTop != minimumTop;
}
