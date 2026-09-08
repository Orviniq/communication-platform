import 'dart:async';

import 'package:communication_platform/app/config/sustained_delivery_gate.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_alerts.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/notifications/domain/message_alert_model.dart';
import 'package:communication_platform/features/synchronization/application/ports/sustained_delivery_ports.dart';
import 'package:communication_platform/features/synchronization/application/sustained_delivery.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sustained_delivery_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/platform_sustained_delivery_port.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The permanent entry's text, in the locale the application itself runs in.
///
/// Resolved through Flutter's own supported-locale resolution rather than left
/// to Android string resources, so that one catalogue is reviewed, one
/// catalogue is translated, and the shade can never speak a different language
/// from the screen behind it.
Future<SustainedDeliveryStrings> resolveSustainedDeliveryStrings() async {
  final locale = basicLocaleListResolution(
    WidgetsBinding.instance.platformDispatcher.locales,
    AppLocalizations.supportedLocales,
  );
  final l10n = await AppLocalizations.delegate.load(locale);
  return SustainedDeliveryStrings(
    title: l10n.sustainedNotificationTitle,
    channelName: l10n.sustainedChannelName,
    channelDescription: l10n.sustainedChannelDescription,
  );
}

/// How the application reaches the sustained-delivery service.
///
/// Only the Android artifact has an implementation behind it. Every other
/// target composes [UnsupportedSustainedDelivery], which reports *unavailable*
/// rather than a stand-in that quietly does nothing while looking like a
/// service.
final sustainedDeliveryPlatformProvider =
    Provider<SustainedDeliveryPlatformPort>(
      (ref) => defaultTargetPlatform == TargetPlatform.android
          ? const PlatformSustainedDeliveryPort(
              strings: resolveSustainedDeliveryStrings,
            )
          : const UnsupportedSustainedDelivery(),
    );

