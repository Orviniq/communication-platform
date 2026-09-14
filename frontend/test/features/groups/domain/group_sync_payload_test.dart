import 'dart:typed_data';

import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

const _user = '10000000-0000-4000-8000-000000000001';
const _device = '20000000-0000-4000-8000-000000000001';
final _groupId = 'ab' * 32;
final _hash = 'cd' * 32;

/// The frame an ordinary pairwise envelope carries a group payload in. It
/// never interprets the signed control inside an entry; the native core does.
void main() {
  final entry = GroupSignedControlBytes(
    signerUserId: _user,
    signerDeviceId: _device,
    canonicalBytes: Uint8List.fromList([1, 2, 3]),
    signature: Uint8List.fromList(List<int>.filled(64, 9)),
  );

  test('every payload kind survives a round trip byte for byte', () {
    final payloads = <GroupSyncPayload>[
      GroupControlDelivery(entry),
      GroupStateRequestPayload(
        groupId: _groupId,
        haveRevision: 0,
        haveStateHash: null,
      ),
      GroupStateRequestPayload(
        groupId: _groupId,
        haveRevision: 7,
        haveStateHash: _hash,
      ),
      GroupTranscriptPayload(
        groupId: _groupId,
        baseRevision: 2,
        baseStateHash: _hash,
        entries: [entry, entry],
      ),
      GroupTranscriptPayload(
        groupId: _groupId,
        baseRevision: 2,
        baseStateHash: _hash,
        entries: const [],
      ),
    ];
    for (final payload in payloads) {
      final bytes = GroupSyncPayloadCodec.encode(payload);
      expect(GroupSyncPayloadCodec.matches(bytes), isTrue);
      final decoded = GroupSyncPayloadCodec.decode(bytes);
      expect(decoded.runtimeType, payload.runtimeType);
      expect(GroupSyncPayloadCodec.encode(decoded), bytes);
    }

    final transcript =
        GroupSyncPayloadCodec.decode(GroupSyncPayloadCodec.encode(payloads[3]))
            as GroupTranscriptPayload;
    expect(transcript.groupId, _groupId);
    expect(transcript.baseRevision, 2);
    expect(transcript.baseStateHash, _hash);
    expect(transcript.entries, hasLength(2));
    for (final decoded in transcript.entries) {
      expect(decoded.signerUserId, _user);
      expect(decoded.signerDeviceId, _device);
      expect(decoded.canonicalBytes, [1, 2, 3]);
      expect(decoded.signature, entry.signature);
    }
  });

  test('a zero revision carries no hash and any other carries one', () {
    expect(
      () => GroupStateRequestPayload(
        groupId: _groupId,
        haveRevision: 0,
        haveStateHash: _hash,
      ),
      throwsFormatException,
    );
    expect(
      () => GroupStateRequestPayload(
        groupId: _groupId,
        haveRevision: 1,
        haveStateHash: null,
      ),
      throwsFormatException,
    );
    final bytes = GroupSyncPayloadCodec.encode(
      GroupStateRequestPayload(
        groupId: _groupId,
        haveRevision: 0,
        haveStateHash: null,
      ),
    );
    bytes[bytes.length - 1] = 1;
    expect(() => GroupSyncPayloadCodec.decode(bytes), throwsFormatException);
  });

  test('anything that is not exactly one payload is refused', () {
    final bytes = GroupSyncPayloadCodec.encode(GroupControlDelivery(entry));
    expect(
      () => GroupSyncPayloadCodec.decode(Uint8List.fromList([...bytes, 0])),
      throwsFormatException,
    );
    expect(
      () => GroupSyncPayloadCodec.decode(bytes.sublist(0, bytes.length - 1)),
      throwsFormatException,
    );
    final unknownKind = Uint8List.fromList(bytes)
      ..[GroupSyncProtocolV1.magic.length] = 9;
    expect(
      () => GroupSyncPayloadCodec.decode(unknownKind),
      throwsFormatException,
    );
    final otherMagic = Uint8List.fromList(bytes)..[0] = 0;
    expect(GroupSyncPayloadCodec.matches(otherMagic), isFalse);
    expect(
      () => GroupSyncPayloadCodec.decode(otherMagic),
      throwsFormatException,
    );
  });

  test('a transcript too large for one envelope is refused', () {
    final largest = GroupSignedControlBytes(
      signerUserId: _user,
      signerDeviceId: _device,
      canonicalBytes: Uint8List(SignedGroupControlEvent.maximumCanonicalBytes),
      signature: Uint8List(SignedGroupControlEvent.signatureBytes),
    );
    GroupTranscriptPayload transcript(int count) => GroupTranscriptPayload(
      groupId: _groupId,
      baseRevision: 0,
      baseStateHash: null,
      entries: List.filled(count, largest),
    );

    // Twelve of the largest entries fit under the bound and thirteen do not.
    expect(GroupSyncPayloadCodec.encode(transcript(12)), isNotEmpty);
    expect(
      () => GroupSyncPayloadCodec.encode(transcript(13)),
      throwsFormatException,
    );
  });
}
