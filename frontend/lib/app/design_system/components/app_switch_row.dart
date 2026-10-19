import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:flutter/material.dart';

/// A titled switch with one line of explanation, read by a screen reader as
/// one switch: the title and the line are its label, and the state is its
/// toggled value.
class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    required this.value,
    required this.title,
    required this.onChanged,
    this.summary,
    super.key,
  });

  final bool value;
  final String title;
  final String? summary;

  /// Null draws the switch disabled.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: Text(title, style: context.tokens.typography.body),
      subtitle: summary == null
          ? null
          : Text(
              summary!,
              style: context.tokens.typography.label.copyWith(
                color: context.tokens.colors.textMuted,
              ),
            ),
    ),
  );
}
