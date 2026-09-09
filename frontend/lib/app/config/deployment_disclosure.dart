import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';

/// The maturity of one user-facing surface, relative to the maturity the whole
/// application declares.
///
/// There is deliberately no value meaning "more mature than the application
/// label". An unlabelled surface is covered by that label and by nothing
/// stronger; a badge reading "supported", "stable", "verified" or "audited"
/// would be a claim nobody outside the project has assessed. Every value here
/// therefore reads *down* from the application label, never up (ADR-045).
enum SurfaceMaturity {
  /// The surface really transmits and really encrypts, using a maintained
  /// implementation, but its cryptography is neither reviewed nor standardised
  /// and the state it produces is disposable by decision (ADR-036, ADR-040).
  experimental,

  /// The surface is routed and visible but has no implementation behind it.
  /// Nothing it appears to offer happens.
  notBuilt;

  String label(AppLocalizations l10n) => switch (this) {
    SurfaceMaturity.experimental => l10n.maturityExperimentalLabel,
    SurfaceMaturity.notBuilt => l10n.maturityNotBuiltLabel,
  };
}

/// One fact about a distributed artifact that a recipient's ordinary
/// expectations of a chat application would otherwise get wrong.
///
/// The set is deliberately short and deliberately free of cryptographic
/// detail. Ciphersuite identifiers, draft revisions and registry state are true
/// but unusable by a reader, and surrounding these consequences with them would
/// hide them (ADR-045).
///
/// [since] is the disclosure revision at which this point's text or its
/// presence last changed, and it is what makes re-presentation mechanical
/// rather than remembered. Editing a string fails the pinning test until
/// [since] is raised with it, and raising [since] raises
/// [DeploymentDisclosure.revision] through the invariant asserted in
/// `test/architecture/deployment_disclosure_test.dart`. A revision bump can
/// therefore no longer be forgotten, and a reader who accepted revision *n* is
/// shown exactly the points whose [since] exceeds it (ADR-052).
enum DisclosurePoint {
  /// Nothing here has been assessed by anyone outside the project. ADR-017 is
  /// open for every layer, pairwise included.
  noIndependentReview(since: 1),

  /// Delivery is immediate while the application is open and *best effort*
  /// otherwise: a deferred platform job at the fifteen-minute floor, deferred
  /// further by Doze, and stopped outright by the *rare* and *restricted*
  /// standby buckets, by Data Saver on a metered network, by a force-stop, and
  /// by a battery-restricted app. Revised at revision 2 when alerts arrived
  /// (ADR-048), at revision 3 when background catch-up did (ADR-049), at
  /// revision 4 when the opt-in sustained delivery capability did (ADR-051),
  /// and at revision 5 when Data Saver was added — it blocks the catch-up's
  /// network on exactly the connection most of these users pay for, and every
  /// earlier revision left it out of the application while stating it in the
  /// written handover (ADR-052).
  bestEffortDelivery(since: 5),

  /// The server's mailbox is a queue, not a store: an envelope the device never
  /// drains is pruned on the operator's retention timer and is then
  /// unrecoverable. Every revision before 5 described delivery only as slow,
  /// which an ordinary reader takes to mean eventual — so the difference
  /// between *late* and *never* was the one consequence the disclosure did not
  /// disclose. The client learns of the loss only as a `pruned_through`
  /// watermark, which it surfaces for groups and not for one-to-one
  /// conversations, so the text may not promise to name what was lost
  /// (ADR-052).
  ///
  /// Revised at revision 8, when `GET /api/v1/config` gave the client the
  /// number for the first time. Revision 5 could only say "a time set by
  /// whoever runs the server", because `ENVELOPE_TTL_DAYS` has no other
  /// observable — nothing refuses, so no error teaches it. The point now
  /// states the deployment's own window **and only its own**: until the route
  /// has answered, this build's default is a guess, and a guess in a mandatory
  /// statement is the class of claim ADR-052 was written to remove. So the
  /// wording without a number is kept for exactly that case rather than
  /// deleted.
  messagesExpireUnread(since: 8),

  /// The server stores no history, `allowBackup` is false and the database key
  /// is a non-exportable AndroidKeyStore key, so erasing app data is final.
  /// Narrowed at revision 5 from "the server keeps no copy" to "no copy of your
  /// history", because the mailbox does hold ciphertext in transit and a
  /// sentence a reader could catch out is a sentence that discredits the rest
  /// (ADR-052).
  deviceOnlyHistory(since: 5),

  /// The recovery backup carries cross-signing identity material only
  /// (ADR-030); history transfers device-to-device or not at all (ADR-028).
  recoveryExcludesHistory(since: 1),

  /// Revised at revision 6, when the group surface was withheld (ADR-055), and
  /// again at revision 7 when it reopened on one measured ABI (ADR-056).
  ///
  /// Revision 6 said group chats were switched off, which was true of every
  /// device. It is now true of only some, so the point carries both halves:
  /// ADR-036's disposable-state rule, which applies wherever the surface is
  /// available, and the fact that a phone whose processor has not been measured
  /// is withheld it instead. Neither half may be dropped — a reader whose
  /// groups work needs the first, and a reader whose groups are missing needs
  /// the second or will conclude the application is broken.
  experimentalGroups(since: 7),

