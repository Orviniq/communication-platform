/// Sustained delivery: the opt-in layer that keeps this application able to
/// receive while nobody is looking at it.
///
/// Everything here is a fact or a conclusion drawn from facts. Nothing in this
/// file promises anything, because the platform does not: what a foreground
/// service buys is that the process is not cached and therefore not frozen, and
/// what the battery-optimization exemption buys is network during Doze and
/// escape from the standby buckets that disable it. Both are *permissions*, and
/// a manufacturer can still end the process at any moment. The types below are
/// shaped so that the user-facing surface reports what is true right now rather
/// than what was arranged once (ADR-051).
library;

/// What the platform reports about sustained delivery, before any policy.
///
/// Every field is a question the operating system can actually answer. There is
/// deliberately no field for "the manufacturer will leave this alone": no
/// Android API reports it, so no value here may imply it.
final class SustainedDeliveryPlatformState {
  const SustainedDeliveryPlatformState({
    required this.supported,
    required this.running,
    required this.exempt,
    required this.alertsEnabled,
  });

  /// Whether this build has a sustained-delivery implementation behind it at
  /// all. False on a host test, on a future Web target, and on any build whose
  /// platform side is absent.
  final bool supported;

  /// Whether the foreground service is running in this process right now.
  final bool running;

  /// `PowerManager.isIgnoringBatteryOptimizations()`. Without it the device
  /// suspends network access in Doze and the standby buckets apply, so the
  /// connection this exists to hold is closed by the platform the first time
  /// the screen has been off for a while.
  final bool exempt;

  /// `NotificationManagerCompat.areNotificationsEnabled()`. Without it the
  /// user is told nothing when a message does arrive, which makes holding the
  /// connection pointless rather than merely degraded.
  final bool alertsEnabled;

  /// The one state the surface renders, derived rather than stored.
  ///
  /// Order matters and is by severity: the first thing that is wrong is the
  /// thing the user is told about, because fixing anything below it would
  /// change nothing while the one above it is unfixed.
  SustainedDeliveryStatus statusFor({required bool chosen}) {
    if (!supported) {
      return SustainedDeliveryStatus.unavailable;
    }
    if (!chosen) {
      return SustainedDeliveryStatus.off;
    }
    if (!alertsEnabled) {
      return SustainedDeliveryStatus.alertsWithheld;
    }
    if (!exempt) {
      return SustainedDeliveryStatus.exemptionWithdrawn;
    }
    if (!running) {
      return SustainedDeliveryStatus.stopped;
    }
    return SustainedDeliveryStatus.holding;
  }
}

/// What the user is shown about sustained delivery, and nothing more.
///
/// Four of these six are degradations, and each of them is a state the
/// application can genuinely observe. There is no value meaning "working
/// reliably", because the platform never says that.
enum SustainedDeliveryStatus {
  /// No implementation is composed. The surface says so instead of offering a
  /// switch that would do nothing.
  unavailable,

  /// The user has not turned it on. Nothing runs, nothing is held, nothing is
  /// requested and nothing appears anywhere.
  off,

  /// Turned on and the process is being kept alive by the foreground service.
  /// This is as good as it gets, and it is still not a guarantee.
  holding,

  /// Turned on, but the operating system will show no alert, so an arriving
  /// message would be received and never announced.
  alertsWithheld,

  /// Turned on, but the battery-optimization exemption is gone — revoked by the
  /// user, or by a manufacturer's own battery management, possibly during a
  /// system update. Delivery is back to the deferred catch-up.
  exemptionWithdrawn,

  /// Turned on and permitted, but the service is not running: the platform or
  /// the manufacturer ended it, or it has not been started again yet after a
  /// restart. Delivery is back to the deferred catch-up.
  stopped;

  /// Whether the connection may be held while the application is backgrounded.
  ///
  /// Only [holding] qualifies. A degraded state must never keep the socket
  /// open, because the thing that would keep the process alive to hold it is
  /// precisely the thing that is missing.
  bool get holdsConnection => this == SustainedDeliveryStatus.holding;

  /// Whether this state is the user's choice being honoured rather than a
  /// state they need to be told about.
  bool get settled =>
      this == SustainedDeliveryStatus.off ||
      this == SustainedDeliveryStatus.holding ||
      this == SustainedDeliveryStatus.unavailable;

  /// Whether the surface may offer a switch at all.
  ///
  /// The one state that answers no is the one where nothing the user does on
  /// this screen would change anything: there is no implementation behind it.
  bool get offersSwitch => this != SustainedDeliveryStatus.unavailable;
}

/// Why turning sustained delivery on did not finish.
///
/// Every value is a refusal the application observed, never one it assumed.
/// None of them leaves anything running, anything held, or a durable choice
/// recorded: an enable that did not complete is indistinguishable from one that
/// was never attempted.
enum SustainedDeliveryRefusal {
  /// This build has no sustained-delivery implementation.
  unavailable,

  /// The user did not allow notifications. Nothing further is requested,
  /// because a connection held for messages nobody is told about is a battery
  /// cost with no benefit.
  alertsRefused,

  /// The user did not grant the battery-optimization exemption. Without it the
  /// platform suspends network access in Doze, so the capability would claim
  /// something it cannot do.
  exemptionRefused,

  /// The platform refused to start the service, or its start could not be
  /// confirmed. This is the manufacturer-restriction case among others, and it
  /// is reported rather than retried.
  platformRefused,

  /// The choice could not be recorded, so it would not survive a restart.
  /// Nothing is started: a capability that is on until the next launch and then
  /// silently off is worse than one that never started.
  notRecorded,
}
