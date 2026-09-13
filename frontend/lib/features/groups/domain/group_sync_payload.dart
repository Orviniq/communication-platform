import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

/// Framing for the group payloads an ordinary pairwise envelope carries.
///
/// ```text
/// "CPGSV001" || kind:u8 || body
///   kind 1, control:    entry
///   kind 2, request:    group_id[32] || have_revision:u32 || have_state_hash[32]
///   kind 3, transcript: group_id[32] || base_revision:u32 || base_state_hash[32]
///                       || count:u16 || count x entry
/// entry = signer_user_id[16] || signer_device_id[16]
///         || canonical_length:u32 || canonical_control || signature[64]
/// ```
///
/// A revision of zero carries an all-zero hash. The control inside an entry is
/// deterministic CBOR the native core built and signed. This layer frames it and
/// never interprets it: the native core opens every entry, under the signing
/// key of the device the entry names, before anything in it is believed.
abstract final class GroupSyncProtocolV1 {
  static const List<int> magic = [
    0x43,
    0x50,
    0x47,
    0x53,
    0x56,
    0x30,
    0x30,
    0x31,
  ];
  static const int kindControl = 1;
  static const int kindStateRequest = 2;
  static const int kindTranscript = 3;

  /// Kept well under the largest envelope bucket, so a payload always fits
  /// one envelope after the pairwise header and padding prefix.
  static const int maximumPayloadBytes = 200000;
}

final class GroupSignedControlBytes {
  GroupSignedControlBytes({
    required String signerUserId,
    required String signerDeviceId,
    required Uint8List canonicalBytes,
    required Uint8List signature,
  }) : signerUserId = signerUserId.toLowerCase(),
       signerDeviceId = signerDeviceId.toLowerCase(),
       canonicalBytes = Uint8List.fromList(canonicalBytes),
       signature = Uint8List.fromList(signature) {
    if (!_uuid.hasMatch(this.signerUserId) ||
        !_uuid.hasMatch(this.signerDeviceId) ||
        this.canonicalBytes.isEmpty ||
        this.canonicalBytes.length >
            SignedGroupControlEvent.maximumCanonicalBytes ||
        this.signature.length != SignedGroupControlEvent.signatureBytes) {
      throw const FormatException('invalid signed group control bytes');
    }
  }

  factory GroupSignedControlBytes.fromStored(StoredGroupControl stored) =>
      GroupSignedControlBytes(
        signerUserId: stored.signerUserId,
        signerDeviceId: stored.signerDeviceId,
        canonicalBytes: stored.canonicalBytes,
        signature: stored.signature,
      );

  factory GroupSignedControlBytes.fromSigned(SignedGroupControlEvent signed) =>
      GroupSignedControlBytes(
        signerUserId: signed.event.signerUserId,
        signerDeviceId: signed.event.signerDeviceId,
        canonicalBytes: signed.canonicalBytes,
        signature: signed.signature,
      );

  final String signerUserId;
  final String signerDeviceId;
  final Uint8List canonicalBytes;
  final Uint8List signature;
}

sealed class GroupSyncPayload {
  const GroupSyncPayload();
}

/// One control event, fanned out by the device that signed it.
final class GroupControlDelivery extends GroupSyncPayload {
  const GroupControlDelivery(this.control);

  final GroupSignedControlBytes control;
}

/// Asks a member for every control event after the state this device holds.
final class GroupStateRequestPayload extends GroupSyncPayload {
  GroupStateRequestPayload({
    required this.groupId,
    required this.haveRevision,
    required this.haveStateHash,
  }) {
    _validateBase(groupId, haveRevision, haveStateHash);
  }

  final String groupId;
  final int haveRevision;
  final String? haveStateHash;
}

/// A contiguous run of a group's accepted control events.
///
/// [baseRevision] and [baseStateHash] name the state the first entry builds
/// on. An answer with no entries says the asker already holds the state the
/// member holds.
final class GroupTranscriptPayload extends GroupSyncPayload {
  GroupTranscriptPayload({
    required this.groupId,
    required this.baseRevision,
    required this.baseStateHash,
    required Iterable<GroupSignedControlBytes> entries,
  }) : entries = List.unmodifiable(entries) {
    _validateBase(groupId, baseRevision, baseStateHash);
    if (this.entries.length > 0xffff) {
      throw const FormatException('too many transcript entries');
    }
  }

  final String groupId;
  final int baseRevision;
  final String? baseStateHash;
  final List<GroupSignedControlBytes> entries;
}

abstract final class GroupSyncPayloadCodec {
  static bool matches(List<int> bytes) {
    if (bytes.length < GroupSyncProtocolV1.magic.length) return false;
    for (var index = 0; index < GroupSyncProtocolV1.magic.length; index += 1) {
      if (bytes[index] != GroupSyncProtocolV1.magic[index]) return false;
    }
    return true;
  }

