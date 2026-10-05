import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('every kind', () {
    for (final body in bodies()) {
      test('${body.kind.name} round-trips byte for byte', () {
        final message = VoiceSignalMessage(header: header(), body: body);
        final encoded = encode(message);

        expect(encoded.sublist(0, 8), ascii.encode('CPVSV001'));
        expect(encoded[8], 1, reason: 'the version byte');
        expect(encoded[9], body.kind.wireValue, reason: 'the kind byte');

        final decoded = VoiceSignalCodec.decode(encoded);
        final read = (decoded as DecodedVoiceSignal).message;
        expect(read.kind, body.kind);
        expect(read.header.roomId, bytes(0x11, 32));
        expect(read.header.joinId, bytes(0x22, 16));
        expect(read.header.senderUserId, bytes(0x33, 16));
        expect(read.header.senderDeviceId, bytes(0x44, 16));
        expect(read.header.counter, 7);
        expect(read.header.createdMs, 1759190400000);
        expect(encode(read), encoded);
      });
    }

    test('the bodies decode to the fields they were written with', () {
      final offer = decodeBody(
        VoiceOffer(targetJoinId: bytes(0x55, 16), sdp: sdp),
      );
      expect((offer as VoiceOffer).targetJoinId, bytes(0x55, 16));
      expect(offer.sdp, sdp);

      final answer = decodeBody(
        VoiceAnswer(
          targetJoinId: bytes(0x56, 16),
          sdp: sdp,
          answersCounter: 0xffffffff,
        ),
      );
      expect((answer as VoiceAnswer).answersCounter, 0xffffffff);

      final candidates = decodeBody(
        VoiceCandidates(
          targetJoinId: bytes(0x57, 16),
          candidates: [
            VoiceIceCandidate(candidate: candidateLine, mid: '0', mline: 0),
            VoiceIceCandidate(candidate: candidateLine, mid: 'audio', mline: 3),
          ],
          end: true,
        ),
      );
      candidates as VoiceCandidates;
      expect(candidates.end, isTrue);
      expect(candidates.candidates.map((item) => item.mid), ['0', 'audio']);
      expect(candidates.candidates.map((item) => item.mline), [0, 3]);

      final participants = decodeBody(
        VoiceParticipants([
          VoiceParticipant(
            userId: bytes(0x61, 16),
            deviceId: bytes(0x62, 16),
            joinId: bytes(0x63, 16),
          ),
        ]),
      );
      final member = (participants as VoiceParticipants).members.single;
      expect(member.userId, bytes(0x61, 16));
      expect(member.deviceId, bytes(0x62, 16));
      expect(member.joinId, bytes(0x63, 16));

      final leave = decodeBody(
        const VoiceLeave(VoiceLeaveReason.roomStateChanged),
      );
      expect((leave as VoiceLeave).reason, VoiceLeaveReason.roomStateChanged);

      final text = decodeBody(VoiceRoomText('سلام — hello 👋'));
      expect((text as VoiceRoomText).text, 'سلام — hello 👋');
    });
  });

  test('a join is exactly the bytes deterministic CBOR gives', () {
    // RFC 8949 §4.2.1 worked by hand, so the codec is checked against the
    // rule rather than against itself: a six-entry map, keys ascending, each
    // byte string with a one-byte length, and 1000 in its shortest form.
    final expected = <int>[
      ...ascii.encode('CPVSV001'),
      0x01,
      0x01,
      0xa6,
      0x00,
      0x58,
      0x20,
      ...bytes(0x11, 32),
      0x01,
      0x50,
      ...bytes(0x22, 16),
      0x02,
      0x50,
      ...bytes(0x33, 16),
      0x03,
      0x50,
      ...bytes(0x44, 16),
      0x04,
      0x01,
      0x05,
      0x19,
      0x03,
      0xe8,
    ];
    final message = VoiceSignalMessage(
      header: header(counter: 1, createdMs: 1000),
      body: const VoiceJoin(),
    );

    expect(encode(message), expected);
    expect(
      VoiceSignalCodec.decode(Uint8List.fromList(expected)),
      isA<DecodedVoiceSignal>(),
    );
  });

  group('the version rule', () {
    test('an unknown major version is reported before the body is read', () {
      for (final version in const [0, 2, 255]) {
        final decoded = VoiceSignalCodec.decode(
          raw(version: version, kind: 1, body: const [0xff, 0xff]),
        );
        expect(
          (decoded as UnsupportedVoiceSignalVersion).version,
          version,
          reason: 'version $version',
        );
      }
    });

    test('an unknown kind of this version is ignored, whatever follows', () {
      for (final kind in const [0, 9, 200]) {
        final decoded = VoiceSignalCodec.decode(
          raw(kind: kind, body: const [0xff]),
        );
        expect((decoded as UnknownVoiceSignalKind).kind, kind);
      }
    });

    test('another magic is another channel', () {
      for (final payload in [
        ascii.encode('CPVRV001'),
        [...ascii.encode('CPVRV001'), 1, 1, 0xa0],
        [...ascii.encode('CPGSV001'), 1, 1],
        ascii.encode('CPVSV00'),
        <int>[],
      ]) {
        expect(
          VoiceSignalCodec.decode(Uint8List.fromList(payload)),
          isA<NotVoiceSignal>(),
        );
        expect(VoiceSignalCodec.matches(payload), isFalse);
      }
    });
  });

  group('a malformed body is refused', () {
    final cases = <String, List<int>>{
      'magic and version with no kind': [...ascii.encode('CPVSV001'), 1],
      'no body at all': [],
      'a body that is not a map': [0x80],
      'a counter in a longer form than it needs': [
        0xa6,
        ...headerEntries(counter: [0x18, 0x01]),
      ],
      'a created time in a longer form than it needs': [
        0xa6,
        ...headerEntries(createdMs: [0x1a, 0x00, 0x00, 0x03, 0xe8]),
      ],
      'keys out of order': [
        0xa6,
        ...entry(1, [0x50, ...bytes(0x22, 16)]),
        ...entry(0, [0x58, 0x20, ...bytes(0x11, 32)]),
        ...entry(2, [0x50, ...bytes(0x33, 16)]),
        ...entry(3, [0x50, ...bytes(0x44, 16)]),
        ...entry(4, [0x07]),
        ...entry(5, [0x00]),
      ],
      'a key twice': [
        0xa7,
        ...headerEntries(),
        ...entry(5, [0x00]),
      ],
      'an indefinite-length map': [0xbf, ...headerEntries(), 0xff],
      'a tagged value': [
        0xa6,
        ...headerEntries(counter: [0xc1, 0x07]),
      ],
      'a float': [
        0xa6,
        ...headerEntries(createdMs: [0xfa, 0x3f, 0x80, 0x00, 0x00]),
      ],
      'a null': [
        0xa6,
        ...headerEntries(createdMs: [0xf6]),
      ],
      'a negative integer': [
        0xa6,
        ...headerEntries(createdMs: [0x20]),
      ],
      'a byte after the body': [0xa6, ...headerEntries(), 0x00],
      'a missing header key': [0xa5, ...headerEntries(withCreatedMs: false)],
      'the reserved key 6': [
        0xa7,
        ...headerEntries(),
        ...entry(6, [0x00]),
      ],
      'a key the kind does not define': [
        0xa7,
        ...headerEntries(),
        ...entry(8, [0x00]),
      ],
      'a room id of 31 bytes': [
        0xa6,
        ...headerEntries(roomId: [0x58, 0x1f, ...bytes(0x11, 31)]),
      ],
      'a room id as text': [
        0xa6,
        ...headerEntries(roomId: [0x78, 0x20, ...List.filled(32, 0x61)]),
      ],
      'a counter of zero': [
        0xa6,
        ...headerEntries(counter: [0x00]),
      ],
      'a counter above 32 bits': [
        0xa6,
        ...headerEntries(counter: [0x1b, 0, 0, 0, 1, 0, 0, 0, 0]),
      ],
      'a length longer than what is left': [
        0xa6,
        ...headerEntries(roomId: [0x59, 0xff, 0xff]),
      ],
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final payload = entry.key == 'magic and version with no kind'
            ? Uint8List.fromList(entry.value)
            : raw(kind: VoiceSignalKind.join.wireValue, body: entry.value);
        expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
      });
    }

    test('a leave with a reason this version does not define', () {
      final payload = raw(
        kind: VoiceSignalKind.leave.wireValue,
        body: [
          0xa7,
          ...headerEntries(),
          ...entry(8, [0x04]),
        ],
      );
      expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
    });

    test('nine candidates in one batch', () {
      final candidate = [0xa3, 0x00, 0x61, 0x63, 0x01, 0x61, 0x30, 0x02, 0x00];
      final payload = raw(
        kind: VoiceSignalKind.candidates.wireValue,
        body: [
          0xa9,
          ...headerEntries(),
          ...entry(8, [0x50, ...bytes(0x55, 16)]),
          ...entry(9, [0x89, for (var i = 0; i < 9; i += 1) ...candidate]),
          ...entry(10, [0xf5]),
        ],
      );
      expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
    });

    test('eleven participants', () {
      final member = [
        0xa3,
        0x00,
        0x50,
        ...bytes(0x61, 16),
        0x01,
        0x50,
        ...bytes(0x62, 16),
        0x02,
        0x50,
        ...bytes(0x63, 16),
      ];
      final payload = raw(
        kind: VoiceSignalKind.participants.wireValue,
        body: [
          0xa7,
          ...headerEntries(),
          ...entry(8, [0x8b, for (var i = 0; i < 11; i += 1) ...member]),
        ],
      );
      expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
    });

    test('room text that is not UTF-8', () {
      final payload = raw(
        kind: VoiceSignalKind.roomText.wireValue,
        body: [
          0xa7,
          ...headerEntries(),
          ...entry(8, [0x62, 0xc3, 0x28]),
        ],
      );
      expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
    });

    test('room text over two thousand scalar values', () {
      final text = utf8.encode(List.filled(2001, 'a').join());
      final payload = raw(
        kind: VoiceSignalKind.roomText.wireValue,
        body: [
          0xa7,
          ...headerEntries(),
          ...entry(8, [0x79, text.length >> 8, text.length & 0xff, ...text]),
        ],
      );
      expect(VoiceSignalCodec.decode(payload), isA<MalformedVoiceSignal>());
    });
  });

  group('encoding', () {
    test('refuses a payload no signal frame can carry', () {
      final message = VoiceSignalMessage(
        header: header(),
        body: VoiceOffer(
          targetJoinId: bytes(0x55, 16),
          sdp: List.filled(VoiceSignalCodec.maximumPayloadBytes, 'v').join(),
        ),
      );
      final result = VoiceSignalCodec.encode(message);
      expect(
        (result as FailureResult<Uint8List>).failure,
        isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.limitExceeded,
        ),
      );
    });

    test('a message outside the bounds cannot be built', () {
      final candidate = VoiceIceCandidate(
        candidate: candidateLine,
        mid: '0',
        mline: 0,
      );
      expect(
        () => VoiceCandidates(
          targetJoinId: bytes(0x55, 16),
          candidates: List.filled(9, candidate),
          end: false,
        ),
        throwsFormatException,
      );
      expect(
        () => VoiceParticipants(
          List.filled(
            11,
            VoiceParticipant(
              userId: bytes(1, 16),
              deviceId: bytes(2, 16),
              joinId: bytes(3, 16),
            ),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => VoiceRoomText(List.filled(2001, 'a').join()),
        throwsFormatException,
      );
      expect(() => VoiceRoomText('\ud83d'), throwsFormatException);
      expect(
        () => VoiceOffer(targetJoinId: bytes(1, 15), sdp: sdp),
        throwsFormatException,
      );
      expect(() => header(counter: 0), throwsFormatException);
      expect(() => header(counter: 0x100000000), throwsFormatException);
      expect(() => header(createdMs: -1), throwsFormatException);
      expect(
        VoiceRoomText(List.filled(2000, '👋').join()).text.runes.length,
        2000,
        reason: 'the ceiling itself is allowed',
      );
    });

    test('nothing that names an address, a key or a person is printed', () {
      final values = <Object>[
        VoiceSignalMessage(
          header: header(),
          body: VoiceOffer(targetJoinId: bytes(0x55, 16), sdp: sdp),
        ),
        header(),
        VoiceAnswer(targetJoinId: bytes(0x55, 16), sdp: sdp, answersCounter: 1),
        VoiceIceCandidate(candidate: candidateLine, mid: '0', mline: 0),
        VoiceRoomText('a private remark'),
      ];
      for (final value in values) {
        final printed = value.toString();
        expect(printed, isNot(contains('192.0.2.1')));
        expect(printed, isNot(contains('fingerprint')));
        expect(printed, isNot(contains('private remark')));
        expect(printed, contains('<redacted>'));
      }
    });
  });
}

