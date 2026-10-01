/// Where this device's call stands.
enum VoiceCallPhase {
  /// No call, and none ending.
  idle,

  /// Checking the room, minting the relay credential and starting the
  /// sessions the call will need. Nothing has been sent.
  preparing,

  /// Asking the room's member devices who is in the call, before this device
  /// announces itself: the participants' answers decide whether the call is
  /// already full (`voice-signalling-v1.md`, The ceiling).
  announcing,

  /// This device's `join` has gone out. The call stays in this phase while
  /// it is alone, and while peers come and go.
  inCall,

  /// The call ended, or never began. [VoiceCallState.endReason] says why.
  ended,
}

/// Why a call ended, or why a join was refused before it began.
enum VoiceCallEndReason {
  /// The user left.
  left,

  /// A member signed an event removing this device's account from the room.
  removedFromRoom,

  /// This device's account left the room: a `remove member` event naming
  /// itself, signed here or on another of its devices.
  leftRoom,

  /// The room may be missing a control event, and a member has been asked for
  /// its state. A join waits for the answer rather than failing.
  roomWaitingForState,

  /// Two valid control events at one revision: nobody may join until the
  /// fork is resolved.
  roomQuarantined,

  /// This device holds no such room.
  roomUnavailable,

  /// The deployment serves no voice: `voice_configured` is false, or the
  /// relay route answered `503 voice_unconfigured`.
  voiceUnavailable,

  /// The relay route answered `429`. [VoiceCallState.retryAt] says when a
  /// join may ask again.
  throttled,

  /// The relay credential could not be minted: offline, a timeout, a server
  /// failure. Another join asks again.
  credentialFailed,

  /// Ten devices are already in the call (§N rule 10), or, when two devices
  /// joined at once, this one sorted outside the ten that every participant
  /// keeps. A full mesh costs every participant one uplink for each peer.
  callFull,

  /// Another call is already in progress on this device.
  alreadyInCall,

  /// The microphone or the platform connection could not be opened.
  localFailure,
}

/// How one peer of the call stands, as the tile shows it.
enum VoiceParticipantStatus {
  /// Expected, or negotiating: an offer and an answer are on their way, or
  /// the peer is known only from another participant's answer.
  connecting,

  connected,

  /// Was connected and lost its path for now. The platform may find it again
  /// on its own; nothing is retried from here.
  reconnecting,

  /// Four attempts over about twenty seconds and nothing back (§N rule 7).
  /// Nothing more is sent to it until it announces itself again, or the user
  /// asks to try again.
  notReachable,

  /// Its safety number changed in a way that is not an expected rotation.
  /// The connection is closed and nothing more is sealed to it until the user
  /// verifies the new number.
  identityBlocked,

  /// It speaks a major version of the signalling this build does not, or
  /// offered media this version has none of. One of the two builds needs
  /// updating; nothing more is sent to it.
  incompatibleVersion,
}

/// One other device of the call.
///
/// The ids key the tile and choose the name from contacts; a screen never
/// shows them, and they have no string form.
final class VoiceCallParticipant {
  const VoiceCallParticipant({
    required this.userId,
    required this.deviceId,
    required this.status,
    this.restartingIce = false,
  });

  final String userId;
  final String deviceId;
  final VoiceParticipantStatus status;

  /// An ICE restart this device asked for, after a credential refresh, is
  /// waiting for its answer. The audio keeps its old path meanwhile.
  final bool restartingIce;

  /// Counts as in the call: connecting, connected or reconnecting. A peer
  /// that is not reachable, blocked by a changed safety number or on another
  /// version keeps its tile and takes no seat.
  bool get isSeated =>
      status == VoiceParticipantStatus.connecting ||
      status == VoiceParticipantStatus.connected ||
      status == VoiceParticipantStatus.reconnecting;

  @override
  String toString() =>
      'VoiceCallParticipant(${status.name}, restartingIce: $restartingIce)';
}

/// One line of the call's ephemeral room text, held in memory for the life of
/// the call and never written anywhere.
final class VoiceRoomTextEntry {
  const VoiceRoomTextEntry({
    required this.senderUserId,
    required this.senderDeviceId,
    required this.text,
    required this.at,
    required this.isOwn,
  });

  final String senderUserId;
  final String senderDeviceId;
  final String text;

  /// When this device sent or received it, on its own clock.
  final DateTime at;

  /// Sent by this device, which shows it because it sent it: there is no
  /// echo of a device's own message.
  final bool isOwn;

  @override
  String toString() => 'VoiceRoomTextEntry(isOwn: $isOwn, <redacted>)';
}

