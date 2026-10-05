import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/deterministic_cbor.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// What decoding one opened payload found.
sealed class VoiceSignalDecoding {
  const VoiceSignalDecoding();
}

/// A payload of this version and a kind it defines, every field in bounds.
final class DecodedVoiceSignal extends VoiceSignalDecoding {
  const DecodedVoiceSignal(this.message);

  final VoiceSignalMessage message;
}

/// Not `CPVSV001` at all. The payload belongs to another channel.
final class NotVoiceSignal extends VoiceSignalDecoding {
  const NotVoiceSignal();
}

/// `CPVSV001` of a major version this build does not speak. It is dropped,
/// and the sender is counted as not answering; there is no reply to send.
final class UnsupportedVoiceSignalVersion extends VoiceSignalDecoding {
  const UnsupportedVoiceSignalVersion(this.version);

  final int version;
}

/// A kind this version does not define. It is ignored and nothing else, so
/// that a later build can add a kind without breaking this one.
final class UnknownVoiceSignalKind extends VoiceSignalDecoding {
  const UnknownVoiceSignalKind(this.kind);

  final int kind;
}

/// `CPVSV001` of this version whose body is not well formed.
final class MalformedVoiceSignal extends VoiceSignalDecoding {
  const MalformedVoiceSignal();
}

/// `CPVSV001`, the call's signalling payload (`voice-signalling-v1.md`,
/// Part 2):
///
/// ```text
/// "CPVSV001" || version:u8 || kind:u8 || deterministic-CBOR body
/// ```
///
/// The magic and the two bytes sit outside the CBOR, so a reader routes the
/// payload and checks its version before it decodes anything a sender chose.
abstract final class VoiceSignalCodec {
  static const version = 1;

  /// The most plaintext one `signal` frame carries: bucket 16384 under a
  /// regular 58-byte ratchet header. A payload under an initial header holds
  /// less, and the seal refuses whatever does not fit a signal bucket.
  static const maximumPayloadBytes = 16302;

  static const _magic = <int>[0x43, 0x50, 0x56, 0x53, 0x56, 0x30, 0x30, 0x31];
  static const _prefixBytes = 10;

  /// A body map, the array a map holds, and the maps that array holds.
  static const _maximumNesting = 3;

  static const _headerKeys = {0, 1, 2, 3, 4, 5};

  /// Whether [payload] claims to be `CPVSV001`.
  ///
  /// The channel a payload arrived on is checked against this once the
  /// plaintext is open: a `CPVSV001` that did not come over a `signal` frame,
  /// and anything else that did, is not the call's.
  static bool matches(List<int> payload) {
    if (payload.length < _magic.length) {
      return false;
    }
    for (var index = 0; index < _magic.length; index += 1) {
      if (payload[index] != _magic[index]) {
        return false;
      }
    }
    return true;
  }

  /// The one encoding of [message], or `limitExceeded` when it is more than a
  /// signal frame can carry.
  static Result<Uint8List> encode(VoiceSignalMessage message) {
    final encoded = _encode(message);
    if (encoded.length > maximumPayloadBytes) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    return Result.success(encoded);
  }

  static VoiceSignalDecoding decode(Uint8List payload) {
    if (!matches(payload)) {
      return const NotVoiceSignal();
    }
    if (payload.length < _prefixBytes) {
      return const MalformedVoiceSignal();
    }
    final payloadVersion = payload[_magic.length];
    if (payloadVersion != version) {
      return UnsupportedVoiceSignalVersion(payloadVersion);
    }
    final kindValue = payload[_magic.length + 1];
    final kind = VoiceSignalKind.fromWireValue(kindValue);
    if (kind == null) {
      return UnknownVoiceSignalKind(kindValue);
    }
    if (payload.length > maximumPayloadBytes) {
      return const MalformedVoiceSignal();
    }
    try {
      final body = DeterministicCbor.decode(
        Uint8List.sublistView(payload, _prefixBytes),
        maximumNesting: _maximumNesting,
      );
      final message = _message(kind, body);
      // The decoder already holds every rule that makes the encoding unique,
      // so this is the rule restated as one comparison: a payload is accepted
      // only as the bytes its own sender would have written.
      if (!_same(_encode(message), payload)) {
        return const MalformedVoiceSignal();
      }
      return DecodedVoiceSignal(message);
    } on CborFormatException {
      return const MalformedVoiceSignal();
    } on FormatException {
      return const MalformedVoiceSignal();
    }
  }

  static Uint8List _encode(VoiceSignalMessage message) {
    final header = message.header;
    final entries = <int, CborValue>{
      0: CborBytes(header.roomId),
      1: CborBytes(header.joinId),
      2: CborBytes(header.senderUserId),
      3: CborBytes(header.senderDeviceId),
      4: CborUnsigned(header.counter),
      5: CborUnsigned(header.createdMs),
      ..._bodyEntries(message.body),
    };
    final body = DeterministicCbor.encode(CborMap(entries));
    return Uint8List.fromList([
      ..._magic,
      version,
      message.kind.wireValue,
      ...body,
    ]);
  }