const sdp =
    'v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'a=group:BUNDLE 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'c=IN IP4 0.0.0.0\r\na=fingerprint:sha-256 AB:CD\r\n';

const candidateLine =
    'candidate:1 1 udp 41885439 192.0.2.1 50000 typ relay '
    'raddr 0.0.0.0 rport 0 generation 0';

List<VoiceSignalBody> bodies() => [
  const VoiceJoin(),
  const VoiceLeave(VoiceLeaveReason.userLeft),
  VoiceOffer(targetJoinId: bytes(0x55, 16), sdp: sdp),
  VoiceAnswer(targetJoinId: bytes(0x55, 16), sdp: sdp, answersCounter: 3),
  VoiceCandidates(
    targetJoinId: bytes(0x55, 16),
    candidates: [
      VoiceIceCandidate(candidate: candidateLine, mid: '0', mline: 0),
    ],
    end: false,
  ),
  const VoiceParticipantsQuery(),
  VoiceParticipants([
    VoiceParticipant(
      userId: bytes(0x61, 16),
      deviceId: bytes(0x62, 16),
      joinId: bytes(0x63, 16),
    ),
  ]),
  VoiceRoomText('hello'),
];

VoiceSignalHeader header({int counter = 7, int createdMs = 1759190400000}) =>
    VoiceSignalHeader(
      roomId: bytes(0x11, 32),
      joinId: bytes(0x22, 16),
      senderUserId: bytes(0x33, 16),
      senderDeviceId: bytes(0x44, 16),
      counter: counter,
      createdMs: createdMs,
    );