/// The one connection policy the delivery session's supervisor reads.
///
/// It lives above the session on purpose. A session composes and disposes with
/// the signed-in device; the user's arrangement with the operating system does
/// not, and a policy owned by the session would be re-created — and answer
/// *no* — every time a session restarted.
final sustainedConnectionPolicyProvider = Provider<SustainedConnectionPolicy>((
  ref,
) {
  final policy = SustainedConnectionPolicy();
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

/// Whether this build may offer sustained delivery at all (ADR-053).
///
/// It reads the compiled environment, which is fixed by the entry point and
/// cannot be selected at runtime, and the source-only evidence ledger in
/// [SustainedDeliveryGate]. There is no override: a build reaching a user is
/// withheld until the ledger says the capability has been measured on real
/// phones, and a development build is permitted so that the measuring can be
/// done at all.
final sustainedDeliveryAvailabilityProvider =
    Provider<SustainedDeliveryAvailability>(
      (ref) => SustainedDeliveryGate.availabilityIn(
        ref.watch(appEnvironmentProvider),
      ),
    );

/// Notifications, as the sustained-delivery enable flow needs them.
///
/// It adapts the one notification-permission implementation in the artifact
/// rather than adding a second, and it deliberately does not fall through to
/// the system settings screen: that is a navigation the surface performs, with
/// the user watching, not something a use case does behind their back.
final class MessageAlertGate implements SustainedDeliveryAlertGate {
  const MessageAlertGate(this._ref);

  final Ref _ref;

  @override
  Future<bool> ensureAlertsEnabled() async {
    final presenter = _ref.read(messageAlertPresenterProvider);
    final state = await presenter.requestPermission();
    return state?.authorization == MessageAlertAuthorization.granted;
  }
}

/// What sustained delivery is doing, as application state.
///
/// The status is always established from the platform rather than remembered,
/// because everything it depends on can be taken away without telling this
/// application: the user can withdraw the exemption or the notification
/// permission in system settings, and a manufacturer's battery management can
/// withdraw the first during a system update.
final sustainedDeliveryControllerProvider =
    NotifierProvider<SustainedDeliveryController, SustainedDeliveryStatus>(
      SustainedDeliveryController.new,
    );

/// `base` rather than `final` for one reason: the two surfaces this drives are
/// the only place in the application where a user is told what the operating
/// system will and will not do, and a widget test has to be able to render
/// every one of those states without a device behind it. `base` keeps the
/// hierarchy closed - nothing may `implements` this and every subclass must be
/// `base`, `final` or `sealed` - so a substitute is still a real controller
/// with this one's behaviour, not a structural imitation of it.
base class SustainedDeliveryController
    extends Notifier<SustainedDeliveryStatus> {
  Future<void> _work = Future<void>.value();
  bool _closed = false;
  bool _signedIn = false;

  /// Whether ADR-053's gate withholds the capability in this build.
  ///
  /// Read once, at build, because it is a compiled fact: the environment is
  /// fixed by the entry point and the evidence ledger is a source constant.
  bool _withheld = false;

  /// The last refusal the user asked for and did not get, so the surface can
  /// say which one it was. Cleared by any later successful transition.
  SustainedDeliveryRefusal? lastRefusal;

  /// The work queue, so a test can await a transition instead of pumping for it.
  @visibleForTesting
  Future<void> get settled => _work;

  @override
  SustainedDeliveryStatus build() {
    ref.onDispose(() => _closed = true);
    _withheld = !ref.read(sustainedDeliveryAvailabilityProvider).mayOffer;
    if (_withheld) {
      // Nothing is reconciled, nothing is started, and the authentication
      // listener is never attached, so no signed-in session can bring this
      // back. The one thing that does happen is a stand-down: an install
      // upgraded from a build that offered this may have left a service
      // running and a permanent entry displayed, and neither may outlive the
      // decision to withhold the capability. It does not clear the durable
      // choice, because the choice is the user's and a later evidenced build
      // is entitled to honour it.
      _enqueue(_standDown);
      return SustainedDeliveryStatus.withheld;
    }
    ref.listen(authenticationControllerProvider, (previous, next) {
      final signedIn = _deliverable(next);
      if (signedIn == _signedIn) {
        return;
      }
      _signedIn = signedIn;
      // Signing out stops the service without clearing the choice: there is
      // nothing to deliver to, and a permanent entry for an account nobody is
      // signed into announces the account rather than a message. Signing in
      // again is what reconciles it back on.
      _enqueue(signedIn ? _reconcile : _standDown);
    }, fireImmediately: true);
    return SustainedDeliveryStatus.off;
  }

  static bool _deliverable(AuthenticationViewState view) =>
      !view.isTearingDown &&
      switch (view.access) {
        AuthenticationRouteAccess.fullScope ||
        AuthenticationRouteAccess.offlineFullScope => true,
        _ => false,
      };

  /// Re-reads everything and makes the platform agree with the recorded choice.
  ///
  /// Called at start, whenever the application is resumed, and after every
  /// transition, because the two things this depends on are both changeable
  /// from outside the application and neither change is reported to it.
  Future<void> refresh() {
    if (_withheld) {
      // There is nothing to reconcile towards. Re-asserting the stand-down is
      // deliberate rather than a no-op: a resume is the moment to notice that
      // something outside this application started a service this build will
      // not stand behind.
      _enqueue(_standDown);
      return _work;
    }
    _enqueue(_signedIn ? _reconcile : _standDown);
    return _work;
  }

  Future<SustainedDeliveryRefusal?> enable() async {
    if (_withheld) {
      // Refused here, before the platform is asked anything at all. No dialog
      // is shown, no permission is requested, and no durable choice is written,
      // so an attempt to enable a withheld capability leaves the installation
      // exactly as it found it.
      lastRefusal = SustainedDeliveryRefusal.withheld;
      _publish(SustainedDeliveryStatus.withheld);
      return lastRefusal;
    }
    _enqueue(() async {
      final outcome = await EnableSustainedDelivery(
        platform: ref.read(sustainedDeliveryPlatformProvider),
        store: await _store(),
        alerts: MessageAlertGate(ref),
      ).call();
      switch (outcome) {
        case SustainedDeliveryEnabled(:final state):
          lastRefusal = null;
          _publish(state.statusFor(chosen: true));
        case SustainedDeliveryRefused(:final refusal):
          lastRefusal = refusal;
          // Whatever the platform now says, said plainly. A refusal never
          // leaves a durable choice behind, so this settles on *off* unless
          // something outside this flow had already turned it on.
          await _reconcile();
      }
    });
    await _work;
    return lastRefusal;
  }

  Future<void> disable() {
    _enqueue(() async {
      lastRefusal = null;
      _publish(
        await DisableSustainedDelivery(
          platform: ref.read(sustainedDeliveryPlatformProvider),
          store: await _store(),
        ).call(),
      );
    });
    return _work;
  }

  /// Opens the manufacturer's own screen. Nothing is reported back and nothing
  /// is recorded: this application cannot read those settings and must never
  /// appear to have confirmed them.
  Future<void> openVendorSettings() =>
      ref.read(sustainedDeliveryPlatformProvider).openVendorSettings();

  Future<void> _reconcile() async {
    _publish(
      await ReconcileSustainedDelivery(
        platform: ref.read(sustainedDeliveryPlatformProvider),
        store: await _store(),
      ).call(),
    );
  }

  /// Stops the service without touching the recorded choice.
  Future<void> _standDown() async {
    final platform = ref.read(sustainedDeliveryPlatformProvider);
    final state = await platform.platformState();
    if (state != null && state.running) {
      await platform.stop();
    }
    _publish(
      state == null
          ? SustainedDeliveryStatus.unavailable
          : SustainedDeliveryStatus.off,
    );
  }

  /// What a status becomes once ADR-053's gate has had its say.
  ///
  /// The gate outranks every platform reading. A withheld build reports
  /// *withheld* whatever the operating system would otherwise permit, because
  /// the question the user is owed an answer to is not "could this phone do
  /// it" but "will this build ask it to".
  SustainedDeliveryStatus _gated(SustainedDeliveryStatus status) =>
      _withheld ? SustainedDeliveryStatus.withheld : status;

  Future<SustainedDeliveryStorePort> _store() async =>
      DriftSustainedDeliveryStore(await ref.read(localDatabaseProvider.future));

  void _enqueue(Future<void> Function() work) {
    _work = _work.then((_) async {
      if (_closed) {
        return;
      }
      try {
        await work();
      } on Object {
        // Protected storage is unavailable, most plausibly. Nothing durable is
        // changed and nothing is claimed; the surface reports what it can see.
        _publish(SustainedDeliveryStatus.unavailable);
      }
    });
  }

  /// Publishes the status and tells the delivery supervisor, in that order.
  ///
  /// The supervisor is told through the policy rather than by watching this
  /// notifier, so that a session composed later reads the same object and a
  /// session already running is woken by it.
  void _publish(SustainedDeliveryStatus status) {
    if (_closed) {
      return;
    }
    final gated = _gated(status);
    state = gated;
    ref.read(sustainedConnectionPolicyProvider).update(gated);
  }
}
