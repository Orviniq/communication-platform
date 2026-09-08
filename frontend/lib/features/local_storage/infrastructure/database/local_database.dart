// ignore_for_file: recursive_getters

import 'dart:convert';

import 'package:drift/drift.dart';

part 'local_database.g.dart';

abstract class _NamedTable extends Table {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class AccountSessions extends Table {
  @override
  String get tableName => 'account_session';

  IntColumn get singletonId =>
      integer().withDefault(const Constant(1)).check(singletonId.equals(1))();
  BlobColumn get userIdCiphertext => blob()();
  BlobColumn get deviceIdCiphertext => blob().nullable()();
  IntColumn get scope => integer().check(scope.isBetweenValues(0, 1))();
  BlobColumn get tokenMetadataCiphertext => blob()();
  BlobColumn get serverProfileCiphertext => blob()();
  DateTimeColumn get expiresAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {singletonId};
}

class SecureSecrets extends _NamedTable {
  @override
  String get tableName => 'secure_secrets';

  TextColumn get secretId => text()();
  IntColumn get kind => integer().check(kind.isBetweenValues(0, 31))();
  BlobColumn get wrappedCiphertextOrOpaqueHandle => blob()();
  IntColumn get formatVersion =>
      integer().check(formatVersion.isBiggerThanValue(0))();
  IntColumn get stateRevision => integer()
      .withDefault(const Constant(1))
      .check(stateRevision.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {secretId};
}

class AccountIdentities extends Table {
  @override
  String get tableName => 'account_identity';

  IntColumn get singletonId =>
      integer().withDefault(const Constant(1)).check(singletonId.equals(1))();
  BlobColumn get verifiedPublicStateCiphertext => blob()();
  IntColumn get backupVersion => integer()
      .withDefault(const Constant(0))
      .check(backupVersion.isBiggerOrEqualValue(0))();
  IntColumn get recoveryStatus =>
      integer().check(recoveryStatus.isBetweenValues(0, 4))();

  @override
  Set<Column<Object>> get primaryKey => {singletonId};
}

class EnrollmentIntents extends Table {
  @override
  String get tableName => 'enrollment_intent';

  TextColumn get userId => text()();
  IntColumn get flow => integer().check(flow.isBetweenValues(0, 1))();
  IntColumn get phase => integer().check(phase.isBetweenValues(0, 17))();
  BlobColumn get fingerprint => blob()();
  BlobColumn get deviceState => blob()();
  TextColumn get deviceId => text().nullable()();
  BlobColumn get identityState => blob().nullable()();
  BlobColumn get backup => blob().nullable()();
  IntColumn get backupVersion => integer()
      .withDefault(const Constant(1))
      .check(backupVersion.isBiggerThanValue(0))();
  IntColumn get identityVersion => integer()
      .withDefault(const Constant(1))
      .check(identityVersion.isBiggerThanValue(0))();
  IntColumn get expectedSequence => integer().nullable().check(
    expectedSequence.isNull() | expectedSequence.isBiggerOrEqualValue(0),
  )();
  BlobColumn get previousHash => blob().nullable()();
  BlobColumn get pendingLogRecord => blob().nullable()();
  IntColumn get message => integer().nullable().check(
    message.isNull() | message.isBetweenValues(0, 14),
  )();
  BoolColumn get recoverySecretDisplayed =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get recoveryConfirmed =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {userId};
}

class Users extends Table {
  @override
  String get tableName => 'users';

  TextColumn get userId => text()();
  BoolColumn get activated => boolean()();
  BlobColumn get directoryEntryCiphertext => blob()();
  IntColumn get localState =>
      integer().check(localState.isBetweenValues(0, 7))();

  @override
  Set<Column<Object>> get primaryKey => {userId};
}

class Profiles extends Table {
  @override
  String get tableName => 'profiles';

  TextColumn get userId =>
      text().references(Users, #userId, onDelete: KeyAction.cascade)();
  BlobColumn get profileCiphertext => blob()();
  IntColumn get version => integer().check(version.isBiggerOrEqualValue(0))();
  IntColumn get verificationState =>
      integer().check(verificationState.isBetweenValues(0, 4))();

  @override
  Set<Column<Object>> get primaryKey => {userId};
}

class Devices extends Table {
  @override
  String get tableName => 'devices';