  /// Throws [FormatException] for a payload that would not fit one envelope.
  static Uint8List encode(GroupSyncPayload payload) {
    final writer = BytesBuilder(copy: false)..add(GroupSyncProtocolV1.magic);
    switch (payload) {
      case GroupControlDelivery(:final control):
        writer.addByte(GroupSyncProtocolV1.kindControl);
        _writeEntry(writer, control);
      case GroupStateRequestPayload(
        :final groupId,
        :final haveRevision,
        :final haveStateHash,
      ):
        writer
          ..addByte(GroupSyncProtocolV1.kindStateRequest)
          ..add(_hexBytes(groupId))
          ..add(_u32(haveRevision))
          ..add(_hashBytes(haveStateHash));
      case GroupTranscriptPayload(
        :final groupId,
        :final baseRevision,
        :final baseStateHash,
        :final entries,
      ):
        writer
          ..addByte(GroupSyncProtocolV1.kindTranscript)
          ..add(_hexBytes(groupId))
          ..add(_u32(baseRevision))
          ..add(_hashBytes(baseStateHash))
          ..add(_u16(entries.length));
        for (final entry in entries) {
          _writeEntry(writer, entry);
          if (writer.length > GroupSyncProtocolV1.maximumPayloadBytes) {
            throw const FormatException('group payload too large');
          }
        }
    }
    if (writer.length > GroupSyncProtocolV1.maximumPayloadBytes) {
      throw const FormatException('group payload too large');
    }
    return writer.takeBytes();
  }

  /// Throws [FormatException] for anything that is not exactly one payload.
  static GroupSyncPayload decode(Uint8List bytes) {
    if (bytes.length > GroupSyncProtocolV1.maximumPayloadBytes ||
        !matches(bytes)) {
      throw const FormatException('not a group payload');
    }
    final reader = _Reader(bytes, GroupSyncProtocolV1.magic.length);
    final payload = switch (reader.u8()) {
      GroupSyncProtocolV1.kindControl => GroupControlDelivery(
        _readEntry(reader),
      ),
      GroupSyncProtocolV1.kindStateRequest => () {
        final groupId = _hex(reader.take(32));
        final revision = reader.u32();
        return GroupStateRequestPayload(
          groupId: groupId,
          haveRevision: revision,
          haveStateHash: _readHash(reader, revision),
        );
      }(),
      GroupSyncProtocolV1.kindTranscript => () {
        final groupId = _hex(reader.take(32));
        final revision = reader.u32();
        final hash = _readHash(reader, revision);
        final count = reader.u16();
        return GroupTranscriptPayload(
          groupId: groupId,
          baseRevision: revision,
          baseStateHash: hash,
          entries: [
            for (var index = 0; index < count; index += 1) _readEntry(reader),
          ],
        );
      }(),
      _ => throw const FormatException('unsupported group payload kind'),
    };
    if (!reader.finished) {
      throw const FormatException('trailing group payload bytes');
    }
    return payload;
  }

  static void _writeEntry(BytesBuilder writer, GroupSignedControlBytes entry) {
    writer
      ..add(protocolUuidBytes(entry.signerUserId))
      ..add(protocolUuidBytes(entry.signerDeviceId))
      ..add(_u32(entry.canonicalBytes.length))
      ..add(entry.canonicalBytes)
      ..add(entry.signature);
  }

  static GroupSignedControlBytes _readEntry(_Reader reader) {
    final signerUserId = protocolUuidString(reader.take(16));
    final signerDeviceId = protocolUuidString(reader.take(16));
    final length = reader.u32();
    if (length == 0 || length > SignedGroupControlEvent.maximumCanonicalBytes) {
      throw const FormatException('invalid group control length');
    }
    return GroupSignedControlBytes(
      signerUserId: signerUserId,
      signerDeviceId: signerDeviceId,
      canonicalBytes: reader.take(length),
      signature: reader.take(SignedGroupControlEvent.signatureBytes),
    );
  }

  static String? _readHash(_Reader reader, int revision) {
    final bytes = reader.take(32);
    if (revision == 0) {
      if (bytes.any((byte) => byte != 0)) {
        throw const FormatException('a zero revision carries no hash');
      }
      return null;
    }
    return _hex(bytes);
  }
}

void _validateBase(String groupId, int revision, String? hash) {
  if (!_hexValue.hasMatch(groupId) ||
      groupId.length != GroupState.groupIdBytes * 2 ||
      revision < 0 ||
      revision > GroupControlEvent.maximumRevision ||
      (revision == 0) != (hash == null) ||
      (hash != null &&
          (!_hexValue.hasMatch(hash) ||
              hash.length != GroupState.stateHashBytes * 2))) {
    throw const FormatException('invalid group state reference');
  }
}

final class _Reader {
  _Reader(this.bytes, this.offset);

  final Uint8List bytes;
  int offset;

  bool get finished => offset == bytes.length;

  Uint8List take(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('truncated group payload');
    }
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    return value;
  }

  int u8() => take(1)[0];

  int u16() => ByteData.sublistView(take(2)).getUint16(0);

  int u32() => ByteData.sublistView(take(4)).getUint32(0);
}

Uint8List _u16(int value) {
  if (value < 0 || value > 0xffff) {
    throw const FormatException('value out of range');
  }
  return Uint8List(2)..buffer.asByteData().setUint16(0, value);
}

Uint8List _u32(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw const FormatException('value out of range');
  }
  return Uint8List(4)..buffer.asByteData().setUint32(0, value);
}

Uint8List _hashBytes(String? hash) =>
    hash == null ? Uint8List(32) : _hexBytes(hash);

Uint8List _hexBytes(String value) {
  if (value.length.isOdd || !_hexValue.hasMatch(value)) {
    throw const FormatException('invalid hexadecimal value');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

String _hex(List<int> bytes) => protocolBytesToHex(bytes);

final RegExp _hexValue = RegExp(r'^[0-9a-f]*$');

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