/// What asking to join came to.
sealed class VoiceJoinOutcome {
  const VoiceJoinOutcome();
}

/// This device's `join` has gone out to the room's member devices.
final class VoiceJoinAnnounced extends VoiceJoinOutcome {
  const VoiceJoinAnnounced();
}

/// No `join` went out, or the call ended before one could.
final class VoiceJoinRefused extends VoiceJoinOutcome {
  const VoiceJoinRefused(this.reason, {this.retryAt});

  final VoiceCallEndReason reason;

  /// For [VoiceCallEndReason.throttled]: when a join may ask again.
  final DateTime? retryAt;
}

/// The call as the application layer sees it.
///
/// [participants] are this device's peers, itself excluded, in device-id
/// order. A device is in the call when a connection to it is open; one that
/// another participant named, and that has not negotiated yet, shows as
/// [VoiceParticipantStatus.connecting].
final class VoiceCallState {
  VoiceCallState({
    required this.phase,
    this.roomId,
    Iterable<VoiceCallParticipant> participants = const [],
    Iterable<VoiceRoomTextEntry> roomText = const [],
    this.announcing = false,
    this.muted = false,
    this.endReason,
    this.retryAt,
  }) : participants = List.unmodifiable(participants),
       roomText = List.unmodifiable(roomText);

  VoiceCallState.idle() : this(phase: VoiceCallPhase.idle);

  final VoiceCallPhase phase;

  /// The room, as the 64-character hex id the room state uses.
  final String? roomId;
  final List<VoiceCallParticipant> participants;
  final List<VoiceRoomTextEntry> roomText;

  /// Whether this device's announcement is still being retried: until it
  /// ends, a call with no participant is still being joined rather than
  /// empty.
  final bool announcing;

  /// Whether this device's microphone is muted: every connection sends
  /// silence. Known only for this device; a peer's mute crosses no frame.
  final bool muted;

  /// Set when [phase] is [VoiceCallPhase.ended].
  final VoiceCallEndReason? endReason;

  /// For [VoiceCallEndReason.throttled]: when a join may ask again.
  final DateTime? retryAt;

  bool get isActive =>
      phase == VoiceCallPhase.preparing ||
      phase == VoiceCallPhase.announcing ||
      phase == VoiceCallPhase.inCall;

  /// The devices this one counts in the call, itself included, or zero when
  /// no call runs. It is what this device has been told, and no more:
  /// nothing on the server counts participants.
  int get devicesInCall =>
      isActive ? 1 + participants.where((peer) => peer.isSeated).length : 0;

  @override
  String toString() =>
      'VoiceCallState(${phase.name}, participants: ${participants.length}, '
      'roomText: ${roomText.length}, muted: $muted, '
      'endReason: ${endReason?.name})';
}

/// The ten-device ceiling of §N rule 10, as ADR-077 D2 decides it.
abstract final class VoiceCallCeiling {
  /// Joined devices, this one included.
  static const maximumJoinedDevices = 10;

  /// The devices that stay when more than ten have joined: the ten whose ids
  /// sort lowest as lowercase strings, the order §N rule 3 uses for the
  /// polite peer. Every participant computes it from the ids alone, so they
  /// agree without a round trip.
  static Set<String> kept(Iterable<String> deviceIds) {
    final sorted = {for (final id in deviceIds) id.toLowerCase()}.toList()
      ..sort();
    return sorted.take(maximumJoinedDevices).toSet();
  }
}

/// The bounded retry of §N rule 7, as `voice-signalling-v1.md` sets it: four
/// attempts, the first at once, then waits of 2, 4 and 8 seconds, each within
/// 25 % either way, and a 6-second answer window after the last. A peer that
/// has answered nothing by then — about twenty seconds after the first
/// attempt — is not reachable.
abstract final class VoiceRetrySchedule {
  static const attempts = 4;
  static const _waits = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  static const jitterFraction = 0.25;
  static const answerWindow = Duration(seconds: 6);

  /// The wait after attempt [attempt], counted from 0, scaled by [unit]: a
  /// value in `[0, 1)`, where 0.5 is the nominal wait.
  static Duration waitAfter(int attempt, double unit) {
    if (attempt < 0 || attempt >= _waits.length) {
      throw RangeError.range(attempt, 0, _waits.length - 1, 'attempt');
    }
    final clamped = unit.isNaN ? 0.5 : unit.clamp(0.0, 1.0);
    final factor = 1 - jitterFraction + 2 * jitterFraction * clamped;
    return Duration(
      microseconds: (_waits[attempt].inMicroseconds * factor).round(),
    );
  }
}
