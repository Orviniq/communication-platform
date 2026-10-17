import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class SafetyNumberPage extends ConsumerStatefulWidget {
  const SafetyNumberPage({
    required this.userId,
    this.authentication,
    this.local,
    super.key,
  });

  final String userId;
  final PeerAuthenticationService? authentication;
  final ContactLocalPort? local;

  @override
  ConsumerState<SafetyNumberPage> createState() => _SafetyNumberPageState();
}

class _SafetyNumberPageState extends ConsumerState<SafetyNumberPage> {
  ContactTrustRecord? _trust;
  SafetyFingerprint? _fingerprint;
  var _busy = true;
  var _confirmedOutOfBand = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
      _confirmedOutOfBand = false;
    });
    final PeerAuthenticationService authentication =
        widget.authentication ??
        await ref.read(peerAuthenticationServiceProvider.future);
    final ContactLocalPort local =
        widget.local ?? await ref.read(contactLocalProvider.future);
    await authentication.refreshPeer(
      userId: widget.userId,
      requirePrekeys: false,
    );
    final trustResult = await local.readTrust(widget.userId);
    final fingerprintResult = await authentication.safetyFingerprint(
      widget.userId,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _trust = switch (trustResult) {
        Success<ContactTrustRecord?>(:final value) => value,
        _ => null,
      };
      _fingerprint = switch (fingerprintResult) {
        Success<SafetyFingerprint>(:final value) => value,
        _ => null,
      };
      _failed = _trust == null || _fingerprint == null;
    });
  }

  Future<void> _confirm() async {
    final trust = _trust;
    final identity = trust?.identity;
    if (!_confirmedOutOfBand ||
        identity == null ||
        !_canConfirm(trust!.state)) {
      return;
    }
    setState(() => _busy = true);
    final PeerAuthenticationService authentication =
        widget.authentication ??
        await ref.read(peerAuthenticationServiceProvider.future);
    final result = await authentication.confirmOutOfBand(
      userId: widget.userId,
      exactMasterPublic: identity.masterPublic,
    );
    if (!mounted) return;
    switch (result) {
      case Success(value: final verified):
        setState(() {
          _busy = false;
          _trust = verified;
          _confirmedOutOfBand = false;
          _failed = false;
        });
      case FailureResult():
        await _load();
    }
  }

  bool _canConfirm(ContactTrustState state) =>
      state == ContactTrustState.unverified ||
      state == ContactTrustState.masterKeyChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final trustState = _trust?.state ?? ContactTrustState.identityUnavailable;
    final fingerprint = _fingerprint;
    final canConfirm = _canConfirm(trustState);
    return Scaffold(
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          onPressed: () => context.pop(),
          kind: AppButtonKind.ghost,
        ),
        title: Text(strings.safetyTitle),
      ),
      body: _busy && fingerprint == null
          ? AppStatePanel.loading(title: strings.safetyRefreshing)
          : ListView(
              padding: AppInsets.belowAppBar(context, AppSpacing.x6),
              children: [
                Notice(
                  key: ValueKey('safety-state-${trustState.name}'),
                  kind: trustState == ContactTrustState.verified
                      ? AppStatusKind.success
                      : canConfirm
                      ? AppStatusKind.warning
                      : AppStatusKind.danger,
                  message: _trustMessage(strings, trustState),
                ),
                const SizedBox(height: AppSpacing.x4),
                Text(strings.safetyInstructions),
                if (fingerprint != null) ...[
                  const SizedBox(height: AppSpacing.x6),
                  _SafetyValue(
                    label: strings.safetyEmojiLabel,
                    value: fingerprint.emojiCode,
                    textDirection: TextDirection.ltr,
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  _SafetyValue(
                    label: strings.safetyNumberLabel,
                    value: fingerprint.numericCode,
                    textDirection: TextDirection.ltr,
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  Semantics(
                    image: true,
                    label: strings.safetyQrLabel,
                    child: Center(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(color: Colors.white),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.x3),
                          child: QrImageView(
                            key: const ValueKey('safety-qr'),
                            data: fingerprint.qrValue,
                            size: 220,
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                            semanticsLabel: strings.safetyQrLabel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (canConfirm && fingerprint != null) ...[
                  const SizedBox(height: AppSpacing.x6),
                  AppCheckboxRow(
                    value: _confirmedOutOfBand,
                    label: strings.safetyOutOfBandCheck,
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _confirmedOutOfBand = value),
                  ),
                  AppButton(
                    key: const ValueKey('safety-confirm'),
                    label: strings.safetyConfirmAction,
                    onPressed: _busy || !_confirmedOutOfBand ? null : _confirm,
                    leading: AppIcons.security,
                  ),
                ],
                if (_failed) ...[
                  const SizedBox(height: AppSpacing.x6),
                  AppButton(
                    label: strings.safetyRetryAction,
                    onPressed: _busy ? null : _load,
                    kind: AppButtonKind.outline,
                    leading: AppIcons.retry,
                  ),
                ],
              ],
            ),
    );
  }

  String _trustMessage(AppLocalizations strings, ContactTrustState state) =>
      switch (state) {
        ContactTrustState.unverified => strings.safetyUnverifiedState,
        ContactTrustState.verified => strings.safetyVerifiedState,
        ContactTrustState.masterKeyChanged => strings.safetyMasterChangedState,
        ContactTrustState.invalidDevice => strings.safetyInvalidDeviceState,
        ContactTrustState.deviceLogFork => strings.safetyForkState,
        ContactTrustState.identityUnavailable =>
          strings.safetyIdentityUnavailableState,
      };
}

class _SafetyValue extends StatelessWidget {
  const _SafetyValue({
    required this.label,
    required this.value,
    required this.textDirection,
  });

  final String label;
  final String value;
  final TextDirection textDirection;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $value',
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: context.tokens.colors.border),
        borderRadius: AppRadii.card,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: context.tokens.typography.label),
            const SizedBox(height: AppSpacing.x2),
            SelectableText(
              value,
              textDirection: textDirection,
              textAlign: TextAlign.center,
              style: context.tokens.typography.section,
            ),
          ],
        ),
      ),
    ),
  );
}
