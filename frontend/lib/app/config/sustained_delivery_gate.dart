import 'package:communication_platform/app/config/app_environment.dart';
import 'package:flutter/foundation.dart';

/// The release gate for ADR-051's opt-in sustained delivery: the capability may
/// not be offered to a user until it has been measured on the phones that user
/// actually has.
///
/// ## Why this exists
///
/// Sustained delivery rests on two things the platform *permits* and never
/// *guarantees* — that a foreground service keeps running, and that an exempt
/// app keeps its network through Doze — and on a third thing the platform does
/// not govern at all: whether the manufacturer of the phone leaves the process
/// alone. Roughly nine in ten Android devices in this deployment's country are
/// made by two manufacturers whose own documentation says they suspend
/// background applications on their own schedule. None of that is knowable from
/// documentation, from source, or from a host test. It is knowable only by
/// measurement, and no measurement has been made.
///
/// ADR-046 held that this layer may not be enabled in a distributed artifact
/// before that matrix had been run. ADR-051 removed that clause on the argument
/// that the matrix could not be run in the environment available, so keeping it
/// would cancel the capability rather than defer it. ADR-053 restores it, on the
/// ground that "we cannot measure this" is a reason to withhold a capability
/// from users, never a reason to ship it: the cost of being wrong is a person
/// who was told their messages would arrive and did not get them.
///
/// ## What kind of gate this is
///
/// There is deliberately no environment define, no remote value, no runtime
/// setter and no debug override. Opening this gate means editing this file to
/// add [SustainedDeliveryFieldEvidence] for every mandatory
/// [SustainedDeliveryFleetCell], and each record has to survive
/// [SustainedDeliveryFieldEvidence.isAdmissible] — which refuses an emulator,
/// refuses a run shorter than the criteria require, and refuses a cell that was
/// reasoned about rather than run. An inadmissible record does not open
/// anything; it is simply not counted.
///
/// The criteria, the matrix, the measurement procedure and the current results
/// are in `docs/sustained-delivery-validation.md`.
/// `test/architecture/sustained_delivery_gate_test.dart` fails if this gate
/// opens without them.
final class SustainedDeliveryGate {
  const SustainedDeliveryGate._({required this.evidence});

  /// The one instance the application reads.
  ///
  /// The list is empty. Nothing about this capability has been observed on any
  /// hardware, on any platform version, on any date — see ADR-053 and
  /// `docs/sustained-delivery-validation.md` for what was and was not run.
  static const releaseAssertion = SustainedDeliveryGate._(
    evidence: <SustainedDeliveryFieldEvidence>[],
  );

  /// Every field measurement recorded for this capability, in the order it was
  /// obtained.
  final List<SustainedDeliveryFieldEvidence> evidence;

  /// A gate over a hypothetical ledger, so that a test can prove the mechanism
  /// works rather than only that the real ledger is empty.
  ///
  /// The application never calls this. It reads [releaseAssertion] and nothing
  /// else, so no build can be handed a ledger at runtime.
  @visibleForTesting
  static SustainedDeliveryGate forEvidence(
    List<SustainedDeliveryFieldEvidence> evidence,
  ) => SustainedDeliveryGate._(evidence: evidence);

  /// The admissible record for [cell], or null when that cell has none.
  ///
  /// Inadmissible records are not returned. That is the whole mechanism by
  /// which an emulator result, or a run that stopped early, cannot stand in for
  /// a cell: it may be written down here for the record, and it still opens
  /// nothing.
  SustainedDeliveryFieldEvidence? evidenceFor(SustainedDeliveryFleetCell cell) {
    for (final record in evidence) {
      if (record.cell == cell && record.isAdmissible) {
        return record;
      }
    }
    return null;
  }

  /// Whether every mandatory cell of the matrix has an admissible record.
  ///
  /// A partially satisfied matrix opens nothing. There is no "mostly", and
  /// there is no per-cell release: a user's phone is one cell, and the point of
  /// the matrix is that this deployment does not know which one.
  bool get isOpen => SustainedDeliveryFleetCell.values
      .where((cell) => cell.mandatory)
      .every((cell) => evidenceFor(cell) != null);