  static Map<int, CborValue> _bodyEntries(VoiceSignalBody body) =>
      switch (body) {
        VoiceJoin() || VoiceParticipantsQuery() => const {},
        VoiceLeave(:final reason) => {8: CborUnsigned(reason.wireValue)},
        VoiceOffer(:final targetJoinId, :final sdp) => {
          8: CborBytes(targetJoinId),
          9: CborText(sdp),
        },
        VoiceAnswer(:final targetJoinId, :final sdp, :final answersCounter) => {
          8: CborBytes(targetJoinId),
          9: CborText(sdp),
          10: CborUnsigned(answersCounter),
        },
        VoiceCandidates(:final targetJoinId, :final candidates, :final end) => {
          8: CborBytes(targetJoinId),
          9: CborArray([
            for (final candidate in candidates)
              CborMap({
                0: CborText(candidate.candidate),
                1: CborText(candidate.mid),
                2: CborUnsigned(candidate.mline),
              }),
          ]),
          10: CborBool(end),
        },
        VoiceParticipants(:final members) => {
          8: CborArray([
            for (final member in members)
              CborMap({
                0: CborBytes(member.userId),
                1: CborBytes(member.deviceId),
                2: CborBytes(member.joinId),
              }),
          ]),
        },
        VoiceRoomText(:final text) => {8: CborText(text)},
      };

  static VoiceSignalMessage _message(VoiceSignalKind kind, CborValue value) {
    if (value is! CborMap) {
      throw const FormatException('a body is a map');
    }
    final entries = value.entries;
    final bodyKeys = switch (kind) {
      VoiceSignalKind.join ||
      VoiceSignalKind.participantsQuery => const <int>{},
      VoiceSignalKind.leave ||
      VoiceSignalKind.participants ||
      VoiceSignalKind.roomText => const {8},
      VoiceSignalKind.offer => const {8, 9},
      VoiceSignalKind.answer || VoiceSignalKind.candidates => const {8, 9, 10},
    };
    // Every key is required and no other is allowed, the reserved 6 and 7
    // included: a later header field is a later version.
    if (entries.length != _headerKeys.length + bodyKeys.length ||
        !entries.keys.every(
          (key) => _headerKeys.contains(key) || bodyKeys.contains(key),
        )) {
      throw const FormatException('unexpected body keys');
    }
    final header = VoiceSignalHeader(
      roomId: _bytes(entries[0], VoiceSignalLimits.roomIdBytes),
      joinId: _bytes(entries[1], VoiceSignalLimits.joinIdBytes),
      senderUserId: _bytes(entries[2], VoiceSignalLimits.uuidBytes),
      senderDeviceId: _bytes(entries[3], VoiceSignalLimits.uuidBytes),
      counter: _unsigned(entries[4]),
      createdMs: _unsigned(entries[5]),
    );
    final VoiceSignalBody body = switch (kind) {
      VoiceSignalKind.join => const VoiceJoin(),
      VoiceSignalKind.participantsQuery => const VoiceParticipantsQuery(),
      VoiceSignalKind.leave => VoiceLeave(
        VoiceLeaveReason.fromWireValue(_unsigned(entries[8])) ??
            (throw const FormatException('unknown leave reason')),
      ),
      VoiceSignalKind.offer => VoiceOffer(
        targetJoinId: _bytes(entries[8], VoiceSignalLimits.joinIdBytes),
        sdp: _text(entries[9]),
      ),
      VoiceSignalKind.answer => VoiceAnswer(
        targetJoinId: _bytes(entries[8], VoiceSignalLimits.joinIdBytes),
        sdp: _text(entries[9]),
        answersCounter: _unsigned(entries[10]),
      ),
      VoiceSignalKind.candidates => VoiceCandidates(
        targetJoinId: _bytes(entries[8], VoiceSignalLimits.joinIdBytes),
        candidates: [
          for (final item in _array(
            entries[9],
            VoiceSignalLimits.maximumCandidates,
          ))
            _candidate(item),
        ],
        end: _boolean(entries[10]),
      ),
      VoiceSignalKind.participants => VoiceParticipants([
        for (final item in _array(
          entries[8],
          VoiceSignalLimits.maximumParticipants,
        ))
          _participant(item),
      ]),
      VoiceSignalKind.roomText => VoiceRoomText(_text(entries[8])),
    };
    return VoiceSignalMessage(header: header, body: body);
  }

  static VoiceIceCandidate _candidate(CborValue value) {
    final entries = _map(value, const {0, 1, 2});
    return VoiceIceCandidate(
      candidate: _text(entries[0]),
      mid: _text(entries[1]),
      mline: _unsigned(entries[2]),
    );
  }

  static VoiceParticipant _participant(CborValue value) {
    final entries = _map(value, const {0, 1, 2});
    return VoiceParticipant(
      userId: _bytes(entries[0], VoiceSignalLimits.uuidBytes),
      deviceId: _bytes(entries[1], VoiceSignalLimits.uuidBytes),
      joinId: _bytes(entries[2], VoiceSignalLimits.joinIdBytes),
    );
  }

  static Map<int, CborValue> _map(CborValue value, Set<int> keys) {
    if (value is! CborMap ||
        value.entries.length != keys.length ||
        !value.entries.keys.every(keys.contains)) {
      throw const FormatException('unexpected map keys');
    }
    return value.entries;
  }

  static List<CborValue> _array(CborValue? value, int maximum) {
    if (value is! CborArray || value.items.length > maximum) {
      throw const FormatException('invalid array');
    }
    return value.items;
  }

  static Uint8List _bytes(CborValue? value, int length) {
    if (value is! CborBytes || value.value.length != length) {
      throw const FormatException('invalid byte string');
    }
    return value.value;
  }

  static int _unsigned(CborValue? value) {
    if (value is! CborUnsigned) {
      throw const FormatException('invalid unsigned integer');
    }
    return value.value;
  }

  static String _text(CborValue? value) {
    if (value is! CborText) {
      throw const FormatException('invalid text string');
    }
    return value.value;
  }

  static bool _boolean(CborValue? value) {
    if (value is! CborBool) {
      throw const FormatException('invalid boolean');
    }
    return value.value;
  }

  static bool _same(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}
