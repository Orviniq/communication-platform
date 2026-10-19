import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';

/// One device a presence frame goes to, or came from.
final class PresenceDevice {
  const PresenceDevice({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  /// The key this device is held by: its id, in lower case.
  String get key => deviceId.toLowerCase();

  @override
  bool operator ==(Object other) =>
      other is PresenceDevice &&
      other.userId.toLowerCase() == userId.toLowerCase() &&
      other.key == key;

  @override
  int get hashCode => Object.hash(userId.toLowerCase(), key);

  @override
  String toString() => 'PresenceDevice(<redacted>)';
}

/// Why one device was sealed nothing.
enum PresenceSealRefusal {
  notLive,
  identityBlocked,
  unverified,
  noSession,
  sessionUnderRepair,
  offBucket,
  sealFailed,
}

/// What sealing came to for one target.
sealed class PresenceSealOutcome {
  const PresenceSealOutcome(this.device);

  final PresenceDevice device;
}

final class PresenceSealed extends PresenceSealOutcome {
  PresenceSealed(super.device, Uint8List frame)
    : frame = Uint8List.fromList(frame);

  /// The exact `EnvelopeV1`, its session state already committed.
  final Uint8List frame;

  @override
  String toString() => 'PresenceSealed(<redacted>)';
}

final class PresenceSealRefused extends PresenceSealOutcome {
  const PresenceSealRefused(super.device, this.reason);

  final PresenceSealRefusal reason;
}

/// Seals one payload to each target's pairwise session, and commits every
/// advanced state before any frame is returned. It refuses an account this
/// user has not verified and a device with no ready session (T4).
abstract interface class PresenceSealPort implements Port {
  /// One outcome for each of [targets], in order. A failure means nothing was
  /// committed and no frame exists.
  Future<Result<List<PresenceSealOutcome>>> seal({
    required Uint8List payload,
    required List<PresenceDevice> targets,
    required Set<int> allowedLengths,
  });
}

/// A conversation this phone holds, as presence needs to know it.
sealed class PresenceConversation {
  const PresenceConversation(this.conversationId);

  final String conversationId;
}

/// A direct conversation and its peer.
final class PresenceDirectConversation extends PresenceConversation {
  const PresenceDirectConversation(super.conversationId, this.peerUserId);

  final String peerUserId;
}

/// A group this phone holds active, and its active members, this account
/// among them when it is one.
final class PresenceGroupConversation extends PresenceConversation {
  PresenceGroupConversation(super.conversationId, Iterable<String> members)
    : activeMemberUserIds = Set.unmodifiable({
        for (final member in members) member.toLowerCase(),
      });

  final Set<String> activeMemberUserIds;
}

abstract interface class PresenceConversationsPort implements Port {
  /// The conversation [conversationId] names, or null when this phone holds
  /// none by that id: Saved Messages, a conversation never opened, and a group
  /// that is not active here are all null.
  Future<PresenceConversation?> read(String conversationId);
}

abstract interface class PresencePeersPort implements Port {
  /// The live device ids of each account in [userIds] that this user has
  /// verified, in lower case. An account that is not verified, whose identity
  /// is blocked, or that could not be read is absent.
  ///
  /// One read answers up to 64 accounts and is reused for at most 10 s
  /// (ADR-098 D7).
  Future<Map<String, List<String>>> verifiedDevices(Set<String> userIds);
}

/// The probe ledger of one peer device (ADR-098 D6), which schema 26 keeps.
final class PresenceLedgerEntry {
  const PresenceLedgerEntry({
    required this.userId,
    required this.deviceId,
    required this.probesSinceHeard,
    required this.tokens,
    required this.tokensAtMs,
    required this.lastProbeMs,
  });

  final String userId;
  final String deviceId;

  /// Probes sent since the last frame committed from the device (P1).
  final int probesSinceHeard;

  /// The bucket of P2, as of [tokensAtMs].
  final int tokens;
  final int tokensAtMs;

  /// When the last probe went, or null when none has.
  final int? lastProbeMs;

  PresenceLedgerEntry copyWith({
    int? probesSinceHeard,
    int? tokens,
    int? tokensAtMs,
    int? lastProbeMs,
  }) => PresenceLedgerEntry(
    userId: userId,
    deviceId: deviceId,
    probesSinceHeard: probesSinceHeard ?? this.probesSinceHeard,
    tokens: tokens ?? this.tokens,
    tokensAtMs: tokensAtMs ?? this.tokensAtMs,
    lastProbeMs: lastProbeMs ?? this.lastProbeMs,
  );

  @override
  String toString() => 'PresenceLedgerEntry(<redacted>)';
}

/// Where the probe ledger is kept. Nothing in it ever leaves the phone.
abstract interface class PresenceLedgerPort implements Port {
  Future<Result<PresenceLedgerEntry?>> read({
    required String userId,
    required String deviceId,
  });

  Future<Result<void>> write(PresenceLedgerEntry entry);
}

/// When this phone last saw one peer device online (ADR-098 D8).
final class PresenceLastSeen {
  const PresenceLastSeen({
    required this.userId,
    required this.deviceId,
    required this.lastSeenMs,
  });

  final String userId;
  final String deviceId;
  final int lastSeenMs;

  @override
  String toString() => 'PresenceLastSeen(<redacted>)';
}

/// Where the last seen of each peer device is kept, beside its probe ledger.
/// It is only what this phone saw, and nothing in it ever leaves the phone.
abstract interface class PresenceLastSeenPort implements Port {
  /// The last seen of every device of [userIds] that has one.
  Future<Result<List<PresenceLastSeen>>> readLastSeen(Set<String> userIds);

  Future<Result<void>> writeLastSeen(PresenceDevice device, int lastSeenMs);

  /// Forgets the last seen of [device], or of every device when it is null.
  Future<Result<void>> forgetLastSeen([PresenceDevice? device]);
}

/// "Show my online status", a preference of this phone (ADR-098 D9).
abstract interface class PresenceSharePort implements Port {
  /// The stored choice. A missing or unreadable choice reads as on (T3).
  Future<bool> readSharing();

  Future<Result<void>> writeSharing({required bool sharing});
}

/// Where a received typing state is shown.
abstract interface class PresenceTypingSinkPort implements Port {
  /// Shows [active] typing until [expiresAt], or ends it.
  void showTyping({
    required String conversationId,
    required String userId,
    required String deviceId,
    required bool active,
    required DateTime expiresAt,
    required DateTime authenticatedAt,
  });

  /// Ends every typing state, as when the socket closes.
  void clearAll();
}

/// Which conversation is on screen, and whether the app is.
abstract interface class PresenceVisibilityPort implements Port {
  /// The conversation on screen, or null when none is or the app is not in
  /// the foreground.
  String? get visibleConversationId;

  bool get isForeground;

  /// Fires on every change of either.
  Stream<void> get changes;
}

/// A timer that can be cancelled before it fires.
abstract interface class PresenceTimer {
  void cancel();
}

/// Runs a callback later, so that a test can move time instead of spending
/// it.
abstract interface class PresenceTimerPort implements Port {
  PresenceTimer start(Duration delay, void Function() callback);
}
