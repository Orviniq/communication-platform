import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/synchronization/domain/history_transfer_model.dart';
import 'package:flutter/material.dart';

/// Honest recovery status: identity recovery and local-history availability
/// are deliberately shown as separate outcomes.
final class HistoryTransferStatusView extends StatelessWidget {
  const HistoryTransferStatusView({required this.state, super.key});

  final HistoryTransferState state;

  @override
  Widget build(BuildContext context) {
    final (title, detail, kind) = switch (state) {
      HistoryTransferState.identityRecovered => (
        'Identity recovered',
        'Your identity is ready. Message history has not been restored.',
        AppStatusKind.success,
      ),
      HistoryTransferState.waitingForSource => (
        'Waiting for an existing device',
        'Keep an authorized device online to send the history it holds.',
        AppStatusKind.information,
      ),
      HistoryTransferState.transferring => (
        'Transferring device history',
        'History is moving directly between your devices.',
        AppStatusKind.information,
      ),
      HistoryTransferState.partialTransfer => (
        'Partial history transferred',
        'The source device only held part of your history.',
        AppStatusKind.warning,
      ),
      HistoryTransferState.noSource => (
        'No history source available',
        'The server has no history copy. You can continue without old messages.',
        AppStatusKind.warning,
      ),
      HistoryTransferState.groupReinviteRequired => (
        'Groups arrive from their members',
        "A group appears on this device once a member sends it the group's "
            'current state.',
        AppStatusKind.information,
      ),
      HistoryTransferState.queueGapRecovery => (
        'Recovering a queue gap',
        'Live synchronization must recover before setup is complete.',
        AppStatusKind.warning,
      ),
      HistoryTransferState.done => (
        'Device setup complete',
        'Available local history has been stored on this device.',
        AppStatusKind.success,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppStatusBadge(kind: kind, label: title),
            const SizedBox(height: AppSpacing.x3),
            Text(detail, style: context.tokens.typography.body),
          ],
        ),
      ),
    );
  }
}
