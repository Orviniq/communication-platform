import 'dart:typed_data';

import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;

void main() {
  RoomSignedControlBytes entry(int marker) => RoomSignedControlBytes(
    signerUserId: roomAlice,
    signerDeviceId: roomAlicePhone,
    canonicalBytes: Uint8List.fromList(List<int>.filled(40, marker)),
    signature: Uint8List.fromList(List<int>.filled(64, marker + 1)),
  );

  test('each kind round-trips under its own magic', () {
    final payloads = <RoomSyncPayload>[
      RoomControlDelivery(entry(1)),
      RoomStateRequestPayload(
        roomId: _roomId,
        haveRevision: 3,
        haveStateHash: 'cd' * 32,
      ),
      RoomStateRequestPayload(
        roomId: _roomId,
        haveRevision: 0,
        haveStateHash: null,
      ),
      RoomTranscriptPayload(
        roomId: _roomId,
        baseRevision: 0,
        baseStateHash: null,
        entries: [entry(1), entry(2)],
      ),
    ];
    for (final payload in payloads) {
      final encoded = RoomSyncPayloadCodec.encode(payload);
      expect(encoded.sublist(0, 8), 'CPVRV001'.codeUnits);
      final decoded = RoomSyncPayloadCodec.decode(encoded);
      expect(decoded.runtimeType, payload.runtimeType);
      expect(RoomSyncPayloadCodec.encode(decoded), encoded);
    }
  });

  test('a session-start request is 77 bytes', () {
    // The number ADR-077 states for the smallest room payload.
    expect(
      RoomSyncPayloadCodec.encode(
        RoomStateRequestPayload(
          roomId: _roomId,
          haveRevision: 7,
          haveStateHash: 'cd' * 32,
        ),
      ),
      hasLength(77),
    );
  });

  test('a group payload is not a room payload, and back', () {
    final group = GroupSyncPayloadCodec.encode(
      GroupStateRequestPayload(
        groupId: _roomId,
        haveRevision: 1,
        haveStateHash: 'cd' * 32,
      ),
    );
    final room = RoomSyncPayloadCodec.encode(
      RoomStateRequestPayload(
        roomId: _roomId,
        haveRevision: 1,
        haveStateHash: 'cd' * 32,
      ),
    );

    expect(RoomSyncPayloadCodec.matches(group), isFalse);
    expect(GroupSyncPayloadCodec.matches(room), isFalse);
    expect(() => RoomSyncPayloadCodec.decode(group), throwsFormatException);
    // Nor is the call's signalling, which shares the first three bytes.
    expect(RoomSyncPayloadCodec.matches('CPVSV001'.codeUnits), isFalse);
  });

  test('anything that is not exactly one payload is refused', () {
    final request = RoomSyncPayloadCodec.encode(
      RoomStateRequestPayload(
        roomId: _roomId,
        haveRevision: 1,
        haveStateHash: 'cd' * 32,
      ),
    );
    final trailing = Uint8List.fromList([...request, 0]);
    final truncated = Uint8List.sublistView(request, 0, request.length - 1);
    final zeroWithHash = Uint8List.fromList(request)
      ..buffer.asByteData().setUint32(8 + 1 + 32, 0);
    final unknownKind = Uint8List.fromList(request)..[8] = 4;

    for (final bytes in [trailing, truncated, zeroWithHash, unknownKind]) {
      expect(() => RoomSyncPayloadCodec.decode(bytes), throwsFormatException);
    }
    expect(
      () => RoomSyncPayloadCodec.encode(
        RoomTranscriptPayload(
          roomId: _roomId,
          baseRevision: 0,
          baseStateHash: null,
          entries: [
            for (var index = 0; index < 13; index += 1)
              RoomSignedControlBytes(
                signerUserId: roomAlice,
                signerDeviceId: roomAlicePhone,
                canonicalBytes: Uint8List(16384),
                signature: Uint8List(64),
              ),
          ],
        ),
      ),
      throwsFormatException,
      reason: 'a transcript that would not fit one envelope is never built',
    );
  });
}