  /// Surfaces that are routed and visible but not implemented. Revised at
  /// revision 5: it named search among them, and search is built — the chat
  /// list filters on name and latest message, and a conversation's own search
  /// reads that conversation's entire local history (ADR-052).
  unbuiltSurfaces(since: 5),

  /// Who this artifact is for, and who it is not for.
  intendedUse(since: 1);

  const DisclosurePoint({required this.since});

  /// The revision at which this point's wording or presence last moved.
  final int since;

  /// [limits] is what the deployment publishes, or this build's defaults when
  /// it has not answered yet. Only [messagesExpireUnread] reads it, and only to
  /// decide whether it may state a number at all.
  String text(AppLocalizations l10n, ServerConfig limits) => switch (this) {
    DisclosurePoint.noIndependentReview => l10n.disclosureNoIndependentReview,
    DisclosurePoint.bestEffortDelivery => l10n.disclosureBestEffortDelivery,
    DisclosurePoint.messagesExpireUnread =>
      limits.fromDeployment
          ? l10n.disclosureMessagesExpireUnreadDays(limits.envelopeTtlDays)
          : l10n.disclosureMessagesExpireUnread,
    DisclosurePoint.deviceOnlyHistory => l10n.disclosureDeviceOnlyHistory,
    DisclosurePoint.recoveryExcludesHistory =>
      l10n.disclosureRecoveryExcludesHistory,
    DisclosurePoint.experimentalGroups => l10n.disclosureExperimentalGroups,
    DisclosurePoint.unbuiltSurfaces => l10n.disclosureUnbuiltSurfaces,
    DisclosurePoint.intendedUse => l10n.disclosureIntendedUse,
  };
}

/// What a distributed build tells its recipients about itself, and the revision
/// of that statement.
///
/// The acknowledgement this drives is shown once, as the last step of device
/// enrollment, and is never repeated on a timer: repetition of an unchanged
/// warning measurably destroys it, and the damage generalises to the
/// application's other blocking security states. [revision] therefore exists to
/// make re-acknowledgement *content-triggered* — when what the build promises
/// changes, the revision changes.
///
/// Until ADR-052 that was the whole mechanism, and it stopped at the release
/// checklist: nothing recorded which revision a user had accepted, so an
/// existing recipient's install could not tell that what they agreed to had
/// moved, and the only remedy was an out-of-band step a human had to remember.
/// The accepted revision is now durable, and a build whose [revision] exceeds
/// it re-presents the statement once, marking the points that moved. The
/// written re-delivery stays release-blocking on top of that: it reaches the
/// people who have not installed the update, whom no in-application mechanism
/// can reach at all.
final class DeploymentDisclosure {
  const DeploymentDisclosure._({required this.revision, required this.points});

  /// The statement carried by the Private Experimental artifact (ADR-044).
  static const privateExperimental = DeploymentDisclosure._(
    revision: 8,
    points: [
      DisclosurePoint.noIndependentReview,
      DisclosurePoint.bestEffortDelivery,
      DisclosurePoint.messagesExpireUnread,
      DisclosurePoint.deviceOnlyHistory,
      DisclosurePoint.recoveryExcludesHistory,
      DisclosurePoint.experimentalGroups,
      DisclosurePoint.unbuiltSurfaces,
      DisclosurePoint.intendedUse,
    ],
  );

  /// Moves when, and only when, the text of any point or the composition of
  /// [points] moves, and it can no longer be moved by hand alone: it must equal
  /// the highest [DisclosurePoint.since] among [points]. Asserted by
  /// `test/architecture/deployment_disclosure_test.dart`.
  final int revision;

  /// Ordered by consequence: the reader is freshest at the top.
  final List<DisclosurePoint> points;

  /// What a reader who last accepted [acknowledgedRevision] has not seen.
  ///
  /// Empty when they are current. A reader with no durable record at all —
  /// everyone who enrolled before ADR-052 — passes 0 and gets the whole
  /// statement, which is the honest answer: nothing is known about what they
  /// were shown, so nothing may be assumed read.
  Set<DisclosurePoint> changedSince(int acknowledgedRevision) => {
    for (final point in points)
      if (point.since > acknowledgedRevision) point,
  };

  /// Whether a build carrying this statement owes [acknowledgedRevision] a
  /// second showing.
  bool requiresReacknowledgement(int acknowledgedRevision) =>
      acknowledgedRevision < revision;

  String title(AppLocalizations l10n) => l10n.disclosureBuildTitle;
}

/// Which builds carry a deployment disclosure, and which carry none.
///
/// Only a build that is handed to someone else needs to state what it is.
/// Production is unsigned and cannot be installed at all (ADR-042), and the
/// development flavor is never distributed and already names itself in its own
/// banner; neither of them may render the Private Experimental text, so the
/// wording of one build can never leak into the other.
extension AppDeploymentDisclosure on AppEnvironment {
  DeploymentDisclosure? get deploymentDisclosure => switch (this) {
    AppEnvironment.beta => DeploymentDisclosure.privateExperimental,
    AppEnvironment.development || AppEnvironment.production => null,
  };
}
