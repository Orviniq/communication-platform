import 'dart:typed_data';

import 'package:communication_platform/core/protocol/deterministic_cbor.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';

/// What decoding one opened payload found.
sealed class PresenceSignalDecoding {
  const PresenceSignalDecoding();
}

/// A payload of this version and a kind it defines, every field in bounds.
final class DecodedPresenceSignal extends PresenceSignalDecoding {
  const DecodedPresenceSignal(this.message);

  final PresenceSignalMessage message;
}

/// Not `CPPSV001` at all. The payload belongs to another channel.
final class NotPresenceSignal extends PresenceSignalDecoding {
  const NotPresenceSignal();
}

/// `CPPSV001` of a major version this build does not speak: dropped.
final class UnsupportedPresenceSignalVersion extends PresenceSignalDecoding {
  const UnsupportedPresenceSignalVersion(this.version);

  final int version;
}

/// A kind this version does not define: ignored, so that a later build can
/// add one without breaking this one.
final class UnknownPresenceSignalKind extends PresenceSignalDecoding {
  const UnknownPresenceSignalKind(this.kind);

  final int kind;
}

/// `CPPSV001` of this version whose body is not well formed.
final class MalformedPresenceSignal extends PresenceSignalDecoding {
  const MalformedPresenceSignal();
}

/// `CPPSV001`, typing and the online status (ADR-098 D2):
///
/// ```text
/// "CPPSV001" || version:u8 (= 1) || kind:u8 || deterministic-CBOR body
/// ```
///
/// The body is a map with small unsigned integer keys under the rules
/// `CPVSV001` uses: keys 0 to 3 are the header, 4 to 7 are reserved, and body
/// keys begin at 8. Every key a kind defines is required and no other is
/// allowed. It encodes and decodes CBOR, and implements no cryptographic
/// primitive.
abstract final class PresenceSignalCodec {
  static const version = 1;

  /// The plaintext bucket 1024 carries under a regular ratchet header. Every
  /// kind fits it, so every presence frame is a 1024-byte blob; and no
  /// volatile frame carries an initial header (ADR-077 B).
  static const maximumPayloadBytes = 942;

  static const _magic = <int>[0x43, 0x50, 0x50, 0x53, 0x56, 0x30, 0x30, 0x31];
  static const _prefixBytes = 10;

  /// A body is one flat map.
  static const _maximumNesting = 1;

  static const _headerKeys = {0, 1, 2, 3};

  /// Whether [payload] claims to be `CPPSV001`.
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
  /// 1024-byte frame carries.
  static Result<Uint8List> encode(PresenceSignalMessage message) {
    final encoded = _encode(message);
    if (encoded.length > maximumPayloadBytes) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    return Result.success(encoded);
  }

  static PresenceSignalDecoding decode(Uint8List payload) {
    if (!matches(payload)) {
      return const NotPresenceSignal();
    }
    if (payload.length < _prefixBytes) {
      return const MalformedPresenceSignal();
    }
    final payloadVersion = payload[_magic.length];
    if (payloadVersion != version) {
      return UnsupportedPresenceSignalVersion(payloadVersion);
    }
    final kindValue = payload[_magic.length + 1];
    final kind = PresenceSignalKind.fromWireValue(kindValue);
    if (kind == null) {
      return UnknownPresenceSignalKind(kindValue);
    }
    if (payload.length > maximumPayloadBytes) {
      return const MalformedPresenceSignal();
    }
    try {
      final body = DeterministicCbor.decode(
        Uint8List.sublistView(payload, _prefixBytes),
        maximumNesting: _maximumNesting,
      );
      final message = _message(kind, body);
      // A payload is accepted only as the bytes its own sender would have
      // written.
      if (!_same(_encode(message), payload)) {
        return const MalformedPresenceSignal();
      }
      return DecodedPresenceSignal(message);
    } on CborFormatException {
      return const MalformedPresenceSignal();
    } on FormatException {
      return const MalformedPresenceSignal();
    }
  }

  static Uint8List _encode(PresenceSignalMessage message) {
    final header = message.header;
    final entries = <int, CborValue>{
      0: CborBytes(header.senderUserId),
      1: CborBytes(header.senderDeviceId),
      2: CborBytes(header.instanceId),
      3: CborUnsigned(header.counter),
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

  static Map<int, CborValue> _bodyEntries(PresenceSignalBody body) =>
      switch (body) {
        PresenceWatch(:final conversationId, :final leaseMs) => {
          8: CborBytes(conversationId),
          9: CborUnsigned(leaseMs),
        },
        PresenceHere(:final conversationId, :final typing) => {
          8: CborBytes(conversationId),
          9: CborBool(typing),
        },
        PresenceTyping(:final conversationId, :final active, :final ttlMs) => {
          8: CborBytes(conversationId),
          9: CborBool(active),
          if (ttlMs != null) 10: CborUnsigned(ttlMs),
        },
        PresenceGone(:final reason) => {8: CborUnsigned(reason.wireValue)},
      };

  static PresenceSignalMessage _message(
    PresenceSignalKind kind,
    CborValue value,
  ) {
    if (value is! CborMap) {
      throw const FormatException('a body is a map');
    }
    final entries = value.entries;
    final bodyKeys = switch (kind) {
      PresenceSignalKind.watch || PresenceSignalKind.here => const {8, 9},
      // Key 10 is present exactly when the typing is active; the model
      // refuses either mismatch.
      PresenceSignalKind.typing =>
        entries.containsKey(10) ? const {8, 9, 10} : const {8, 9},
      PresenceSignalKind.gone => const {8},
    };
    // The reserved 4 to 7 included: a later header field is a later version.
    if (entries.length != _headerKeys.length + bodyKeys.length ||
        !entries.keys.every(
          (key) => _headerKeys.contains(key) || bodyKeys.contains(key),
        )) {
      throw const FormatException('unexpected body keys');
    }
    final header = PresenceSignalHeader(
      senderUserId: _bytes(entries[0], PresenceSignalLimits.uuidBytes),
      senderDeviceId: _bytes(entries[1], PresenceSignalLimits.uuidBytes),
      instanceId: _bytes(entries[2], PresenceSignalLimits.instanceIdBytes),
      counter: _unsigned(entries[3]),
    );
    final PresenceSignalBody body = switch (kind) {
      PresenceSignalKind.watch => PresenceWatch(
        conversationId: _conversation(entries[8]),
        leaseMs: _unsigned(entries[9]),
      ),
      PresenceSignalKind.here => PresenceHere(
        conversationId: _conversation(entries[8]),
        typing: _boolean(entries[9]),
      ),
      PresenceSignalKind.typing => PresenceTyping(
        conversationId: _conversation(entries[8]),
        active: _boolean(entries[9]),
        ttlMs: entries.containsKey(10) ? _unsigned(entries[10]) : null,
      ),
      PresenceSignalKind.gone => PresenceGone(
        PresenceGoneReason.fromWireValue(_unsigned(entries[8])) ??
            (throw const FormatException('unknown gone reason')),
      ),
    };
    return PresenceSignalMessage(header: header, body: body);
  }

  static Uint8List _conversation(CborValue? value) =>
      _bytes(value, PresenceSignalLimits.conversationIdBytes);

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
