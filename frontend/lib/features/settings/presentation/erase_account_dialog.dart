import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_scaffold.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens the erase-account confirmation over [context].
///
/// The barrier is deliberately not a way out. A statement dialog may be
/// dismissed by tapping beside it; this one holds a typed password, and losing
/// it to a stray tap on the way to the button is a worse outcome than one more
/// deliberate press of Cancel.
Future<void> showEraseAccountDialog(BuildContext context) =>
    showAppContentDialog<void>(
      context: context,
      title: AppLocalizations.of(context).eraseAccountConfirmTitle,
      dismissible: false,
      content: const EraseAccountForm(),
    );

/// What the erasure costs, what it does not reach, and the password that
/// authorizes it.
///
/// The four statements are the requirement, not decoration around it
/// (`backend/SECURITY.md` § "Best-effort features, worded honestly", and
/// `CLIENT_WORK.md` § "The wording is part of the requirement"). Three deletion
/// meanings are kept apart everywhere in this system, and a confirmation that
/// said "erase my messages" without the second statement would collapse two of
/// them: what this reaches is one server's rows, and every message this account
/// sent was decrypted on somebody else's phone and is stored there.
///
/// The actions live inside the form rather than in the dialog's action row,
/// because both of them depend on state this widget owns — whether a password
/// has been typed, and whether a call is in flight.
final class EraseAccountForm extends ConsumerStatefulWidget {
  const EraseAccountForm({super.key});

  @override
  ConsumerState<EraseAccountForm> createState() => _EraseAccountFormState();
}

final class _EraseAccountFormState extends ConsumerState<EraseAccountForm> {
  final TextEditingController _password = TextEditingController();
  bool _busy = false;

  /// The refusal to word, when the last attempt was refused.
  ///
  /// [AccountErased] never lands here: it closes the dialog. Holding an outcome
  /// rather than a rendered string keeps the wording in `build`, where the
  /// locale is, so a language change mid-dialog re-renders in the new one.
  AccountErasureOutcome? _refusal;

  /// The reviewed string for an ordinary failure — offline, a `500`, storage
  /// gone — which is a different thing from the route refusing the request.
  AuthenticationMessage? _failure;

  @override
  void dispose() {
    // Cleared before disposal, like every other password field in this
    // application: the controller's own `dispose` drops the reference but
    // leaves the characters where they were.
    _password
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _erase() async {
    if (_busy || _password.text.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _refusal = null;
      _failure = null;
    });
    final outcome = await ref
        .read(authenticationControllerProvider.notifier)
        .erase(password: _password.text);
    if (!mounted) {
      return;
    }
    if (outcome is AccountErased) {
      // The account is gone and the session went with it. Closing is all this
      // widget owes: the route guard reads the signed-out access the controller
      // has already written and lands on the sign-in screen.
      _password.clear();
      popAppModal(context);
      return;
    }
    setState(() {
      _busy = false;
      _refusal = outcome;
      _failure = outcome == null
          ? ref.read(authenticationControllerProvider).message
          : null;
      if (outcome != null) {
        // A refused password is not a password to try again unchanged, and a
        // cool-off outlives this dialog. Either way the field starts empty.
        _password.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = context.tokens;
    final error = _errorText(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Statement(l10n.eraseAccountServerScope),
        // The one the rule is about, and the one a reader skimming a
        // confirmation is likeliest to skip, so it carries the warning colour
        // the rest do not. Colour is the emphasis and never the meaning: the
        // sentence says what it says with the styling stripped off.
        _Statement(l10n.eraseAccountPeerCopies, emphasis: true),
        _Statement(
          l10n.eraseAccountAttachments(
            AccountErasureDisclosure.attachmentRetentionDays,
          ),
        ),
        _Statement(l10n.eraseAccountUsernameFreed),
        const SizedBox(height: AppSpacing.x2),
        AppField(
          key: const ValueKey('erase-account-password'),
          label: l10n.eraseAccountPasswordLabel,
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          error: error,
          textInputAction: TextInputAction.done,
          // No autofill hint. The saved credential belongs to signing in, and
          // offering it here would put the password one tap from the button
          // that spends it.
          autofillHints: const [],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _erase(),
          maxLength: AuthenticationInputPolicy.maximumPasswordLength,
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          l10n.eraseAccountPasswordPurpose,
          style: tokens.typography.compact.copyWith(
            color: tokens.colors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.x6),
        AppButton(
          key: const ValueKey('erase-account-confirm'),
          label: _busy
              ? l10n.eraseAccountWorkingAction
              : l10n.eraseAccountAction,
          kind: AppButtonKind.danger,
          onPressed: _busy || _password.text.isEmpty ? null : _erase,
        ),
        const SizedBox(height: AppSpacing.x2),
        AppButton(
          key: const ValueKey('erase-account-cancel'),
          label: l10n.settingsCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: _busy ? null : () => popAppModal(context),
        ),
      ],
    );
  }

  /// The refusal, in this application's own words.
  ///
  /// Never a server string: the route's `detail` is English prose written for
  /// an operator, and the same `throttled` code carries both the account's
  /// ordinary rate limit and the per-name lock, so the text is the one thing
  /// about the answer that may not be shown or branched on.
  String? _errorText(AppLocalizations l10n) {
    if (_failure case final message?) {
      return authenticationMessageText(l10n, message);
    }
    return switch (_refusal) {
      AccountErasurePasswordRejected(
        :final attemptsUsed,
        :final attemptsAllowed,
      ) =>
        l10n.eraseAccountWrongPassword(attemptsUsed, attemptsAllowed),
      AccountErasureLocked(retryAfter: final wait?) =>
        l10n.eraseAccountThrottled(_wait(l10n, wait)),
      AccountErasureLocked() => l10n.eraseAccountThrottledUnknownWait,
      AccountErased() || null => null,
    };
  }

  /// `Retry-After`, rounded *up*.
  ///
  /// Rounding down would name a moment the server still refuses, which costs
  /// the user a second refusal and teaches them the wait is not real.
  String _wait(AppLocalizations l10n, Duration wait) {
    final seconds = wait.inSeconds;
    if (seconds >= Duration.secondsPerMinute) {
      return l10n.eraseAccountWaitMinutes(
        (seconds + Duration.secondsPerMinute - 1) ~/ Duration.secondsPerMinute,
      );
    }
    return l10n.eraseAccountWaitSeconds(seconds < 1 ? 1 : seconds);
  }
}

final class _Statement extends StatelessWidget {
  const _Statement(this.text, {this.emphasis = false});

  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: Text(
        text,
        style: tokens.typography.body.copyWith(
          color: emphasis ? tokens.colors.warning : null,
        ),
      ),
    );
  }
}
