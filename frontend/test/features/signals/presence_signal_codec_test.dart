import 'dart:typed_data';

import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_codec.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-098 D2: the `CPPSV001` payload, byte for byte.
void main() {
  const user = '00000000-0000-4000-8000-000000001001';
  const device = '00000000-0000-4000-8000-000000000901';
  final conversation = Uint8List.fromList(List.filled(32, 0xcd));

  PresenceSignalMessage message(PresenceSignalBody body, {int? counter}) =>
      PresenceSignalMessage(
        header: PresenceSignalHeader(
          senderUserId: protocolUuidBytes(user),
          senderDeviceId: protocolUuidBytes(device),
          instanceId: Uint8List.fromList(List.filled(16, 0xab)),
          counter: counter ?? PresenceSignalLimits.maximumCounter,
        ),
        body: body,
      );

  Uint8List encode(PresenceSignalMessage value) =>
      (PresenceSignalCodec.encode(value) as Success<Uint8List>).value;

  String hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Uint8List unhex(String value) => Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);

  // The magic, version 1, a kind, and the header every kind shares.
  String prefix(int kind, int entries) =>
      '4350505356303031'
      '01'
      '${kind.toRadixString(16).padLeft(2, '0')}'
      '${(0xa0 + entries).toRadixString(16)}'
      '0050${'00000000000040008000000000001001'}'
      '0150${'00000000000040008000000000000901'}'
      '0250${'ab' * 16}'
      '031affffffff';
  final conversationHex = '085820${'cd' * 32}';
  // 40,000 and 15,000, each in its shortest form.
  const lease = '09199c40';
  const ttl = '0a193a98';

  group('golden bytes', () {
    final cases = <String, (PresenceSignalBody, String, int)>{
      'watch': (
        PresenceWatch(conversationId: conversation, leaseMs: 40000),
        '${prefix(1, 6)}$conversationHex$lease',
        110,
      ),
      'here, typing': (
        PresenceHere(conversationId: conversation, typing: true),
        '${prefix(2, 6)}${conversationHex}09f5',
        108,
      ),
      'typing, active': (
        PresenceTyping(
          conversationId: conversation,
          active: true,
          ttlMs: 15000,
        ),
        '${prefix(3, 7)}${conversationHex}09f5$ttl',
        112,
      ),
      'typing, stopped': (
        PresenceTyping(conversationId: conversation, active: false),
        '${prefix(3, 6)}${conversationHex}09f4',
        108,
      ),
      'gone': (
        const PresenceGone(PresenceGoneReason.leftForeground),
        '${prefix(4, 5)}0801',
        73,
      ),
    };
    for (final MapEntry(key: name, value: (body, golden, length))
        in cases.entries) {
      test('$name is $length bytes, within one 1024-byte frame', () {
        final bytes = encode(message(body));

        expect(hex(bytes), golden);
        expect(bytes, hasLength(length));
        expect(
          bytes.length,
          lessThanOrEqualTo(PresenceSignalCodec.maximumPayloadBytes),
        );
        final decoded = PresenceSignalCodec.decode(bytes);
        expect(decoded, isA<DecodedPresenceSignal>());
        expect(hex(encode((decoded as DecodedPresenceSignal).message)), golden);
      });
    }
  });

  test('the magic is the one the router routes to presence', () {
    final bytes = encode(
      message(PresenceWatch(conversationId: conversation, leaseMs: 40000)),
    );

    expect(SignalChannel.of(bytes), SignalChannel.presence);
    expect(SignalChannel.presence.magic, 'CPPSV001'.codeUnits);
    expect(PresenceSignalCodec.matches('CPVSV001'.codeUnits), isFalse);
  });

  test('a message that cannot be built is refused before it is encoded', () {
    expect(
      () => PresenceWatch(conversationId: conversation, leaseMs: 0),
      throwsFormatException,
    );
    expect(
      () => PresenceWatch(conversationId: conversation, leaseMs: 60001),
      throwsFormatException,
    );
    expect(
      () => PresenceTyping(
        conversationId: conversation,
        active: true,
        ttlMs: 15001,
      ),
      throwsFormatException,
    );
    expect(
      () => PresenceTyping(conversationId: conversation, active: true),
      throwsFormatException,
    );
    expect(
      () => PresenceTyping(
        conversationId: conversation,
        active: false,
        ttlMs: 1000,
      ),
      throwsFormatException,
    );
    expect(
      () => PresenceWatch(conversationId: Uint8List(31), leaseMs: 40000),
      throwsFormatException,
    );
    expect(
      () => message(
        const PresenceGone(PresenceGoneReason.leftForeground),
        counter: 0,
      ),
      throwsFormatException,
    );
  });

  group('decoding refuses', () {
    final watch = '${prefix(1, 6)}$conversationHex$lease';
    final cases = <String, String>{
      // Counter 7 in five bytes rather than one.
      'a counter not in its shortest form': watch.replaceFirst(
        '031affffffff',
        '031a00000007',
      ),
      'a lease of 0': '${prefix(1, 6)}${conversationHex}0900',
      'a lease over 60,000 ms': '${prefix(1, 6)}${conversationHex}0919ea61',
      'a ttl over 15,000 ms': '${prefix(3, 7)}${conversationHex}09f50a193a99',
      'an active typing with no ttl': '${prefix(3, 6)}${conversationHex}09f5',
      'a stopped typing with a ttl':
          '${prefix(3, 7)}${conversationHex}09f4$ttl',
      'a reserved header key':
          '${prefix(1, 7).replaceFirst(RegExp(r'031affffffff$'), '031affffffff0400')}'
          '$conversationHex$lease',
      'keys out of order': '${prefix(1, 6)}$lease$conversationHex',
      'a trailing byte': '${watch}00',
      'an unknown gone reason': '${prefix(4, 5)}0803',
      'a header cut short': watch.substring(0, 18),
    };
    for (final MapEntry(key: name, value: bytes) in cases.entries) {
      test(name, () {
        expect(
          PresenceSignalCodec.decode(unhex(bytes)),
          isA<MalformedPresenceSignal>(),
          reason: name,
        );
      });
    }

    test('a later version and an unknown kind, without decoding them', () {
      final later = unhex(watch)..[8] = 2;
      final unknown = unhex(watch)..[9] = 9;

      expect(
        (PresenceSignalCodec.decode(later) as UnsupportedPresenceSignalVersion)
            .version,
        2,
      );
      expect(
        (PresenceSignalCodec.decode(unknown) as UnknownPresenceSignalKind).kind,
        9,
      );
      expect(
        PresenceSignalCodec.decode(Uint8List.fromList('CPVSV001'.codeUnits)),
        isA<NotPresenceSignal>(),
      );
    });

    test('more than a 1024-byte frame carries', () {
      final long = Uint8List.fromList([
        ...unhex(watch),
        ...List.filled(PresenceSignalCodec.maximumPayloadBytes, 0),
      ]);

      expect(PresenceSignalCodec.decode(long), isA<MalformedPresenceSignal>());
    });
  });
}
