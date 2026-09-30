import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// Signs and opens room control events through the shared native core.
///
/// The device signing key never leaves the native device state. This adapter
/// hands that opaque state to the core together with a projection of the
/// event, and gets back the canonical CBOR, the signature, and the chain hash,
/// all under the room's own domains (`native/crypto_core/src/room_control.rs`).
final class NativeRoomControlCrypto implements RoomControlCryptoPort {
  const NativeRoomControlCrypto({
    required this.crypto,
    required this.store,
    required this.localDeviceId,
    required this.clock,
  });

  final PairwiseCryptoPort crypto;
  final PairwiseTransportStore store;
  final String localDeviceId;
  final TimeSource clock;

  @override
  Future<Result<SignedRoomControlEvent>> seal(RoomControlEvent event) async {
    if (event.signerDeviceId != localDeviceId.toLowerCase()) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final contextResult = await store.readInboundContext(
      localDeviceId: localDeviceId,
    );
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final deviceState =
        (contextResult as Success<PairwiseInboundPreparationContext>)
            .value
            .deviceState
            .opaqueState;
    final Uint8List request;
    try {
      request =
          (_Writer()
                ..frame(deviceState)
                ..u32(
                  clock.now().toUtc().millisecondsSinceEpoch ~/
                      Duration.millisecondsPerDay,
                )
                ..frame(encodeRoomControlProjection(event)))
              .takeBytes();
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final response = await crypto.pairwiseOperation(
      operation: PairwiseCryptoOperation.sealRoomControl,
      payload: request,
    );
    if (response case FailureResult(failure: final failure)) {
      return Result.failure(_nativeFailure(failure));
    }
    final value = (response as Success<PairwiseCryptoResponse>).value;
    if (value.outcome != PairwiseCryptoOutcome.ok) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    try {
      final reader = _Reader(value.body);
      final canonical = reader.frame();
      final signature = reader.take(SignedRoomControlEvent.signatureBytes);
      final hash = reader.take(RoomState.stateHashBytes);
      if (!reader.finished) {
        throw const FormatException('trailing seal response bytes');
      }
      return Result.success(
        SignedRoomControlEvent(
          event: event,
          controlStateHash: protocolBytesToHex(hash),
          canonicalBytes: canonical,
          signature: signature,
        ),
      );
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  @override
  Future<Result<SignedRoomControlEvent>> open({
    required RoomSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) async {
    if (signerSigningPublic.length != 32) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final response = await crypto.pairwiseOperation(
      operation: PairwiseCryptoOperation.openRoomControl,
      payload:
          (_Writer()
                ..bytes(signerSigningPublic)
                ..frame(control.canonicalBytes)
                ..bytes(control.signature))
              .takeBytes(),
    );
    if (response case FailureResult(failure: final failure)) {
      return Result.failure(_nativeFailure(failure));
    }
    final value = (response as Success<PairwiseCryptoResponse>).value;
    if (value.outcome != PairwiseCryptoOutcome.ok) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final RoomControlEvent event;
    final String hash;
    try {
      final reader = _Reader(value.body);
      final projection = reader.frame();
      hash = protocolBytesToHex(reader.take(RoomState.stateHashBytes));
      if (!reader.finished) {
        throw const FormatException('trailing open response bytes');
      }
      event = decodeRoomControlProjection(projection);
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    // The key was chosen for the device the frame names. An event that names
    // anybody else inside its signed bytes was signed by a device this check
    // never authenticated for that identity.
    if (event.signerUserId != control.signerUserId ||
        event.signerDeviceId != control.signerDeviceId) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(
      SignedRoomControlEvent(
        event: event,
        controlStateHash: hash,
        canonicalBytes: control.canonicalBytes,
        signature: control.signature,
      ),
    );
  }
}

/// A native refusal of the event itself is a fact about the bytes, not the
/// device: the signature did not verify, or the event is not one this protocol
/// allows. Everything else, such as a core momentarily out of entropy, passes
/// through unchanged so that it can be retried.
Failure _nativeFailure(Failure failure) => switch (failure) {
  CryptoCoreFailure(code: CryptoCoreFailureCode.authenticationFailed) =>
    const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
  CryptoCoreFailure(
    code: CryptoCoreFailureCode.malformedInput ||
        CryptoCoreFailureCode.inputTooLarge ||
        CryptoCoreFailureCode.invalidArgument ||
        CryptoCoreFailureCode.unsupportedVersion ||
        CryptoCoreFailureCode.unsupportedOperation,
  ) =>
    const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
  _ => failure,
};

/// The frame the native core turns into canonical CBOR.
///
/// It mirrors `decode_projection` in `native/crypto_core/src/room_control.rs`
/// field for field. Only the roster and the name cross.
Uint8List encodeRoomControlProjection(RoomControlEvent event) {
  final writer = _Writer()
    ..u8(event.protocolVersion)
    ..bytes(_hexBytes(event.eventId, RoomControlEvent.eventIdBytes))
    ..bytes(_hexBytes(event.roomId, RoomState.roomIdBytes))
    ..u32(event.revision);
  final previous = event.previousControlStateHash;
  if (previous == null) {
    writer.u8(0);
  } else {
    writer
      ..u8(1)
      ..bytes(_hexBytes(previous, RoomState.stateHashBytes));
  }
  writer
    ..bytes(protocolUuidBytes(event.signerUserId))
    ..bytes(protocolUuidBytes(event.signerDeviceId))
    ..u64(event.createdMs)
    ..u8(event.operation.kind.wireValue);
  switch (event.operation) {
    case CreateRoomOperation(:final name, :final memberUserIds):
      writer
        ..text(name)
        ..userIds(memberUserIds);
    case AddRoomMembersOperation(:final userIds):
      writer.userIds(userIds);
    case RemoveRoomMemberOperation(:final targetUserId):
      writer.bytes(protocolUuidBytes(targetUserId));
    case RenameRoomOperation(:final name):
      writer.text(name);
  }
  return writer.takeBytes();
}

/// Reads the frame the native core returns for a verified event.
///
/// Throws [FormatException] for anything that is not exactly one projection.
RoomControlEvent decodeRoomControlProjection(Uint8List bytes) {
  final reader = _Reader(bytes);
  final version = reader.u8();
  final eventId = protocolBytesToHex(
    reader.take(RoomControlEvent.eventIdBytes),
  );
  final roomId = protocolBytesToHex(reader.take(RoomState.roomIdBytes));
  final revision = reader.u32();
  final previous = switch (reader.u8()) {
    0 => null,
    1 => protocolBytesToHex(reader.take(RoomState.stateHashBytes)),
    _ => throw const FormatException('invalid previous state marker'),
  };
  final signerUserId = protocolUuidString(reader.take(16));
  final signerDeviceId = protocolUuidString(reader.take(16));
  final createdMs = reader.u64();
  final RoomControlOperation operation = switch (RoomControlKind.fromWireValue(
    reader.u8(),
  )) {
    RoomControlKind.create => CreateRoomOperation(
      name: reader.text(),
      memberUserIds: reader.userIds(),
    ),
    RoomControlKind.addMembers => AddRoomMembersOperation(reader.userIds()),
    RoomControlKind.removeMember => RemoveRoomMemberOperation(
      protocolUuidString(reader.take(16)),
    ),
    RoomControlKind.rename => RenameRoomOperation(reader.text()),
    null => throw const FormatException('unsupported room control kind'),
  };
  if (!reader.finished) {
    throw const FormatException('trailing projection bytes');
  }
  return RoomControlEvent(
    protocolVersion: version,
    eventId: eventId,
    roomId: roomId,
    revision: revision,
    previousControlStateHash: previous,
    signerUserId: signerUserId,
    signerDeviceId: signerDeviceId,
    createdMs: createdMs,
    operation: operation,
  );
}

Uint8List _hexBytes(String value, int length) {
  if (value.length != length * 2 || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    throw const FormatException('invalid hexadecimal value');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

final class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);

  void u8(int value) {
    if (value < 0 || value > 0xff) {
      throw const FormatException('value out of range');
    }
    _builder.addByte(value);
  }

  void u16(int value) {
    if (value < 0 || value > 0xffff) {
      throw const FormatException('value out of range');
    }
    bytes(Uint8List(2)..buffer.asByteData().setUint16(0, value));
  }

  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const FormatException('value out of range');
    }
    bytes(Uint8List(4)..buffer.asByteData().setUint32(0, value));
  }

  void u64(int value) {
    if (value < 0) {
      throw const FormatException('value out of range');
    }
    bytes(Uint8List(8)..buffer.asByteData().setUint64(0, value));
  }

  void frame(Uint8List value) {
    if (value.length > 2 * 1024 * 1024) {
      throw const FormatException('frame too large');
    }
    u32(value.length);
    bytes(value);
  }

  void text(String value) => frame(Uint8List.fromList(utf8.encode(value)));

  void userIds(List<String> values) {
    u16(values.length);
    for (final value in values) {
      bytes(protocolUuidBytes(value));
    }
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  bool get finished => _offset == _bytes.length;

  int u8() => take(1).first;

  int u16() => ByteData.sublistView(take(2)).getUint16(0);

  int u32() => ByteData.sublistView(take(4)).getUint32(0);

  int u64() {
    final value = ByteData.sublistView(take(8)).getUint64(0);
    if (value < 0) {
      throw const FormatException('value out of range');
    }
    return value;
  }

  Uint8List frame() {
    final length = u32();
    if (length > 2 * 1024 * 1024) {
      throw const FormatException('frame too large');
    }
    return take(length);
  }

  String text() => utf8.decode(frame());

  List<String> userIds() => [
    for (var index = u16(); index > 0; index -= 1) protocolUuidString(take(16)),
  ];

  Uint8List take(int length) {
    final end = _offset + length;
    if (length < 0 || end > _bytes.length) {
      throw const FormatException('truncated frame');
    }
    final value = Uint8List.fromList(_bytes.sublist(_offset, end));
    _offset = end;
    return value;
  }
}
