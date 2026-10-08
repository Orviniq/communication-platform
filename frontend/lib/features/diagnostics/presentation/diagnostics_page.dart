import 'package:communication_platform/app/dependencies/diagnostics.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The user-initiated diagnostics export.
///
/// What is on the screen is byte-for-byte what the copy button puts on the
/// clipboard. That is the design, not a convenience: a screen that showed a
/// friendly summary and copied something larger would be asking a person to
/// share a document they have not read, which is the failure mode this whole
/// surface exists to avoid. The report itself cannot contain a message, a name,
/// an address, a key or an identifier — see `diagnostics_report.dart` for why
/// that is a property of the type rather than of this screen.
///
/// Nothing leaves the device here. The application has no telemetry channel and
/// this screen adds none: it writes to the clipboard and stops, and where the
/// text goes next is the user's decision.
final class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({this.onCopy, super.key});

  /// Overridden in tests. Production uses the platform clipboard.
  final Future<void> Function(String text)? onCopy;

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  String? _copyMessage;

  Future<void> _copy(DiagnosticsReport report, AppLocalizations l10n) async {
    final text = report.render();
    var copied = true;
    try {
      final onCopy = widget.onCopy;
      if (onCopy != null) {
        await onCopy(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
    } on PlatformException {
      copied = false;
    } on MissingPluginException {
      copied = false;
    }
    if (!mounted) return;
    setState(
      () => _copyMessage = copied
          ? l10n.diagnosticsCopiedMessage
          : l10n.diagnosticsCopyFailed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = ref.watch(diagnosticsReportProvider);
    return Scaffold(
      key: const ValueKey('diagnostics-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings/about'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.diagnosticsTitle),
        actions: [
          AppIconButton(
            icon: AppIcons.retry,
            semanticLabel: l10n.diagnosticsRefreshAction,
            onPressed: () {
              setState(() => _copyMessage = null);
              ref.invalidate(diagnosticsReportProvider);
            },
            kind: AppButtonKind.ghost,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: report.when(
            loading: () =>
                AppStatePanel.loading(title: l10n.diagnosticsLoadingTitle),
            // The collector never throws — every source is guarded — so this
            // branch means the provider itself could not be created. It is a
            // stated outcome rather than a blank screen.
            error: (_, _) => AppStatePanel.error(
              title: l10n.diagnosticsTitle,
              message: l10n.diagnosticsCopyFailed,
              actionLabel: l10n.retryAction,
              onAction: () => ref.invalidate(diagnosticsReportProvider),
            ),
            data: (value) => _ReportView(
              report: value,
              copyMessage: _copyMessage,
              onCopy: () => _copy(value, l10n),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ReportView extends StatelessWidget {
  const _ReportView({
    required this.report,
    required this.copyMessage,
    required this.onCopy,
  });

  final DiagnosticsReport report;
  final String? copyMessage;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final message = copyMessage;
    return ListView(
      padding: AppInsets.belowAppBar(context, AppSpacing.x4),
      children: [
        Text(l10n.diagnosticsExplain, style: context.tokens.typography.body),
        const SizedBox(height: AppSpacing.x3),
        AppStatusBadge(
          kind: AppStatusKind.information,
          label: l10n.diagnosticsNothingSentNotice,
        ),
        const SizedBox(height: AppSpacing.x4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.tokens.colors.surfaceRaised,
            borderRadius: AppRadii.card,
            border: Border.all(color: context.tokens.colors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            // Horizontally scrollable rather than wrapped: a wrapped key/value
            // line is a line a reader can misread as two entries.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                report.render(),
                key: const ValueKey('diagnostics-report-text'),
                // The report is ASCII by construction and is read as a
                // technical document in both interface languages, so it is
                // rendered left to right whichever way the page runs.
                textDirection: TextDirection.ltr,
                style: context.tokens.typography.compact.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['monospace'],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.x4),
        AppButton(
          key: const ValueKey('diagnostics-copy'),
          label: l10n.diagnosticsCopyAction,
          leading: AppIcons.copy,
          onPressed: onCopy,
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x2),
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                key: const ValueKey('diagnostics-copy-message'),
                style: context.tokens.typography.compact.copyWith(
                  color: context.tokens.colors.textMuted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
