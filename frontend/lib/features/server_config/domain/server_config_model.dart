/// The limits this deployment publishes at `GET /api/v1/config`.
///
/// Every value here is a setting or a constant a route already enforces, so
/// none of it is a second statement of a limit: a client that never reads the
/// route learns the same numbers from a `413`, a `409` or a `400 bad_bucket`.
/// One value is the exception, and is why the route exists at all —
/// [envelopeTtlDays] is an operator setting with no other observable, and a
/// client that tells a user how long an undelivered message survives has no way
/// to know it (`backend/CLIENT_CONTRACT.md` §H).
///
/// The values change only when the operator edits the environment file and
/// restarts, so this is read once after the client reaches full scope and kept
/// until the next start.
///
/// Bucket sets are held as sets because the only question anything asks of them
/// is membership, and canonicalised ascending on the way in so that `last` is
/// the largest — the ceiling an upload is measured against.
final class ServerConfig {
  /// Each bucket set must already be non-empty and ascending. The parse
  /// boundary in `infrastructure/server_config_api_dtos.dart` is what
  /// establishes that; nothing else constructs one from untrusted input.
  const ServerConfig({
    required this.envelopeTtlDays,
    required this.attachmentTtlDays,
    required this.attachmentDailyBytes,
    required this.mailboxMaxBytes,
    required this.maxDevicesPerUser,
    required this.maxDeviceLogRecords,
    required this.sessionTokenDays,
    required this.sendBatchMax,
    required this.ackMax,
    required this.drainPageMax,
    required this.claimMax,
    required this.envelopeBuckets,
    required this.attachmentBuckets,
    required this.signalBuckets,
    required this.voiceConfigured,
  }) : assert(envelopeTtlDays > 0, 'a retention window is at least one day'),
       assert(attachmentTtlDays > 0, 'a retention window is at least one day'),
       assert(attachmentDailyBytes > 0, 'an allowance admits one upload'),
       assert(mailboxMaxBytes > 0, 'a mailbox holds something'),
       assert(maxDevicesPerUser > 0, 'an account holds one device'),
       assert(maxDeviceLogRecords > 0, 'a log holds one record'),
       assert(sessionTokenDays > 0, 'a token lives at least one day'),
       assert(sendBatchMax > 0, 'a batch carries one item'),
       assert(ackMax > 0, 'an acknowledgement carries one id'),
       assert(drainPageMax > 0, 'a page carries one envelope'),
       assert(claimMax > 0, 'a claim carries one device id');

  /// What this client used before the route existed, and what it uses until it
  /// has stored an answer.
  ///
  /// These are the deployment defaults recorded in `backend/README.md` and the
  /// wire constants the client already enforces, restated here rather than read
  /// from `ApiContractLimits`: the domain layer may not depend on
  /// infrastructure, and those constants are the ones the published values
  /// replace.
  ///
  /// [voiceConfigured] falls back to `false`. A deployment serves no voice
  /// unless `TURN_URLS` is set, and a client that assumed otherwise would offer
  /// a call the relay route answers `503 voice_unconfigured` to.
  static const fallback = ServerConfig(
    envelopeTtlDays: 7,
    attachmentTtlDays: 30,
    attachmentDailyBytes: 268435456,
    mailboxMaxBytes: 33554432,
    maxDevicesPerUser: 10,
    maxDeviceLogRecords: 10000,
    sessionTokenDays: 30,
    sendBatchMax: 256,
    ackMax: 200,
    drainPageMax: 100,
    claimMax: 100,
    envelopeBuckets: {1024, 4096, 16384, 65536, 262144},
    attachmentBuckets: {65536, 262144, 1048576, 4194304, 16777216, 67108864},
    signalBuckets: {1024, 4096, 16384},
    voiceConfigured: false,
  );

  /// How long an undelivered envelope survives in a mailbox before the sweep
  /// deletes it. The one value the client cannot observe any other way.
  final int envelopeTtlDays;

  /// How long an uploaded attachment survives before the sweep deletes it.
  final int attachmentTtlDays;

  /// What one account may upload in one UTC day. Past it, an upload is
  /// `413 quota_exceeded` until the day turns.
  final int attachmentDailyBytes;

  /// The undelivered bytes one device's mailbox holds before a send naming it
  /// is refused and the device is reported in `full_devices`.
  final int mailboxMaxBytes;

  /// Live devices for one account. A further registration is `409
  /// device_limit`.
  final int maxDevicesPerUser;

  /// Records in one account's device-list log. A further append is `409
  /// devicelog_limit`.
  final int maxDeviceLogRecords;

  /// The session token's lifetime, the same number `expires_in` carries in
  /// seconds.
  final int sessionTokenDays;

  /// Items in one `POST /api/v1/envelopes` body.
  final int sendBatchMax;

  /// Ids in one `POST /api/v1/me/envelopes/ack` body.
  final int ackMax;

  /// The ceiling on `GET /api/v1/me/envelopes?limit=`, and its default.
  final int drainPageMax;

  /// Device ids in one `POST /api/v1/users/{user_id}/keys/claim` body.
  final int claimMax;

  /// The exact byte lengths an envelope blob may decode to.
  final Set<int> envelopeBuckets;

  /// The exact byte lengths an attachment upload may be.
  final Set<int> attachmentBuckets;

  /// The exact byte lengths a `/ws` `signal` blob may decode to.
  final Set<int> signalBuckets;

  /// Whether `POST /api/v1/me/relay` mints a credential. `false` means this
  /// deployment serves no voice at all, rather than that voice is failing.
  final bool voiceConfigured;

  /// The largest attachment this deployment accepts, which is the top bucket.
  int get largestAttachmentBucket => attachmentBuckets.last;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerConfig &&
          other.envelopeTtlDays == envelopeTtlDays &&
          other.attachmentTtlDays == attachmentTtlDays &&
          other.attachmentDailyBytes == attachmentDailyBytes &&
          other.mailboxMaxBytes == mailboxMaxBytes &&
          other.maxDevicesPerUser == maxDevicesPerUser &&
          other.maxDeviceLogRecords == maxDeviceLogRecords &&
          other.sessionTokenDays == sessionTokenDays &&
          other.sendBatchMax == sendBatchMax &&
          other.ackMax == ackMax &&
          other.drainPageMax == drainPageMax &&
          other.claimMax == claimMax &&
          other.voiceConfigured == voiceConfigured &&
          _sameBuckets(other.envelopeBuckets, envelopeBuckets) &&
          _sameBuckets(other.attachmentBuckets, attachmentBuckets) &&
          _sameBuckets(other.signalBuckets, signalBuckets);

  @override
  int get hashCode => Object.hash(
    envelopeTtlDays,
    attachmentTtlDays,
    attachmentDailyBytes,
    mailboxMaxBytes,
    maxDevicesPerUser,
    maxDeviceLogRecords,
    sessionTokenDays,
    sendBatchMax,
    ackMax,
    drainPageMax,
    claimMax,
    voiceConfigured,
    Object.hashAll(envelopeBuckets),
    Object.hashAll(attachmentBuckets),
    Object.hashAll(signalBuckets),
  );
}

/// Both sets are canonical ascending, so order is part of the value.
bool _sameBuckets(Set<int> left, Set<int> right) {
  if (left.length != right.length) {
    return false;
  }
  final rightValues = right.iterator;
  for (final value in left) {
    rightValues.moveNext();
    if (value != rightValues.current) {
      return false;
    }
  }
  return true;
}
