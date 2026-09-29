import 'dart:convert';
import 'dart:typed_data';

/// The bounds `voice-signalling-v1.md` Part 2 sets on a `CPVSV001` body.
abstract final class VoiceSignalLimits {
  static const roomIdBytes = 32;
  static const joinIdBytes = 16;
  static const uuidBytes = 16;

  /// A `counter` or an `answers_counter`: monotonic within one join, from 1.
  static const maximumCounter = 0xffffffff;

  static const maximumCandidates = 8;
  static const maximumParticipants = 10;
  static const maximumRoomTextScalars = 2000;
  static const maximumRoomTextBytes = 8000;
}

/// The eight kinds, by the value the frame carries after its version byte.
enum VoiceSignalKind {
  join(1),
  leave(2),
  offer(3),
  answer(4),
  candidates(5),
  participantsQuery(6),
  participants(7),
  roomText(8);

  const VoiceSignalKind(this.wireValue);

  final int wireValue;

  static VoiceSignalKind? fromWireValue(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// One signalling message: the header every kind carries, and its body.
final class VoiceSignalMessage {
  const VoiceSignalMessage({required this.header, required this.body});

  final VoiceSignalHeader header;
  final VoiceSignalBody body;

  VoiceSignalKind get kind => body.kind;

  @override
  String toString() => 'VoiceSignalMessage(${kind.name}, <redacted>)';
}

/// Keys 0 to 5 of every body.
///
/// [senderUserId] and [senderDeviceId] are what the sender says about itself.
/// A receiver accepts them only when they equal the device the pairwise
/// session authenticated; they never name the sender on their own.
final class VoiceSignalHeader {
  VoiceSignalHeader({
    required Uint8List roomId,
    required Uint8List joinId,
    required Uint8List senderUserId,
    required Uint8List senderDeviceId,
    required this.counter,
    required this.createdMs,
  }) : roomId = _exact(roomId, VoiceSignalLimits.roomIdBytes),
       joinId = _exact(joinId, VoiceSignalLimits.joinIdBytes),
       senderUserId = _exact(senderUserId, VoiceSignalLimits.uuidBytes),
       senderDeviceId = _exact(senderDeviceId, VoiceSignalLimits.uuidBytes) {
    if (!_isCounter(counter) || createdMs < 0) {
      throw const FormatException('invalid voice signal header');
    }
  }

  /// The room this frame belongs to.
  final Uint8List roomId;

  /// The sender's own join: minted when it joins a call, kept until it leaves.
  final Uint8List joinId;

  final Uint8List senderUserId;
  final Uint8List senderDeviceId;

  /// Orders two frames of one join and marks a retry as a duplicate.
  final int counter;

  /// The sender's wall clock, for display and staleness only.
  final int createdMs;

  @override
  String toString() => 'VoiceSignalHeader(<redacted>)';
}

sealed class VoiceSignalBody {
  const VoiceSignalBody();

  VoiceSignalKind get kind;
}

/// "This device is in the call now." A participant answers with an offer.
final class VoiceJoin extends VoiceSignalBody {
  const VoiceJoin();

  @override
  VoiceSignalKind get kind => VoiceSignalKind.join;
}

/// Advisory: the closing connection is the authoritative signal.
final class VoiceLeave extends VoiceSignalBody {
  const VoiceLeave(this.reason);

  final VoiceLeaveReason reason;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.leave;
}

enum VoiceLeaveReason {
  userLeft(1),
  roomStateChanged(2),
  localFailure(3);

  const VoiceLeaveReason(this.wireValue);

  final int wireValue;

  static VoiceLeaveReason? fromWireValue(int value) {
    for (final reason in values) {
      if (reason.wireValue == value) {
        return reason;
      }
    }
    return null;
  }
}

/// An SDP offer for the peer's join [targetJoinId].
final class VoiceOffer extends VoiceSignalBody {
  VoiceOffer({required Uint8List targetJoinId, required this.sdp})
    : targetJoinId = _exact(targetJoinId, VoiceSignalLimits.joinIdBytes) {
    _requireScalarText(sdp);
  }

  final Uint8List targetJoinId;
  final String sdp;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.offer;

  @override
  String toString() => 'VoiceOffer(<redacted>)';
}

/// An SDP answer to the offer whose `counter` was [answersCounter].
final class VoiceAnswer extends VoiceSignalBody {
  VoiceAnswer({
    required Uint8List targetJoinId,
    required this.sdp,
    required this.answersCounter,
  }) : targetJoinId = _exact(targetJoinId, VoiceSignalLimits.joinIdBytes) {
    _requireScalarText(sdp);
    if (!_isCounter(answersCounter)) {
      throw const FormatException('invalid answered counter');
    }
  }

  final Uint8List targetJoinId;
  final String sdp;
  final int answersCounter;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.answer;

  @override
  String toString() => 'VoiceAnswer(<redacted>)';
}

/// One batch of ICE candidates. [end] says none will follow for this
/// negotiation.
final class VoiceCandidates extends VoiceSignalBody {
  VoiceCandidates({
    required Uint8List targetJoinId,
    required List<VoiceIceCandidate> candidates,
    required this.end,
  }) : targetJoinId = _exact(targetJoinId, VoiceSignalLimits.joinIdBytes),
       candidates = List.unmodifiable(candidates) {
    if (candidates.length > VoiceSignalLimits.maximumCandidates) {
      throw const FormatException('too many candidates in one batch');
    }
  }

  final Uint8List targetJoinId;
  final List<VoiceIceCandidate> candidates;
  final bool end;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.candidates;

  @override
  String toString() => 'VoiceCandidates(${candidates.length}, <redacted>)';
}

/// One `RTCIceCandidate`: its line, its `sdpMid` and its `sdpMLineIndex`.
final class VoiceIceCandidate {
  VoiceIceCandidate({
    required this.candidate,
    required this.mid,
    required this.mline,
  }) {
    _requireScalarText(candidate);
    _requireScalarText(mid);
    if (mline < 0) {
      throw const FormatException('invalid m-line index');
    }
  }

  final String candidate;
  final String mid;
  final int mline;

  @override
  String toString() => 'VoiceIceCandidate(<redacted>)';
}

/// "Who is in the call?" Each participant answers with [VoiceParticipants].
final class VoiceParticipantsQuery extends VoiceSignalBody {
  const VoiceParticipantsQuery();

  @override
  VoiceSignalKind get kind => VoiceSignalKind.participantsQuery;
}

/// The devices the answering device believes are in the call, itself
/// included. A hint, never an authority.
final class VoiceParticipants extends VoiceSignalBody {
  VoiceParticipants(List<VoiceParticipant> members)
    : members = List.unmodifiable(members) {
    if (members.length > VoiceSignalLimits.maximumParticipants) {
      throw const FormatException('too many participants');
    }
  }

  final List<VoiceParticipant> members;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.participants;

  @override
  String toString() => 'VoiceParticipants(${members.length}, <redacted>)';
}

final class VoiceParticipant {
  VoiceParticipant({
    required Uint8List userId,
    required Uint8List deviceId,
    required Uint8List joinId,
  }) : userId = _exact(userId, VoiceSignalLimits.uuidBytes),
       deviceId = _exact(deviceId, VoiceSignalLimits.uuidBytes),
       joinId = _exact(joinId, VoiceSignalLimits.joinIdBytes);

  final Uint8List userId;
  final Uint8List deviceId;
  final Uint8List joinId;

  @override
  String toString() => 'VoiceParticipant(<redacted>)';
}

/// Ephemeral room text, held in memory and never appended to a timeline.
final class VoiceRoomText extends VoiceSignalBody {
  VoiceRoomText(this.text) {
    _requireScalarText(text);
    if (text.runes.length > VoiceSignalLimits.maximumRoomTextScalars ||
        utf8.encode(text).length > VoiceSignalLimits.maximumRoomTextBytes) {
      throw const FormatException('room text is too long');
    }
  }

  final String text;

  @override
  VoiceSignalKind get kind => VoiceSignalKind.roomText;

  @override
  String toString() => 'VoiceRoomText(<redacted>)';
}

Uint8List _exact(Uint8List value, int length) {
  if (value.length != length) {
    throw const FormatException('invalid identifier length');
  }
  return Uint8List.fromList(value);
}

bool _isCounter(int value) =>
    value >= 1 && value <= VoiceSignalLimits.maximumCounter;

/// A text field must be Unicode scalar values: a lone surrogate has no UTF-8
/// encoding, so it could not travel without being silently replaced.
void _requireScalarText(String value) {
  for (var index = 0; index < value.length; index += 1) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final next = index + 1 < value.length ? value.codeUnitAt(index + 1) : 0;
      if (next < 0xdc00 || next > 0xdfff) {
        throw const FormatException('unpaired surrogate');
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('unpaired surrogate');
    }
  }
}