Uint8List encode(VoiceSignalMessage message) =>
    (VoiceSignalCodec.encode(message) as Success<Uint8List>).value;

VoiceSignalBody decodeBody(VoiceSignalBody body) {
  final encoded = encode(VoiceSignalMessage(header: header(), body: body));
  return (VoiceSignalCodec.decode(encoded) as DecodedVoiceSignal).message.body;
}

Uint8List bytes(int value, int length) =>
    Uint8List.fromList(List<int>.filled(length, value));

/// A `CPVSV001` payload with [body] written byte by byte.
Uint8List raw({int version = 1, required int kind, required List<int> body}) =>
    Uint8List.fromList([...ascii.encode('CPVSV001'), version, kind, ...body]);

List<int> entry(int key, List<int> value) => [key, ...value];

/// The six header entries, each value replaceable by raw bytes.
List<int> headerEntries({
  List<int>? roomId,
  List<int>? counter,
  List<int>? createdMs,
  bool withCreatedMs = true,
}) => [
  ...entry(0, roomId ?? [0x58, 0x20, ...bytes(0x11, 32)]),
  ...entry(1, [0x50, ...bytes(0x22, 16)]),
  ...entry(2, [0x50, ...bytes(0x33, 16)]),
  ...entry(3, [0x50, ...bytes(0x44, 16)]),
  ...entry(4, counter ?? [0x07]),
  if (withCreatedMs) ...entry(5, createdMs ?? [0x00]),
];