  /// The cells that still have no admissible record.
  List<SustainedDeliveryFleetCell> get outstanding => SustainedDeliveryFleetCell
      .values
      .where((cell) => cell.mandatory && evidenceFor(cell) == null)
      .toList(growable: false);

  /// What this build may do with the capability.
  ///
  /// Production is what reaches a user, so it is withheld until the gate opens.
  /// Development is the flavour the measurement itself runs on: it carries its
  /// own application ID, is never handed to anybody, and has to be able to run
  /// the capability or the matrix could never be run at all. That deliberately
  /// includes a development *release* build, because whether a headless engine
  /// starts an entry point in an AOT snapshot is one of the things the matrix
  /// has to answer and a debug build cannot.
  static SustainedDeliveryAvailability availabilityIn(
    AppEnvironment environment,
  ) {
    if (releaseAssertion.isOpen) {
      return SustainedDeliveryAvailability.evidenced;
    }
    return switch (environment) {
      AppEnvironment.development =>
        SustainedDeliveryAvailability.measurementOnly,
      AppEnvironment.production => SustainedDeliveryAvailability.withheld,
    };
  }
}

/// What a build may do with sustained delivery.
enum SustainedDeliveryAvailability {
  /// The matrix has been run and recorded. The capability is offered.
  evidenced,

  /// A non-distributed development build, where the capability runs so that it
  /// can be measured. A result obtained here is a result about this build; what
  /// it does and does not say about the distributed artifact is argued in
  /// ADR-053, not assumed.
  measurementOnly,

  /// The evidence is absent, so the capability is not offered. Nothing starts,
  /// nothing is requested, nothing is displayed, and anything a previous
  /// install left running is stopped.
  withheld;

  /// Whether this build may offer the capability to whoever is holding it.
  bool get mayOffer => this != SustainedDeliveryAvailability.withheld;
}

/// One cell of the validation matrix.
///
/// Derived from Statcounter's Iranian fleet distribution for July 2026, read
/// 2026-08-23; the derivation, the figures and what the matrix does not cover
/// are in `docs/sustained-delivery-validation.md`. The axes are manufacturer
/// and platform-version band, because those are the two things the evidence
/// says the answer depends on: the manufacturer decides whether the process is
/// allowed to live, and the platform version decides which of the freezer,
/// the eight-day restricted bucket and the typed-foreground-service rules
/// apply at all.
enum SustainedDeliveryFleetCell {
  /// Samsung on Android 11 or 12. Before the eight-day restricted bucket, and
  /// before typed foreground services.
  samsungAndroid11To12(mandatory: true),

  /// Samsung on Android 13, running One UI 5.x — the single largest cell, and
  /// the one Samsung's own foreground-service statement does not cover.
  samsungAndroid13(mandatory: true),

  /// Samsung on Android 14 or later, running One UI 6.0 or later — the one
  /// configuration in this matrix for which a manufacturer has published a
  /// statement of intent.
  samsungAndroid14Plus(mandatory: true),

  /// Xiaomi on Android 11 or 12 (MIUI 13/14).
  xiaomiAndroid11To12(mandatory: true),

  /// Xiaomi on Android 13 (MIUI 14).
  xiaomiAndroid13(mandatory: true),

  /// Xiaomi on Android 14 or later (HyperOS). Xiaomi publishes nothing about
  /// foreground services at all, so nothing about this cell is predictable.
  xiaomiAndroid14Plus(mandatory: true),

  /// A device whose background behaviour is the platform's own, with no
  /// manufacturer layer over it — a Pixel, or an AOSP build.
  ///
  /// Mandatory, and for a reason that is not coverage: without it a failure
  /// anywhere else cannot be attributed. A capability that fails on Samsung and
  /// on the platform reference is broken; one that fails on Samsung alone is
  /// a manufacturer deviation. Those are different findings with different
  /// remedies, and one run cannot distinguish them.
  platformReference(mandatory: true);

