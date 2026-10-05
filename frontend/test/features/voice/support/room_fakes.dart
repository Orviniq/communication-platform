import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/native_room_control_crypto.dart';

const roomAlice = '10000000-0000-4000-8000-000000000001';
const roomAlicePhone = '1a000000-0000-4000-8000-000000000001';
const roomAliceTablet = '1b000000-0000-4000-8000-000000000001';
const roomBob = '20000000-0000-4000-8000-000000000002';
const roomBobPhone = '2a000000-0000-4000-8000-000000000002';
const roomCarol = '30000000-0000-4000-8000-000000000003';
const roomCarolPhone = '3a000000-0000-4000-8000-000000000003';
const roomDave = '40000000-0000-4000-8000-000000000004';
const roomDavePhone = '4a000000-0000-4000-8000-000000000004';

/// Each device's stand-in signing key. The fake core below treats it as both
/// halves of the pair, which is all a test of the protocol around the core
/// needs: a signature made under one device's key verifies under that key and
/// under no other.
Uint8List roomDeviceKey(String deviceId) =>
    fakeRoomDigest(utf8.encode('key'), utf8.encode(deviceId));

/// Stands in for the native room control operations.
///
/// It keeps the two properties the room protocol leans on and nothing else:
/// the canonical bytes are one deterministic encoding of the event, here its
/// projection frame, and the signature is bound to the signing device's key
/// and to every one of those bytes. A changed byte, or another device's key,
/// is refused exactly as the core refuses it, as `unauthenticatedInput`.
final class FakeRoomControlCore implements RoomControlCryptoPort {
  FakeRoomControlCore({required this.localDeviceId});

  final String localDeviceId;
  var seals = 0;
  var opens = 0;

  @override
  Future<Result<SignedRoomControlEvent>> seal(RoomControlEvent event) async {
    seals += 1;
    if (event.signerDeviceId != localDeviceId) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final canonical = encodeRoomControlProjection(event);
    return Result.success(
      SignedRoomControlEvent(
        event: event,
        controlStateHash: fakeRoomStateHash(canonical),
        canonicalBytes: canonical,
        signature: fakeRoomSignature(roomDeviceKey(localDeviceId), canonical),
      ),
    );
  }

  @override
  Future<Result<SignedRoomControlEvent>> open({
    required RoomSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) async {
    opens += 1;
    final expected = fakeRoomSignature(
      signerSigningPublic,
      control.canonicalBytes,
    );
    if (!_same(expected, control.signature)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final RoomControlEvent event;
    try {
      event = decodeRoomControlProjection(control.canonicalBytes);
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    if (event.signerUserId != control.signerUserId ||
        event.signerDeviceId != control.signerDeviceId) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(
      SignedRoomControlEvent(
        event: event,
        controlStateHash: fakeRoomStateHash(control.canonicalBytes),
        canonicalBytes: control.canonicalBytes,
        signature: control.signature,
      ),
    );
  }
}

Uint8List fakeRoomSignature(List<int> key, List<int> canonical) =>
    Uint8List.fromList([
      ...fakeRoomDigest([...key, 1], canonical),
      ...fakeRoomDigest([...key, 2], canonical),
    ]);

String fakeRoomStateHash(List<int> canonical) => fakeRoomDigest(
  utf8.encode('chat:v1:room-control-state'),
  canonical,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// A deterministic 32-byte mix of [seed] and [input]. Not a hash anybody
/// should trust: it only has to change when any byte of either changes.
Uint8List fakeRoomDigest(List<int> seed, List<int> input) {
  final output = Uint8List(32);
  var state = 0x811c9dc5;
  for (var round = 0; round < 32; round += 1) {
    for (final byte in seed) {
      state = ((state ^ byte) * 0x01000193) & 0xffffffff;
    }
    for (final byte in input) {
      state = ((state ^ byte) * 0x01000193) & 0xffffffff;
    }
    state = ((state ^ round) * 0x01000193) & 0xffffffff;
    output[round] = (state ^ (state >> 8) ^ (state >> 16)) & 0xff;
  }
  return output;
}

/// The authenticated live device lists, with each device's stand-in key.
final class FakeRoomLiveDevices implements RoomLiveDeviceResolverPort {
  FakeRoomLiveDevices(Map<String, List<String>> devicesByUser)
    : devicesByUser = {
        for (final entry in devicesByUser.entries)
          entry.key: List.of(entry.value),
      };

  final Map<String, List<String>> devicesByUser;
  final blockedUsers = <String>{};
  final lookups = <String>[];

  @override
  Future<Result<List<RoomAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId) async {
    lookups.add(userId);
    if (blockedUsers.contains(userId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return Result.success([
      for (final deviceId in devicesByUser[userId] ?? const <String>[])
        RoomAuthenticatedLiveDevice(
          userId: userId,
          deviceId: deviceId,
          signingPublic: roomDeviceKey(deviceId),
        ),
    ]);
  }
}

/// Sixteen bytes at a time, never the same twice for one seed.
final class FakeRoomIdentity implements RoomIdentityPort {
  FakeRoomIdentity(this.seed);

  final int seed;
  var _issued = 0;

  @override
  Future<Result<Uint8List>> randomIdentifier() async {
    _issued += 1;
    return Result.success(
      Uint8List.fromList(
        List<int>.generate(
          16,
          (index) => (seed * 31 + _issued * 7 + index * 13 + 1) & 0xff,
        ),
      ),
    );
  }
}

final class FakeRoomClock implements TimeSource {
  FakeRoomClock([DateTime? start])
    : _now = start ?? DateTime.utc(2026, 9, 30, 12);

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// Whether a session exists, as a test sets it.
final class FakeRoomSessions implements RoomPairwiseSessionPort {
  final established = <String>{};

  void establish(String localDeviceId, String remoteDeviceId) {
    established
      ..add('$localDeviceId>$remoteDeviceId')
      ..add('$remoteDeviceId>$localDeviceId');
  }

  @override
  Future<Result<bool>> hasSession({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  }) async =>
      Result.success(established.contains('$localDeviceId>$remoteDeviceId'));
}

/// Signs one event with [signerDeviceId]'s fake key, outside any use case.
Future<SignedRoomControlEvent> signRoomEvent({
  required String signerUserId,
  required String signerDeviceId,
  required String roomId,
  required int revision,
  required SignedRoomControlEvent? previous,
  required RoomControlOperation operation,
  required int eventMarker,
  int createdMs = 1790000000000,
}) async {
  final result = await FakeRoomControlCore(localDeviceId: signerDeviceId).seal(
    RoomControlEvent(
      eventId: (eventMarker & 0xff).toRadixString(16).padLeft(2, '0') * 16,
      roomId: roomId,
      revision: revision,
      previousControlStateHash: previous?.controlStateHash,
      signerUserId: signerUserId,
      signerDeviceId: signerDeviceId,
      createdMs: createdMs + revision,
      operation: operation,
    ),
  );
  return (result as Success<SignedRoomControlEvent>).value;
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