  TextColumn get deviceId => text()();
  TextColumn get userId =>
      text().references(Users, #userId, onDelete: KeyAction.cascade)();
  BlobColumn get publicBundle => blob()();
  BlobColumn get etagCiphertext => blob().nullable()();
  BlobColumn get labelCiphertext => blob().nullable()();
  TextColumn get decryptedLabel => text().nullable()();
  IntColumn get revocationState =>
      integer().check(revocationState.isBetweenValues(0, 3))();
  IntColumn get bundleVersion => integer().nullable().check(
    bundleVersion.isNull() | bundleVersion.isBiggerThanValue(0),
  )();
  IntColumn get lastSignedPrekeyRotationUnixDay => integer()
      .withDefault(const Constant(0))
      .check(lastSignedPrekeyRotationUnixDay.isBiggerOrEqualValue(0))();
  TextColumn get createdDate => text().nullable()();
  BoolColumn get isCurrentDevice =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get ownerListing => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

/// Exact own-account log append retained before its non-idempotent POST.
class DeviceLogMutations extends Table {
  @override
  String get tableName => 'device_log_mutations';

  TextColumn get operationId => text()();
  TextColumn get userId => text()();
  IntColumn get mutationKind =>
      integer().check(mutationKind.isBetweenValues(0, 3))();
  TextColumn get targetDeviceId => text().nullable()();
  IntColumn get expectedSequence =>
      integer().check(expectedSequence.isBiggerOrEqualValue(0))();
  BlobColumn get previousHeadHash => blob()();
  BlobColumn get exactRecord => blob()();
  IntColumn get state => integer().check(state.isBetweenValues(0, 3))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

class SecurityPostures extends Table {
  @override
  String get tableName => 'security_posture';

  IntColumn get singletonId =>
      integer().withDefault(const Constant(1)).check(singletonId.equals(1))();
  // 0 normal, 1 globally-forked, 2 pending authenticated device change.
  IntColumn get state => integer().check(state.isBetweenValues(0, 2))();
  IntColumn get evidenceKind => integer().nullable().check(
    evidenceKind.isNull() | evidenceKind.isBetweenValues(0, 4),
  )();
  DateTimeColumn get detectedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {singletonId};
}

class DeviceLogRecords extends Table {
  @override
  String get tableName => 'device_log';

  TextColumn get userId =>
      text().references(Users, #userId, onDelete: KeyAction.cascade)();
  IntColumn get sequence => integer().check(sequence.isBiggerOrEqualValue(0))();
  BlobColumn get signedOpaqueRecord => blob()();
  BlobColumn get recordHash => blob()();
  IntColumn get forkState => integer().check(forkState.isBetweenValues(0, 2))();
  IntColumn get gossipState =>
      integer().check(gossipState.isBetweenValues(0, 3))();

  @override
  Set<Column<Object>> get primaryKey => {userId, sequence};
}

class PairwiseSessions extends Table {
  @override
  String get tableName => 'pairwise_sessions';

  TextColumn get localDeviceId => text()();
  TextColumn get remoteUserId => text().withDefault(const Constant(''))();
  TextColumn get remoteDeviceId => text()();
  BlobColumn get sessionId => blob().nullable()();
  BlobColumn get opaqueCryptoStateHandle => blob()();
  IntColumn get stateVersion =>
      integer().check(stateVersion.isBiggerThanValue(0))();
  IntColumn get skippedKeyCount => integer()
      .withDefault(const Constant(0))
      .check(skippedKeyCount.isBetweenValues(0, 2000))();
  IntColumn get disposition => integer()
      .withDefault(const Constant(0))
      .check(disposition.isBetweenValues(0, 1))();
  IntColumn get repairState => integer()
      .withDefault(const Constant(0))
      .check(repairState.isBetweenValues(0, 3))();
  BlobColumn get repairAuthorization => blob().nullable()();
  DateTimeColumn get lastAuthenticatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localDeviceId, remoteDeviceId};
}

/// The single receive-only session retained during simultaneous initiation.
class PairwiseSessionAlternates extends Table {
  @override
  String get tableName => 'pairwise_session_alternates';

  BlobColumn get sessionId => blob()();
  TextColumn get localDeviceId => text()();
  TextColumn get remoteUserId => text()();
  TextColumn get remoteDeviceId => text()();
  BlobColumn get opaqueCryptoStateHandle => blob()();
  IntColumn get stateVersion =>
      integer().check(stateVersion.isBiggerThanValue(0))();
  IntColumn get skippedKeyCount =>
      integer().check(skippedKeyCount.isBetweenValues(0, 2000))();
  IntColumn get repairState =>
      integer().check(repairState.isBetweenValues(0, 3))();
  BlobColumn get repairAuthorization => blob().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastAuthenticatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {localDeviceId, remoteDeviceId},
  ];
}

class Prekeys extends Table {
  @override
  String get tableName => 'prekeys';

  IntColumn get kind => integer().check(kind.isBetweenValues(0, 5))();
  IntColumn get keyId => integer().check(keyId.isBiggerOrEqualValue(0))();
  BlobColumn get privateStateHandle => blob()();
  IntColumn get uploadState =>
      integer().check(uploadState.isBetweenValues(0, 4))();
  IntColumn get useState => integer().check(useState.isBetweenValues(0, 4))();

  @override
  Set<Column<Object>> get primaryKey => {kind, keyId};
}

/// Resumable public/checkpoint projection for an authenticated native prekey plan.
@DataClassName('StoredPrekeyMaintenancePlan')
class PrekeyMaintenancePlans extends Table {
  @override
  String get tableName => 'prekey_maintenance_plans';

  TextColumn get deviceId => text()();
  IntColumn get stage => integer().check(stage.isBetweenValues(0, 2))();
  IntColumn get expectedStateRevision =>
      integer().check(expectedStateRevision.isBiggerThanValue(0))();
  IntColumn get preparedUnixDay =>
      integer().check(preparedUnixDay.isBiggerOrEqualValue(0))();
  IntColumn get bundleVersion =>
      integer().check(bundleVersion.isBiggerThanValue(0))();
  IntColumn get currentSignedPrekeyCreatedUnixDay => integer().check(
    currentSignedPrekeyCreatedUnixDay.isBiggerOrEqualValue(0),
  )();
  BlobColumn get batchId => blob()();
  BlobColumn get nativeUploadProjection => blob()();
  BlobColumn get exactLogRecord => blob().nullable()();
  IntColumn get expectedLogSequence => integer().nullable().check(
    expectedLogSequence.isNull() | expectedLogSequence.isBiggerOrEqualValue(0),
  )();
  BlobColumn get previousLogHead => blob().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

@DataClassName('StoredMlsKeyPackageMaintenanceState')
class MlsKeyPackageMaintenanceStates extends Table {
  @override
  String get tableName => 'mls_key_package_maintenance_states';

  TextColumn get deviceId => text()();
  // 0 idle, 1 prepared, 2 consumable attempt started, 3 ambiguous.
  IntColumn get stage => integer().check(stage.isBetweenValues(0, 3))();
  IntColumn get expectedStateRevision => integer()
      .withDefault(const Constant(0))
      .check(expectedStateRevision.isBiggerOrEqualValue(0))();
  IntColumn get plannedKind => integer().nullable().check(
    plannedKind.isNull() | plannedKind.isBetweenValues(0, 1),
  )();
  BlobColumn get exactUploadProjection => blob().nullable()();
  BoolColumn get lastResortUploaded =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

class MlsGroups extends Table {
  @override
  String get tableName => 'mls_groups';

  TextColumn get groupId => text()();
  BlobColumn get opaqueCryptoStateHandle => blob()();
  IntColumn get acceptedEpoch =>
      integer().check(acceptedEpoch.isBiggerOrEqualValue(0))();
  IntColumn get stateVersion =>
      integer().check(stateVersion.isBiggerThanValue(0))();
  IntColumn get queueGapRecoveryState => integer()
      .withDefault(const Constant(0))
      .check(queueGapRecoveryState.isBetweenValues(0, 2))();
  BlobColumn get controlProjectionCiphertext => blob().nullable()();
  IntColumn get controlRevision => integer()
      .withDefault(const Constant(0))
      .check(controlRevision.isBiggerOrEqualValue(0))();
  BlobColumn get controlStateHash => blob().nullable()();
  IntColumn get lifecycle => integer()
      .withDefault(const Constant(0))
      .check(lifecycle.isBetweenValues(0, 6))();
  TextColumn get pendingMutationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {groupId};
}

@DataClassName('StoredGroupControlEventRow')
class GroupControlEvents extends Table {
  @override
  String get tableName => 'group_control_events';

  TextColumn get eventId => text()();
  TextColumn get groupId =>
      text().references(MlsGroups, #groupId, onDelete: KeyAction.cascade)();
  IntColumn get revision => integer().check(revision.isBiggerThanValue(0))();
  BlobColumn get previousControlStateHash => blob().nullable()();
  BlobColumn get controlStateHash => blob()();
  BlobColumn get mlsCommitHash => blob().nullable()();
  IntColumn get epoch => integer().check(epoch.isBiggerOrEqualValue(0))();
  TextColumn get signerUserId => text()();
  TextColumn get signerDeviceId => text()();
  IntColumn get operationKind =>
      integer().check(operationKind.isBetweenValues(1, 8))();
  TextColumn get deterministicProjection => text().nullable()();
  BlobColumn get canonicalControl => blob()();
  BlobColumn get signature => blob()();
  BlobColumn get signedPayload => blob().nullable()();
  BlobColumn get signerAuthenticationProof => blob().nullable()();
  IntColumn get applyState =>
      integer().check(applyState.isBetweenValues(0, 2))();
  IntColumn get createdMs =>
      integer().check(createdMs.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {eventId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {groupId, revision},
  ];
}

@DataClassName('StoredGroupOutboundObjectRow')
class GroupOutboundObjects extends Table {
  @override
  String get tableName => 'group_outbound_objects';

  TextColumn get operationId => text()();
  TextColumn get groupId =>
      text().references(MlsGroups, #groupId, onDelete: KeyAction.cascade)();
  TextColumn get eventId => text()();
  IntColumn get epoch => integer().check(epoch.isBiggerOrEqualValue(0))();
  BlobColumn get mlsObject => blob()();
  TextColumn get recipientUserIdsJson =>
      text().withDefault(const Constant('[]'))();
  // 0 development preview only and never dispatched, 1 committed and awaiting
  // recipient-bound pairwise fan-out, 2 routed into the durable pairwise outbox.
  IntColumn get deliveryState =>
      integer().check(deliveryState.isBetweenValues(0, 2))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

class Conversations extends Table {
  @override
  String get tableName => 'conversations';

  TextColumn get conversationId => text()();
  IntColumn get kind => integer().check(kind.isBetweenValues(0, 2))();
  BlobColumn get listProjectionCiphertext => blob()();
  IntColumn get sortKey => integer()();
  BoolColumn get tombstoned => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get peerUserId => text().nullable()();
  TextColumn get lastActivityEventId => text().nullable()();
  IntColumn get unreadCount => integer()
      .withDefault(const Constant(0))
      .check(unreadCount.isBiggerOrEqualValue(0))();
  DateTimeColumn get mutedUntil => dateTime().nullable()();
  BlobColumn get draftCiphertext => blob().nullable()();
  BlobColumn get displayTitleCiphertext => blob().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

class Memberships extends Table {
  @override
  String get tableName => 'memberships';

  TextColumn get conversationId => text().references(
    Conversations,
    #conversationId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get userId =>
      text().references(Users, #userId, onDelete: KeyAction.cascade)();
  BlobColumn get rolePolicyProjectionCiphertext => blob()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, userId};
}

/// The one index the timeline is read through.
///
/// `conversation_id` is not the primary key, so every lookup by conversation
/// was a scan of every message this device holds for anybody. The three
/// ordering columns follow it in the order the timeline sorts by, which makes
/// the same index answer the `WHERE`, satisfy the `ORDER BY` in both
/// directions without a temporary B-tree, and cover the keyset cursor probe
/// outright.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS messages_conversation_ordering '
  'ON messages (conversation_id, ordering_ms, ordering_event_id, message_id)',
)
/// Pinned messages, and only pinned messages.
///
/// Partial on purpose: a pin is rare, so this index holds a handful of entries
/// rather than one per message, and an insert that is not pinned writes nothing
/// to it. The cost of that is that SQLite will only choose it for a query whose
/// `WHERE` contains the bare term `pinned` — a bound `pinned = ?` proves
/// nothing at prepare time — which is why the two callers spell the predicate
/// that way.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS messages_pinned_by_conversation '
  'ON messages (conversation_id, message_id) WHERE pinned',
)
/// Unread messages, and only unread messages.
///
/// `conversations.unread_count` is a conversation-level aggregate the projector
/// has to keep exactly equal to what a full rebuild would compute, and an
/// incremental apply cannot count what it did not project. Counting the rows
/// instead is only affordable if the count reads the rows it counts: through
/// `messages_conversation_ordering` it is one index entry **and one row lookup**
/// per message in the conversation, read or not. Partial, this holds only the
/// unread ones, and an insert that is not unread writes nothing to it.
///
/// `unread` is a column here as well as the predicate, and that is not
/// redundant. Without it SQLite keeps the query's own `unread` term as a filter,
/// needs the column to evaluate it, and visits the row: measured at 614 µs
/// against 431 µs over twenty thousand unread messages, and the plan says
/// `USING COVERING INDEX` only in the second form.
///
/// Partial carries the same catch as the pinned index: SQLite will only choose
/// it for a query whose `WHERE` contains the bare term `unread`, so the
/// projector spells it that way ([ADR-063](decisions.md)).
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS messages_unread_by_conversation '
  'ON messages (conversation_id, unread) WHERE unread',
)
class Messages extends Table {
  @override
  String get tableName => 'messages';

  TextColumn get messageId => text()();
  TextColumn get conversationId => text().references(
    Conversations,
    #conversationId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get currentEventId => text()();
  BlobColumn get projectionCiphertext => blob()();
  IntColumn get status => integer().check(status.isBetweenValues(0, 8))();
  IntColumn get revision => integer().check(revision.isBiggerOrEqualValue(0))();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get senderUserId => text().withDefault(const Constant(''))();
  TextColumn get senderDeviceId => text().withDefault(const Constant(''))();
  TextColumn get replyToMessageId => text().nullable()();
  BlobColumn get quoteFallbackCiphertext => blob().nullable()();
  IntColumn get orderingMs => integer().withDefault(const Constant(0))();
  TextColumn get orderingEventId => text().withDefault(const Constant(''))();
  IntColumn get timestampState => integer()
      .withDefault(const Constant(0))
      .check(timestampState.isBetweenValues(0, 1))();
  BoolColumn get deletedForEveryone =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get deletedForMe => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();

  /// Whether the user has already been alerted that this message arrived.
  ///
  /// Local, durable, and deliberately separate from [unread]: [unread] is what
  /// the timeline and the conversation badge project, while this marks the
  /// one-shot alert as spent. The isolate that alerts may not be the one that
  /// comes back, so an in-memory flag would re-alert after every restart. A
  /// projection rebuild writes messages through `insertOnConflictUpdate`, whose
  /// companion omits this column and therefore leaves it unchanged - the same
  /// mechanism that already preserves [starred].
  BoolColumn get alerted => boolean().withDefault(const Constant(false))();

  /// Whether this device has already told the sender it received this message.
  ///
  /// Local, durable, and one-shot for the same reason as [alerted], which it is
  /// modelled on. A delivered receipt is owed once per message; whether one is
  /// *owed* was previously re-derived on every projection rebuild from
  /// properties that never change — the message came from a peer, in a direct
  /// conversation — so every rebuild re-queued a receipt for every message the
  /// conversation had ever received. Each of those receipts is an event at the
  /// far end, which rebuilds that conversation, which re-queues its own, and
  /// two devices talking to each other sustain it indefinitely. This column is
  /// what makes "owed" a fact about what has happened rather than a restatement
  /// of what the message is. A projection rebuild writes messages through
  /// `insertOnConflictUpdate` with a companion that omits this column, which is
  /// the same mechanism that preserves [alerted] and [starred].
  BoolColumn get deliveredReceiptSent =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class MessageEvents extends Table {
  @override
  String get tableName => 'message_events';

  TextColumn get eventId => text()();
  TextColumn get messageId => text()();
  TextColumn get conversationId => text().references(
    Conversations,
    #conversationId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get eventKind =>
      integer().check(eventKind.isBetweenValues(0, 31))();
  BlobColumn get authenticatedCiphertext => blob()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {eventId};
}

/// Every authenticated version-1 event fact retained for deterministic rebuilds.
///
/// The index is what makes rebuilding one conversation cost that conversation
/// rather than the whole event log: `_rebuildConversation` asks for the
/// candidate events of one conversation, and without it that read scans every
/// event this device has ever stored, for anybody, and grows forever.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS application_events_conversation_apply_state '
  'ON application_events (conversation_id, apply_state)',
)
/// The sender-counter uniqueness check, which every applied event runs.
///
/// It has no conversation to narrow it — a replayed counter is a fact about a
/// device, not about a conversation — so without an index it reads every event
/// this device has ever stored, once per event applied, forever. The table is
/// append-only and the pair is very nearly unique, so the index costs one entry
/// per insert and turns the check into a seek that returns one row.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS application_events_sender_counter '
  'ON application_events (sender_device_id, sender_counter)',
)
class StoredApplicationEvents extends Table {
  @override
  String get tableName => 'application_events';

  TextColumn get eventId => text()();
  TextColumn get conversationId => text()();
  IntColumn get kind => integer().check(kind.isBetweenValues(1, 65535))();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();
  IntColumn get senderCounter =>
      integer().check(senderCounter.isBiggerThanValue(0))();
  IntColumn get createdMs =>
      integer().check(createdMs.isBiggerOrEqualValue(0))();
  IntColumn get orderingMs => integer()();
  BlobColumn get canonicalEvent => blob()();
  BlobColumn get bodyProjection => blob()();
  IntColumn get applyState =>
      integer().check(applyState.isBetweenValues(0, 5))();
  BoolColumn get localOrigin => boolean().withDefault(const Constant(false))();
  TextColumn get localDeviceId => text().withDefault(const Constant(''))();
  TextColumn get targetMessageId => text().nullable()();
  IntColumn get revision => integer().nullable().check(
    revision.isNull() | revision.isBiggerThanValue(0),
  )();
  DateTimeColumn get authenticatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {eventId};
}

/// Which logical messages each stored event is a fact about.
///
/// Derived state, and only an index: the authoritative fact is the event in
/// `application_events`, and everything read through here is read by joining
/// back to it. That is what makes a stale row harmless — it joins to nothing —
/// while a missing row is not, which is why the row is written in the same
/// statement sequence as the event and why a full rebuild rewrites the rows for
/// every fact it folds.
///
/// It exists because the projector needs the *other* direction. An event
/// carries the message it targets, but an incremental apply has to ask which
/// facts a message has, and the answer decides what that message projects to.
/// A `messageCreate` names its own message; an edit, delete, reaction or pin
/// names one target; a receipt names **many**, which is why this is a table and
/// not a column ([ADR-063](decisions.md)).
///
/// The primary key leads with `message_id`, so its implicit index answers the
/// only question asked of it and no second index is declared. There is
/// deliberately no foreign key: `event_id` would be an unindexed child key, and
/// SQLite would then scan this table on every write to `application_events` to
/// prove nothing was orphaned — the cost `attachments_by_message` exists to
/// stop ([ADR-062](decisions.md)).
class ApplicationEventTargets extends Table {
  @override
  String get tableName => 'application_event_targets';

  TextColumn get messageId => text()();
  TextColumn get eventId => text()();

  @override
  Set<Column<Object>> get primaryKey => {messageId, eventId};
}

/// Unknown future versions/kinds are retained but never projected.
class UnsupportedApplicationEvents extends Table {
  @override
  String get tableName => 'unsupported_application_events';

  TextColumn get recordKey => text()();
  TextColumn get eventId => text().nullable().unique()();
  TextColumn get conversationId => text().nullable()();
  IntColumn get version => integer().check(version.isBetweenValues(0, 255))();
  IntColumn get kind => integer().nullable().check(
    kind.isNull() | kind.isBetweenValues(0, 65535),
  )();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();
  IntColumn get senderCounter => integer().nullable().check(
    senderCounter.isNull() | senderCounter.isBiggerThanValue(0),
  )();
  IntColumn get applyState => integer()
      .withDefault(const Constant(0))
      .check(applyState.isBetweenValues(0, 2))();
  BlobColumn get retainedPayload => blob()();
  DateTimeColumn get authenticatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {recordKey};
}

class ApplicationSenderCounters extends Table {
  @override
  String get tableName => 'application_sender_counters';

  TextColumn get deviceId => text()();
  IntColumn get lastCounter => integer()
      .withDefault(const Constant(0))
      .check(lastCounter.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

class MessageReactions extends Table {
  @override
  String get tableName => 'message_reactions';

  TextColumn get messageId =>
      text().references(Messages, #messageId, onDelete: KeyAction.cascade)();
  TextColumn get reactingUserId => text()();
  TextColumn get eventId => text()();
  BlobColumn get emojiCiphertext => blob().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {messageId, reactingUserId};
}

/// A message's attachments.
///
/// The index is read by the timeline, which asks for the attachments of a whole
/// page at once — but it is paid for on the write path. `message_id` is a
/// foreign key into `messages` with `ON DELETE CASCADE` and `PRAGMA
/// foreign_keys` is on, so every write to a `messages` row makes SQLite prove
/// that no attachment is orphaned. Without an index on the child key that proof
/// is a full scan of this table, once per parent row: measured at 96 ms for one
/// rebuild of a 1200-message conversation, against 27 ms with the index.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS attachments_by_message '
  'ON attachments (message_id)',
)
class Attachments extends Table {
  @override
  String get tableName => 'attachments';

  TextColumn get attachmentId => text()();
  TextColumn get messageId =>
      text().references(Messages, #messageId, onDelete: KeyAction.cascade)();
  BlobColumn get encryptedDescriptor => blob()();
  IntColumn get transferState =>
      integer().check(transferState.isBetweenValues(0, 8))();
  BlobColumn get boundedCacheHandleCiphertext => blob().nullable()();
  DateTimeColumn get cacheExpiresAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {attachmentId};
}

class InboxEnvelopes extends Table {
  @override
  String get tableName => 'inbox_envelopes';

  TextColumn get envelopeId => text()();
  IntColumn get sequence =>
      integer().unique().check(sequence.isBiggerThanValue(0))();
  BlobColumn get envelopeCiphertext => blob()();
  IntColumn get processingState =>
      integer().check(processingState.isBetweenValues(0, 5))();
  BoolColumn get readyToAcknowledge =>
      boolean().withDefault(const Constant(false))();
  TextColumn get opaqueEventId => text().nullable()();
  IntColumn get dependencyClass => integer().nullable().check(
    dependencyClass.isNull() | dependencyClass.isBetweenValues(0, 1),
  )();
  IntColumn get attemptCount => integer()
      .withDefault(const Constant(0))
      .check(attemptCount.isBiggerOrEqualValue(0))();

  /// Failed inspections whose cause a later attempt cannot change.
  ///
  /// Deliberately not [attemptCount]. That column counts every begun attempt,
  /// inspection and acknowledgement alike, and drives retry backoff; it rises
  /// while a device is merely offline. This one rises only when the bytes
  /// themselves were refused, and it is what retires an envelope this device
  /// can never open into quarantine instead of leaving it to be re-served
  /// forever.
  IntColumn get inspectionFailures => integer()
      .withDefault(const Constant(0))
      .check(inspectionFailures.isBiggerOrEqualValue(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {envelopeId};
}

/// The per-recipient ciphertext waiting for the transport.
///
/// `event_id` is the second half of no key here — the primary key is the
/// operation and its recipient device — and it is how transport state is read
/// back for a message. Without the index that read scans the whole outbox.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS outbox_operations_by_event '
  'ON outbox_operations (event_id)',
)
class OutboxOperations extends Table {
  @override
  String get tableName => 'outbox_operations';

  TextColumn get operationId => text()();
  TextColumn get eventId => text()();
  TextColumn get recipientDeviceId => text()();
  TextColumn get recipientUserId => text().withDefault(const Constant(''))();
  IntColumn get batchIndex =>
      integer().check(batchIndex.isBiggerOrEqualValue(0))();
  BlobColumn get exactRecipientCiphertext => blob()();
  IntColumn get attemptState =>
      integer().check(attemptState.isBetweenValues(0, 6))();
  IntColumn get attemptCount => integer()
      .withDefault(const Constant(0))
      .check(attemptCount.isBiggerOrEqualValue(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  DateTimeColumn get terminalAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {operationId, recipientDeviceId};
}

class InboxEventDeduplications extends Table {
  @override
  String get tableName => 'inbox_event_deduplication';

  TextColumn get opaqueEventId => text()();
  TextColumn get firstEnvelopeId => text()();
  IntColumn get dependencyClass =>
      integer().check(dependencyClass.isBetweenValues(0, 1))();
  DateTimeColumn get committedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {opaqueEventId};
}

/// Cryptographic replay identifiers survive inbox acknowledgement cleanup.
class PairwiseReplayMarkers extends Table {
  @override
  String get tableName => 'pairwise_replay_markers';

  BlobColumn get replayMarker => blob()();
  BlobColumn get sessionId => blob()();
  IntColumn get signedPrekeyId => integer().nullable().check(
    signedPrekeyId.isNull() | signedPrekeyId.isBetweenValues(0, 0x7fffffff),
  )();
  IntColumn get pqSignedPrekeyId => integer().nullable().check(
    pqSignedPrekeyId.isNull() | pqSignedPrekeyId.isBetweenValues(0, 0x7fffffff),
  )();
  TextColumn get firstEnvelopeId => text()();
  DateTimeColumn get committedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {replayMarker};
}

/// Authenticated plaintext remains opaque until message semantics are implemented.
class PairwiseOpenedPayloads extends Table {
  @override
  String get tableName => 'pairwise_opened_payloads';

  TextColumn get envelopeId => text()();
  TextColumn get opaqueEventId => text()();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();
  BlobColumn get sessionId => blob()();
  BlobColumn get replayMarker => blob()();
  BlobColumn get openedOpaquePayload => blob()();
  BoolColumn get applicationApplied =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get committedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {envelopeId};
}

/// Current-device application marker committed with remote ciphertext targets.
class PairwiseLocalApplications extends Table {
  @override
  String get tableName => 'pairwise_local_applications';

  TextColumn get operationId => text()();
  TextColumn get eventId => text().unique()();
  TextColumn get localDeviceId => text()();
  BlobColumn get openedOpaquePayload => blob()();
  BoolColumn get applicationApplied =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get committedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

/// One send whose event is committed locally and whose recipients are not yet
/// sealed.
///
/// A row here is the durable request for exactly the work a send used to do on
/// the user's thread: resolve the peer's live devices, claim what needs
/// claiming, run the ratchet once per recipient, and write the outbox. The
/// payload it seals is already in [PairwiseLocalApplications] under the same
/// `operation_id`, so this table carries only the audience and the schedule.
///
/// It is a queue, in the shape [PendingApplicationReceipts] and
/// [StaleDeviceRefreshRequests] already use: a row exists while work is owed
/// and is deleted, in the same transaction that writes the outbox rows, when it
/// is done. The one row that outlives its work is a terminally failed one,
/// which is kept because it is the only durable record that a message the user
/// can see has no route to the wire, and the timeline reads it to say so.
@DataClassName('StoredSendPreparationRow')
class PendingSendPreparations extends Table {
  @override
  String get tableName => 'pending_send_preparations';

  TextColumn get operationId => text()();
  TextColumn get eventId => text().unique()();
  TextColumn get localUserId => text()();
  TextColumn get localDeviceId => text()();
  TextColumn get peerUserId => text()();

  /// 0 owed, 1 permanently failed.
  IntColumn get state => integer()
      .withDefault(const Constant(0))
      .check(state.isBetweenValues(0, 1))();
  IntColumn get attemptCount => integer()
      .withDefault(const Constant(0))
      .check(attemptCount.isBiggerOrEqualValue(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

/// Tombstones contain no key material and make one-time consumption auditable.
class PairwiseConsumedPrekeys extends Table {
  @override
  String get tableName => 'pairwise_consumed_prekeys';

  TextColumn get localDeviceId => text()();
  IntColumn get algorithm => integer().check(algorithm.isBetweenValues(0, 1))();
  IntColumn get keyId => integer().check(keyId.isBiggerOrEqualValue(0))();
  TextColumn get firstEnvelopeId => text()();
  DateTimeColumn get consumedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {localDeviceId, algorithm, keyId};
}

class StaleDeviceRefreshRequests extends Table {
  @override
  String get tableName => 'stale_device_refresh_requests';

  TextColumn get userId => text()();
  TextColumn get staleDeviceId => text()();
  IntColumn get state => integer()
      .withDefault(const Constant(0))
      .check(state.isBetweenValues(0, 3))();
  IntColumn get attemptCount => integer()
      .withDefault(const Constant(0))
      .check(attemptCount.isBiggerOrEqualValue(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {userId, staleDeviceId};
}

class Receipts extends Table {
  @override
  String get tableName => 'receipts';

  TextColumn get messageId =>
      text().references(Messages, #messageId, onDelete: KeyAction.cascade)();
  TextColumn get userId => text()();
  TextColumn get deviceId => text()();
  IntColumn get receiptState =>
      integer().check(receiptState.isBetweenValues(0, 2))();
  BlobColumn get projectionCiphertext => blob()();

  @override
  Set<Column<Object>> get primaryKey => {messageId, userId, deviceId};
}

/// Durable work created only after an incoming message projection commits.
class PendingApplicationReceipts extends Table {
  @override
  String get tableName => 'pending_application_receipts';

  TextColumn get messageId =>
      text().references(Messages, #messageId, onDelete: KeyAction.cascade)();
  TextColumn get conversationId => text()();
  TextColumn get targetUserId => text()();
  TextColumn get localDeviceId => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {messageId, localDeviceId};
}

class VoiceRooms extends Table {
  @override
  String get tableName => 'voice_rooms';

  TextColumn get localRoomId => text()();
  BlobColumn get capabilityCiphertext => blob()();
  BlobColumn get metadataCiphertext => blob()();
  IntColumn get liveState => integer().check(liveState.isBetweenValues(0, 4))();

  @override
  Set<Column<Object>> get primaryKey => {localRoomId};
}

class HistoryTransfers extends Table {
  @override
  String get tableName => 'history_transfers';

  TextColumn get transferId => text()();
  BlobColumn get manifestCiphertext => blob()();
  TextColumn get sourceDeviceId => text().withDefault(const Constant(''))();
  TextColumn get targetDeviceId => text().withDefault(const Constant(''))();
  IntColumn get direction => integer()
      .withDefault(const Constant(0))
      .check(direction.isBetweenValues(0, 1))();
  IntColumn get state => integer()
      .withDefault(const Constant(0))
      .check(state.isBetweenValues(0, 7))();
  IntColumn get nextBatchIndex => integer()
      .withDefault(const Constant(0))
      .check(nextBatchIndex.isBiggerOrEqualValue(0))();
  IntColumn get eventProgress => integer()
      .withDefault(const Constant(0))
      .check(eventProgress.isBiggerOrEqualValue(0))();
  IntColumn get sourceCompleteness =>
      integer().check(sourceCompleteness.isBetweenValues(0, 2))();
  BoolColumn get groupReinviteRequired =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get queueGapRecoveryRequired =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {transferId};
}

class HistoryTransferBatches extends Table {
  @override
  String get tableName => 'history_transfer_batches';

  TextColumn get transferId => text().references(
    HistoryTransfers,
    #transferId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get batchIndex =>
      integer().check(batchIndex.isBiggerOrEqualValue(0))();
  TextColumn get controlEventId => text().unique()();
  IntColumn get eventCount =>
      integer().check(eventCount.isBetweenValues(1, 32))();
  BoolColumn get finalBatch => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {transferId, batchIndex};
}

class SyncCheckpoints extends Table {
  @override
  String get tableName => 'sync_checkpoint';

  IntColumn get singletonId =>
      integer().withDefault(const Constant(1)).check(singletonId.equals(1))();
  IntColumn get highestContiguousAckedSequence => integer()
      .withDefault(const Constant(0))
      .check(highestContiguousAckedSequence.isBiggerOrEqualValue(0))();
  IntColumn get prunedThrough => integer()
      .withDefault(const Constant(0))
      .check(prunedThrough.isBiggerOrEqualValue(0))();
  BlobColumn get etagsCiphertext => blob()();
  IntColumn get retryState =>
      integer().check(retryState.isBetweenValues(0, 5))();
  IntColumn get protocolVersion =>
      integer().check(protocolVersion.isBiggerThanValue(0))();
  IntColumn get queueGapState => integer()
      .withDefault(const Constant(0))
      .check(queueGapState.isBetweenValues(0, 1))();
  BoolColumn get drainRequested =>
      boolean().withDefault(const Constant(true))();
  IntColumn get connectionPhase => integer()
      .withDefault(const Constant(0))
      .check(connectionPhase.isBetweenValues(0, 9))();
  IntColumn get reconnectAttempt => integer()
      .withDefault(const Constant(0))
      .check(reconnectAttempt.isBiggerOrEqualValue(0))();
  DateTimeColumn get reconnectAt => dateTime().nullable()();
  DateTimeColumn get lastSuccessfulSyncAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {singletonId};
}

class LocalPreferences extends Table {
  @override
  String get tableName => 'local_preferences';

  TextColumn get preferenceKey => text()();
  BlobColumn get valueCiphertext => blob()();
  IntColumn get valueVersion =>
      integer().check(valueVersion.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {preferenceKey};
}

class QuarantineRecords extends Table {
  @override
  String get tableName => 'quarantine';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get reasonCode =>
      integer().check(reasonCode.isBetweenValues(0, 63))();
  BlobColumn get opaqueDigest => blob()();
  DateTimeColumn get receivedAt => dateTime().withDefault(currentDateAndTime)();
}

class StorageMigrationHooks {
  const StorageMigrationHooks();

  Future<void> beforeUpgrade(int from, int to) async {}

  Future<void> afterUpgrade(int from, int to) async {}
}

@DriftDatabase(
  tables: [
    AccountSessions,
    SecureSecrets,
    AccountIdentities,
    EnrollmentIntents,
    Users,
    Profiles,
    Devices,
    DeviceLogRecords,
    DeviceLogMutations,
    SecurityPostures,
    PairwiseSessions,
    PairwiseSessionAlternates,
    Prekeys,
    PrekeyMaintenancePlans,
    MlsKeyPackageMaintenanceStates,
    MlsGroups,
    GroupControlEvents,
    GroupOutboundObjects,
    Conversations,
    Memberships,
    Messages,
    MessageEvents,
    StoredApplicationEvents,
    ApplicationEventTargets,
    UnsupportedApplicationEvents,
    ApplicationSenderCounters,
    MessageReactions,
    Attachments,
    InboxEnvelopes,
    OutboxOperations,
    InboxEventDeduplications,
    PairwiseReplayMarkers,
    PairwiseOpenedPayloads,
    PairwiseLocalApplications,
    PendingSendPreparations,
    PairwiseConsumedPrekeys,
    StaleDeviceRefreshRequests,
    Receipts,
    PendingApplicationReceipts,
    VoiceRooms,
    HistoryTransfers,
    HistoryTransferBatches,
    SyncCheckpoints,
    LocalPreferences,
    QuarantineRecords,
  ],
)
final class LocalDatabase extends _$LocalDatabase {
  LocalDatabase(super.executor, {StorageMigrationHooks? migrationHooks})
    : _migrationHooks = migrationHooks ?? const StorageMigrationHooks();

  static const currentSchemaVersion = 19;
  final StorageMigrationHooks _migrationHooks;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await transaction(() async {
        await _migrationHooks.beforeUpgrade(0, schemaVersion);
        await migrator.createAll();
        await _migrationHooks.afterUpgrade(0, schemaVersion);
      });
    },
    onUpgrade: (migrator, from, to) async {
      await transaction(() async {
        await _migrationHooks.beforeUpgrade(from, to);
        if (from < 1) {
          await migrator.createAll();
        } else if (from < 2) {
          await migrator.createTable(enrollmentIntents);
        }
        if (from < 3) {
          await migrator.addColumn(mlsGroups, mlsGroups.queueGapRecoveryState);
          await migrator.addColumn(
            inboxEnvelopes,
            inboxEnvelopes.opaqueEventId,
          );
          await migrator.addColumn(
            inboxEnvelopes,
            inboxEnvelopes.dependencyClass,
          );
          await migrator.addColumn(inboxEnvelopes, inboxEnvelopes.attemptCount);
          await migrator.addColumn(
            inboxEnvelopes,
            inboxEnvelopes.nextAttemptAt,
          );
          await migrator.addColumn(
            outboxOperations,
            outboxOperations.recipientUserId,
          );
          await migrator.addColumn(
            outboxOperations,
            outboxOperations.nextAttemptAt,
          );
          await migrator.addColumn(
            outboxOperations,
            outboxOperations.lastAttemptAt,
          );
          await migrator.addColumn(
            outboxOperations,
            outboxOperations.terminalAt,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.queueGapState,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.drainRequested,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.connectionPhase,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.reconnectAttempt,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.reconnectAt,
          );
          await migrator.addColumn(
            syncCheckpoints,
            syncCheckpoints.lastSuccessfulSyncAt,
          );
          await migrator.createTable(inboxEventDeduplications);
          await migrator.createTable(staleDeviceRefreshRequests);
        }
        if (from < 4) {
          await migrator.addColumn(secureSecrets, secureSecrets.stateRevision);
          await migrator.addColumn(
            devices,
            devices.lastSignedPrekeyRotationUnixDay,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.remoteUserId,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.sessionId,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.skippedKeyCount,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.disposition,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.repairState,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.repairAuthorization,
          );
          await migrator.addColumn(
            pairwiseSessions,
            pairwiseSessions.lastAuthenticatedAt,
          );
          await migrator.createTable(pairwiseSessionAlternates);
          await migrator.createTable(pairwiseReplayMarkers);
          await migrator.createTable(pairwiseOpenedPayloads);
          await migrator.createTable(pairwiseLocalApplications);
          await migrator.createTable(pairwiseConsumedPrekeys);
          await migrator.createTable(prekeyMaintenancePlans);
        }
        if (from < 5) {
          await migrator.addColumn(conversations, conversations.peerUserId);
          await migrator.addColumn(
            conversations,
            conversations.lastActivityEventId,
          );
          await migrator.addColumn(conversations, conversations.unreadCount);
          await migrator.addColumn(conversations, conversations.mutedUntil);
          await migrator.addColumn(
            conversations,
            conversations.draftCiphertext,
          );
          await migrator.addColumn(messages, messages.senderUserId);
          await migrator.addColumn(messages, messages.senderDeviceId);
          await migrator.addColumn(messages, messages.replyToMessageId);
          await migrator.addColumn(messages, messages.quoteFallbackCiphertext);
          await migrator.addColumn(messages, messages.orderingMs);
          await migrator.addColumn(messages, messages.orderingEventId);
          await migrator.addColumn(messages, messages.timestampState);
          await migrator.addColumn(messages, messages.deletedForEveryone);
          await migrator.addColumn(messages, messages.deletedForMe);
          await migrator.addColumn(messages, messages.pinned);
          await migrator.addColumn(messages, messages.unread);
          await migrator.createTable(storedApplicationEvents);
          await migrator.createTable(unsupportedApplicationEvents);
          await migrator.createTable(applicationSenderCounters);
          await migrator.createTable(messageReactions);
          await migrator.createTable(pendingApplicationReceipts);
        }
        if (from < 6) {
          await migrator.addColumn(conversations, conversations.pinned);
          await migrator.addColumn(messages, messages.starred);
        }
        if (from < 7) {
          Future<void> addIfMissing(
            String table,
            String column,
            Future<void> Function() add,
          ) async {
            final existing = await customSelect(
              'PRAGMA table_info("$table")',
            ).get();
            if (!existing.any((row) => row.read<String>('name') == column)) {
              await add();
            }
          }

          await addIfMissing(
            devices.actualTableName,
            devices.createdDate.$name,
            () => migrator.addColumn(devices, devices.createdDate),
          );
          await addIfMissing(
            devices.actualTableName,
            devices.decryptedLabel.$name,
            () => migrator.addColumn(devices, devices.decryptedLabel),
          );
          // `last_active_date`, added here and dropped again by the schema-19
          // step below. The column is gone from the table declaration, so this
          // can no longer name a Dart getter and is spelled as the statement
          // `addColumn` used to issue. It stays because it is what this
          // version did: a database still at schema 6 has to arrive at 19 the
          // way it would have, and the drop below then finds what it expects.
          await addIfMissing(
            devices.actualTableName,
            'last_active_date',
            () => customStatement(
              'ALTER TABLE "${devices.actualTableName}" '
              'ADD COLUMN "last_active_date" TEXT NULL',
            ),
          );
          await addIfMissing(
            devices.actualTableName,
            devices.isCurrentDevice.$name,
            () => migrator.addColumn(devices, devices.isCurrentDevice),
          );
          await addIfMissing(
            devices.actualTableName,
            devices.ownerListing.$name,
            () => migrator.addColumn(devices, devices.ownerListing),
          );
          await migrator.createTable(deviceLogMutations);
          await migrator.createTable(securityPostures);
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.sourceDeviceId.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.sourceDeviceId,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.targetDeviceId.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.targetDeviceId,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.direction.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.direction,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.state.$name,
            () => migrator.addColumn(historyTransfers, historyTransfers.state),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.nextBatchIndex.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.nextBatchIndex,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.groupReinviteRequired.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.groupReinviteRequired,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.queueGapRecoveryRequired.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.queueGapRecoveryRequired,
            ),
          );
          await addIfMissing(
            historyTransfers.actualTableName,
            historyTransfers.updatedAt.$name,
            () => migrator.addColumn(
              historyTransfers,
              historyTransfers.updatedAt,
            ),
          );
          await migrator.createTable(historyTransferBatches);
        }
        if (from < 8) {
          await migrator.addColumn(
            mlsGroups,
            mlsGroups.controlProjectionCiphertext,
          );
          await migrator.addColumn(mlsGroups, mlsGroups.controlRevision);
          await migrator.addColumn(mlsGroups, mlsGroups.controlStateHash);
          await migrator.addColumn(mlsGroups, mlsGroups.lifecycle);
          await migrator.addColumn(mlsGroups, mlsGroups.pendingMutationId);
          await migrator.addColumn(
            conversations,
            conversations.displayTitleCiphertext,
          );
          await migrator.createTable(groupControlEvents);
          await migrator.createTable(groupOutboundObjects);
        }
        if (from < 9) {
          await migrator.createTable(mlsKeyPackageMaintenanceStates);
        }
        if (from < 10) {
          final columns = await customSelect(
            'PRAGMA table_info(group_outbound_objects)',
          ).get();
          final hasRecipientColumn = columns.any(
            (row) => row.read<String>('name') == 'recipient_user_ids_json',
          );
          if (!hasRecipientColumn) {
            await migrator.addColumn(
              groupOutboundObjects,
              groupOutboundObjects.recipientUserIdsJson,
            );
          }
        }
        if (from >= 8 && from < 11) {
          final columns = await customSelect(
            'PRAGMA table_info(group_control_events)',
          ).map((row) => row.read<String>('name')).get();
          if (!columns.contains('deterministic_projection')) {
            await migrator.addColumn(
              groupControlEvents,
              groupControlEvents.deterministicProjection,
            );
          }
          if (!columns.contains('signed_payload')) {
            await migrator.addColumn(
              groupControlEvents,
              groupControlEvents.signedPayload,
            );
          }
          if (!columns.contains('signer_authentication_proof')) {
            await migrator.addColumn(
              groupControlEvents,
              groupControlEvents.signerAuthenticationProof,
            );
          }
        }
        if (from < 12) {
          // Checked rather than assumed, like the schema-7 and schema-11 steps
          // above: a database whose recorded version is behind its actual shape
          // is a real condition, and an upgrade that fails on it leaves the
          // application unable to open its own storage.
          final columns = await customSelect(
            'PRAGMA table_info(messages)',
          ).map((row) => row.read<String>('name')).get();
          if (!columns.contains(messages.alerted.$name)) {
            await migrator.addColumn(messages, messages.alerted);
          }
        }
        if (from < 13) {
          // Enrolment wrote the account's own device bundle under the wire
          // field names, producing a row `DriftContactRepository` throws on.
          // Fixing the writer alone would strand every install that already
          // enrolled, because the unreadable row is what stops the refresh
          // that would otherwise overwrite it. This table is a cache of server
          // state, so dropping bundles that carry no `format` key costs
          // nothing: the next peer refresh writes them back correctly.
          await customStatement(
            'DELETE FROM devices '
            "WHERE CAST(public_bundle AS TEXT) NOT LIKE '%\"format\"%'",
          );
        }
        if (from < 14) {
          // Two things at once, because they are the same repair.
          //
          // The column is new: inspection failures used to be indistinguishable
          // from ordinary retries, so an envelope this device could never open
          // had no terminal state and was re-served, re-fetched and re-failed
          // on every drain forever.
          //
          // The rest un-strands the installs that ran the version without it.
          // Those devices are carrying inbox rows left in `inspecting` by a run
          // that ended mid-envelope, attempt counts driven high enough that the
          // backoff they produce is a quarter of an hour of uniform jitter, and
          // outbox rows waiting out the same thing. None of it is content, all
          // of it is scheduling state, and re-deriving it from zero costs one
          // extra attempt and fixes a queue that would otherwise never move.
          //
          // Every statement here is idempotent and none of them touch a
          // message, an envelope ciphertext or a projection.
          final inboxColumns = await customSelect(
            'PRAGMA table_info(inbox_envelopes)',
          ).map((row) => row.read<String>('name')).get();
          if (!inboxColumns.contains(inboxEnvelopes.inspectionFailures.$name)) {
            await migrator.addColumn(
              inboxEnvelopes,
              inboxEnvelopes.inspectionFailures,
            );
          }
          await customStatement(
            'UPDATE inbox_envelopes '
            'SET processing_state = 0, attempt_count = 0, next_attempt_at = NULL '
            'WHERE processing_state IN (0, 1)',
          );
          await customStatement(
            'UPDATE outbox_operations '
            'SET attempt_state = 0, attempt_count = 0, next_attempt_at = NULL '
            'WHERE attempt_state IN (0, 1, 2)',
          );
          // A conversation with messages in it exists, whatever its row says.
          // Tombstoning is how a conversation is retired, and a row tombstoned
          // while its messages survived is a conversation the list will not
          // show and the diagnostics report will not count while the chat page
          // renders it from the message rows underneath — which is exactly what
          // the affected devices show. Un-tombstoning restores the row the
          // projector already maintains; nothing is created and nothing is
          // deleted.
          await customStatement(
            'UPDATE conversations SET tombstoned = 0 '
            'WHERE tombstoned = 1 AND conversation_id IN '
            '(SELECT DISTINCT conversation_id FROM messages)',
          );
          // And a conversation whose row is gone entirely. The foreign key
          // makes that unreachable while it is enforced, so this is for a
          // database that was written while it was not. The row is minimal on
          // purpose: the ordering key is recoverable from the messages, the
          // rendered preview is not, and the next projector pass writes it.
          await customStatement(
            'INSERT INTO conversations '
            '(conversation_id, kind, list_projection_ciphertext, sort_key, '
            'tombstoned, pinned, unread_count) '
            "SELECT m.conversation_id, 0, X'', MAX(m.ordering_ms), 0, 0, 0 "
            'FROM messages m '
            'WHERE m.conversation_id NOT IN '
            '(SELECT conversation_id FROM conversations) '
            'GROUP BY m.conversation_id',
          );
        }
        if (from < 15) {
          // Checked rather than assumed, in the style of the schema-7, -11 and
          // -12 steps: a database whose recorded version is behind its actual
          // shape is a real condition on a device that has taken a development
          // build, and an upgrade that fails on it leaves the application
          // unable to open its own storage.
          final columns = await customSelect(
            'PRAGMA table_info(messages)',
          ).map((row) => row.read<String>('name')).get();
          if (!columns.contains(messages.deliveredReceiptSent.$name)) {
            await migrator.addColumn(messages, messages.deliveredReceiptSent);
          }
          // Everything already here has had its receipt sent many times over,
          // which is the defect. Marking the existing rows sent is what stops
          // the upgrade itself from queueing one more round of them.
          await customStatement(
            'UPDATE messages SET delivered_receipt_sent = 1',
          );
          await customStatement('DELETE FROM pending_application_receipts');
        }
        if (from < 16) {
          // Local echo needs somewhere to record that a committed message is
          // still owed its per-recipient ciphertext. Nothing is repaired here
          // and nothing is back-filled: every message already on a device
          // either has its outbox rows or has reached a terminal state, so
          // there is no send this table would have been holding.
          //
          // Checked rather than assumed, for the same reason the schema-14 and
          // -15 steps check: a database whose recorded version is behind its
          // actual shape is a real condition on a device that has taken a
          // development build, and an upgrade that fails on it leaves the
          // application unable to open its own storage.
          final existing = await customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [
              Variable<String>(pendingSendPreparations.actualTableName),
            ],
          ).get();
          if (existing.isEmpty) {
            await migrator.createTable(pendingSendPreparations);
          }
        }
        if (from < 17) {
          // Additively, and only indexes. Nothing is dropped, nothing is
          // re-keyed and no row is rewritten: `CREATE INDEX` reads the table
          // once and writes a new B-tree beside it, so an interrupted upgrade
          // rolls back to a database that is exactly what it was.
          //
          // It is not free on a device that already holds history. Each of
          // these reads its whole table under SQLCipher, where every page read
          // is a decrypt, and the two on `messages` read the same table twice.
          // That is a one-time cost at the first open after the update, paid
          // where the integrity check is already paid.
          //
          // `IF NOT EXISTS` is part of each declaration rather than a
          // convenience here, so that this step and `createAll` are the same
          // statement and neither can fail against a database that has already
          // seen the other.
          for (final index in <Index>[
            messagesConversationOrdering,
            messagesPinnedByConversation,
            applicationEventsConversationApplyState,
            applicationEventsSenderCounter,
            attachmentsByMessage,
            outboxOperationsByEvent,
          ]) {
            await migrator.createIndex(index);
          }
        }
        if (from < 18) {
          // The index an incremental projection is read through, and the one
          // aggregate it cannot derive without one.
          //
          // Additive: one new table, one new index, no column added, no table
          // dropped or re-keyed and no existing row rewritten. Checked rather
          // than assumed, in the style of the schema-14, -15 and -16 steps.
          final existing = await customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [
              Variable<String>(applicationEventTargets.actualTableName),
            ],
          ).get();
          if (existing.isEmpty) {
            await migrator.createTable(applicationEventTargets);
          }
          await migrator.createIndex(messagesUnreadByConversation);

          // And the back-fill, which is the whole cost of this step. An empty
          // target table would not be a slower projection, it would be a wrong
          // one: an edit landing on a message whose create has no row here
          // would fold the edit alone and find no message to edit. Every event
          // this device already holds therefore has to be indexed before the
          // first incremental apply runs.
          //
          // The four single-target kinds are already a column, so they are one
          // set-based statement that never leaves SQLite. Creates and receipts
          // carry their message ids inside the projected body, so those are
          // read, decoded and written back in Dart — SQLite's JSON functions
          // are not used, because whether the SQLCipher build has them is not
          // something to discover during a migration on somebody's phone.
          //
          // `INSERT OR IGNORE` throughout, so an interrupted upgrade that is
          // retried cannot collide with itself.
          await customStatement(
            'INSERT OR IGNORE INTO application_event_targets '
            '(message_id, event_id) '
            'SELECT target_message_id, event_id FROM application_events '
            'WHERE target_message_id IS NOT NULL',
          );
          // Read in keyset pages over the primary key rather than all at once:
          // this is still one pass over the table, but the bodies of a whole
          // event log are never in memory together. `OFFSET` would re-scan what
          // it skipped, which is the shape ADR-062 rejected on the read path.
          var cursor = '';
          while (true) {
            final bodies = await customSelect(
              'SELECT event_id, kind, body_projection FROM application_events '
              'WHERE event_id > ? AND kind IN (?, ?, ?) '
              'ORDER BY event_id LIMIT 512',
              variables: [
                Variable<String>(cursor),
                // messageCreate, receiptDelivered, receiptRead. Spelled as the
                // wire values they are stored as, because the protocol enum
                // lives in a layer this file may not import.
                const Variable<int>(1),
                const Variable<int>(6),
                const Variable<int>(7),
              ],
            ).get();
            if (bodies.isEmpty) {
              break;
            }
            cursor = bodies.last.read<String>('event_id');
            final targets = <ApplicationEventTargetsCompanion>[];
            for (final row in bodies) {
              final eventId = row.read<String>('event_id');
              final Object? body;
              try {
                body = jsonDecode(
                  utf8.decode(
                    row.read<Uint8List>('body_projection'),
                    allowMalformed: false,
                  ),
                );
              } on Object {
                // A body this device cannot read is a fact the projector will
                // reject the next time it folds the conversation. Skipping it
                // here leaves that decision where it already lives.
                continue;
              }
              if (body is! Map<String, Object?>) {
                continue;
              }
              final ids = row.read<int>('kind') == 1
                  ? <Object?>[body['message_id']]
                  : (body['message_ids'] as List<Object?>? ?? const []);
              for (final id in ids) {
                if (id is String && id.isNotEmpty) {
                  targets.add(
                    ApplicationEventTargetsCompanion.insert(
                      messageId: id,
                      eventId: eventId,
                    ),
                  );
                }
              }
            }
            if (targets.isNotEmpty) {
              await batch(
                (batch) => batch.insertAll(
                  applicationEventTargets,
                  targets,
                  mode: InsertMode.insertOrIgnore,
                ),
              );
            }
          }
        }
        if (from < 19) {
          // `GET /api/v1/me/devices` stopped carrying `last_active_date`, and
          // the server records no activity day for a device at all. Nothing
          // writes this column and nothing reads it.
          //
          // Dropping it rather than leaving it nullable and idle is the point
          // of the step, not tidiness. Whatever days this device already
          // stored were the last thing on it that answered "when was this
          // device last used", and the server discarded its own copy for that
          // reason. A column no code reads is still a column a seized phone
          // yields.
          //
          // Checked rather than assumed, in the style of the schema-14, -15
          // and -16 steps, and here it is load-bearing rather than defensive:
          // the column is gone from the table declaration, so `createAll` no
          // longer creates it. Any database created by this build and then
          // stamped to an earlier version — which is what the migration tests
          // do, and what a development build does — reaches this step with no
          // column to drop.
          //
          // `ALTER TABLE ... DROP COLUMN` needs SQLite 3.35 or later. The
          // SQLCipher build this client links is well past that, and the
          // column carries no index, view, trigger or foreign key, so the
          // table does not need re-creating around it.
          final existing = await customSelect(
            'PRAGMA table_info("${devices.actualTableName}")',
          ).get();
          final present = existing.any(
            (row) => row.read<String>('name') == 'last_active_date',
          );
          if (present) {
            await migrator.dropColumn(devices, 'last_active_date');
          }
        }
        await _migrationHooks.afterUpgrade(from, to);
      });
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      if (!details.wasCreated) {
        final integrityRows = await customSelect('PRAGMA quick_check').get();
        final isValid =
            integrityRows.length == 1 &&
            integrityRows.single.data.values.singleOrNull == 'ok';
        if (!isValid) {
          throw const LocalDatabaseIntegrityException();
        }
      }
    },
  );

  Future<T> writeTransaction<T>(Future<T> Function() operation) {
    return transaction(operation);
  }

  Stream<List<Conversation>> watchConversationRows() {
    final query = select(conversations)
      ..where((row) => row.tombstoned.equals(false))
      ..orderBy([(row) => OrderingTerm.desc(row.sortKey)]);
    return query.watch();
  }

  Future<CleanupReportRow> cleanupBounded({required int maximumEntries}) async {
    if (maximumEntries <= 0) {
      return const CleanupReportRow(removedEntries: 0, hasMore: true);
    }
    return transaction(() async {
      final expired =
          await (select(attachments)
                ..where(
                  (row) =>
                      row.cacheExpiresAt.isSmallerOrEqualValue(DateTime.now()),
                )
                ..limit(maximumEntries))
              .get();
      for (final row in expired) {
        await (update(
          attachments,
        )..where((item) => item.attachmentId.equals(row.attachmentId))).write(
          const AttachmentsCompanion(
            boundedCacheHandleCiphertext: Value(null),
            cacheExpiresAt: Value(null),
          ),
        );
      }

      final remainingBudget = maximumEntries - expired.length;
      var removedQuarantine = 0;
      if (remainingBudget > 0) {
        final overflow =
            await (select(quarantineRecords)
                  ..orderBy([(row) => OrderingTerm.desc(row.receivedAt)])
                  ..limit(remainingBudget, offset: 256))
                .get();
        for (final row in overflow) {
          removedQuarantine += await (delete(
            quarantineRecords,
          )..where((item) => item.id.equals(row.id))).go();
        }
      }
      final remaining = await (selectOnly(
        quarantineRecords,
      )..addColumns([quarantineRecords.id.count()])).getSingle();
      final remainingCount = remaining.read(quarantineRecords.id.count()) ?? 0;
      return CleanupReportRow(
        removedEntries: expired.length + removedQuarantine,
        hasMore: remainingCount > 256 || expired.length == maximumEntries,
      );
    });
  }
}

final class LocalDatabaseIntegrityException implements Exception {
  const LocalDatabaseIntegrityException();
}

final class CleanupReportRow {
  const CleanupReportRow({required this.removedEntries, required this.hasMore});

  final int removedEntries;
  final bool hasMore;
}