  const SustainedDeliveryFleetCell({required this.mandatory});

  /// Whether the gate requires an admissible record for this cell.
  final bool mandatory;
}

/// One recorded field measurement: what was run, on what, for how long, when.
///
/// Every field is a fact somebody wrote down after watching a phone. There is
/// deliberately no field for a conclusion, a confidence, or an expectation:
/// this type records observations, and [SustainedDeliveryGate.isOpen] is the
/// only thing that draws anything from them.
final class SustainedDeliveryFieldEvidence {
  const SustainedDeliveryFieldEvidence({
    required this.cell,
    required this.hardware,
    required this.platformVersion,
    required this.vendorSkin,
    required this.observedOn,
    required this.emulated,
    required this.vendorStepPerformed,
    required this.holdingHours,
    required this.deliveriesObserved,
    required this.repetitions,
    required this.runRecord,
  });

  /// Which cell of the matrix this record belongs to.
  final SustainedDeliveryFleetCell cell;

  /// The device, as its own build reports it: manufacturer and model.
  final String hardware;

  /// The platform release and API level, as the device reports them.
  final String platformVersion;

  /// The manufacturer's own software version — "One UI 6.1", "HyperOS 2.0" —
  /// or an empty string on a device that has none.
  final String vendorSkin;

  /// The date the run finished, as `YYYY-MM-DD`.
  final String observedOn;

  /// Whether this was an emulator rather than a phone.
  ///
  /// An emulated record is never admissible. It may be recorded — an emulator
  /// answers real questions about the platform's own behaviour — but it can
  /// never stand in for a cell, because the question every cell asks is what a
  /// manufacturer's build does, and an emulator has no manufacturer.
  final bool emulated;

  /// Whether the user-performed manufacturer step had been done on this device
  /// when the run started.
  ///
  /// Recorded rather than required. A cell that holds only when the step has
  /// been performed is a different finding from one that holds either way, and
  /// this deployment's users are people who do not repeat setup.
  final bool vendorStepPerformed;

  /// How many hours the service and its connection were observed to be
  /// continuously up, in the shortest of the [repetitions] runs.
  final int holdingHours;

  /// How many message deliveries were timed on this device, in Doze.
  final int deliveriesObserved;

  /// How many independent runs were made, each from a fresh enable.
  final int repetitions;

  /// The path of the machine-readable run record under
  /// `docs/validation/sustained-delivery/`, relative to `frontend/`.
  final String runRecord;

  /// The thresholds from `docs/sustained-delivery-validation.md`, fixed on
  /// 2026-08-23 before any measurement, in the one place code can enforce them.
  static const minimumHoldingHours = 24;
  static const minimumDeliveries = 20;
  static const minimumRepetitions = 3;

  /// Whether this record may count towards opening the gate.
  ///
  /// Each clause refuses a specific way a matrix turns into decoration: an
  /// emulator standing in for hardware, a run too short to reach the conditions
  /// that take hours to appear, a single observation presented as a property,
  /// and a row with nothing behind it.
  bool get isAdmissible =>
      !emulated &&
      hardware.trim().isNotEmpty &&
      platformVersion.trim().isNotEmpty &&
      _isIsoDate(observedOn) &&
      runRecord.trim().isNotEmpty &&
      holdingHours >= minimumHoldingHours &&
      deliveriesObserved >= minimumDeliveries &&
      repetitions >= minimumRepetitions;

  /// A strict `YYYY-MM-DD`.
  ///
  /// `DateTime.parse` normalises an out-of-range date rather than rejecting it —
  /// `2026-13-45` becomes a real day in 2027 — so the parsed value is compared
  /// back against the digits. A date nobody could have observed on is not a
  /// date this ledger accepts.
  static bool _isIsoDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return false;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return false;
    }
    final year = parsed.year.toString().padLeft(4, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '$year-$month-$day' == value;
  }
}
