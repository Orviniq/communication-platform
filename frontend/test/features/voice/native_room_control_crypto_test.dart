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
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/native_room_control_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;
final _previous = 'cd' * 32;

/// The adapter frames requests for the native core and reads its answers. It
/// signs nothing and verifies nothing itself: the core stand-in here records
/// exactly what it was handed and returns what the test tells it to. What the
/// core decides about a signature is `native/crypto_core/src/room_control.rs`'s
/// own tests.
void main() {
  test(
    'sealing hands the core the device state, the day and the event',
    () async {
      final core = _Core(
        (operation, payload) => _ok(operation, [
          ..._frame(const [0xaa, 0xbb]),
          ...List<int>.filled(64, 0x11),
          ...List<int>.filled(32, 0x22),
        ]),
      );
      final event = _rename();

      final result = await _adapter(core).seal(event);

      final signed = (result as Success<SignedRoomControlEvent>).value;
      expect(signed.event, same(event));
      expect(signed.canonicalBytes, [0xaa, 0xbb]);
      expect(signed.signature, List<int>.filled(64, 0x11));
      expect(signed.controlStateHash, '22' * 32);
      final (operation, payload) = core.calls.single;
      expect(operation, PairwiseCryptoOperation.sealRoomControl);
      expect(operation.wireValue, 20);
      final day =
          DateTime.utc(2026, 9, 30).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay;
      expect(payload, [
        ..._frame(const [5, 5, 5]),
        ..._u32(day),
        ..._frame(encodeRoomControlProjection(event)),
      ]);
    },
  );

  test('a device signs only as itself', () async {
    final core = _Core((operation, payload) => throw StateError('unreached'));

    final result = await _adapter(
      core,
    ).seal(_rename(signerDevice: roomBobPhone));

    expect(
      (result as FailureResult<SignedRoomControlEvent>).failure,
      const ValidationFailure(ValidationFailureKind.invalidInput),
    );
    expect(core.calls, isEmpty);
  });

  test('opening checks under the given key and decodes the event', () async {
    final event = _rename();
    final core = _Core(
      (operation, payload) => _ok(operation, [
        ..._frame(encodeRoomControlProjection(event)),
        ...List<int>.filled(32, 0x33),
      ]),
    );
    final control = _control();

    final result = await _adapter(core).open(
      control: control,
      signerSigningPublic: Uint8List.fromList(List<int>.filled(32, 7)),
    );

    final opened = (result as Success<SignedRoomControlEvent>).value;
    expect(opened.event.eventId, event.eventId);
    expect(opened.event.revision, 2);
    expect(opened.event.previousControlStateHash, _previous);
    expect((opened.event.operation as RenameRoomOperation).name, 'Renamed');
    expect(opened.controlStateHash, '33' * 32);
    expect(opened.canonicalBytes, control.canonicalBytes);
    expect(opened.signature, control.signature);
    final (operation, payload) = core.calls.single;
    expect(operation, PairwiseCryptoOperation.openRoomControl);
    expect(operation.wireValue, 21);
    expect(payload, [
      ...List<int>.filled(32, 7),
      ..._frame(control.canonicalBytes),
      ...control.signature,
    ]);
  });

  test('an event with a bad signature is refused', () async {
    // The native core answers a signature that does not verify under the
    // signer's key with `authenticationFailed`, before it reads a byte of the
    // event; the adapter reports that as input nobody authenticated.
    final core = _Core(
      (operation, payload) => const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      ),
    );

    final result = await _adapter(
      core,
    ).open(control: _control(), signerSigningPublic: Uint8List(32));

    expect(
      (result as FailureResult<SignedRoomControlEvent>).failure,
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });

  test('the keyed stand-in refuses a changed byte and another key', () async {
    // The stand-in every room protocol test signs with keeps the core's two
    // refusals, so those tests exercise a real one.
    final create = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: _roomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Standup',
        memberUserIds: [roomAlice, roomBob],
      ),
      eventMarker: 1,
    );
    final core = FakeRoomControlCore(localDeviceId: roomBobPhone);
    RoomSignedControlBytes bytes({Uint8List? canonical}) =>
        RoomSignedControlBytes(
          signerUserId: roomAlice,
          signerDeviceId: roomAlicePhone,
          canonicalBytes: canonical ?? create.canonicalBytes,
          signature: create.signature,
        );
    final tampered = Uint8List.fromList(create.canonicalBytes)..[40] ^= 1;

    expect(
      await core.open(
        control: bytes(),
        signerSigningPublic: roomDeviceKey(roomAlicePhone),
      ),
      isA<Success<SignedRoomControlEvent>>(),
    );
    for (final (control, key) in [
      (bytes(canonical: tampered), roomDeviceKey(roomAlicePhone)),
      (bytes(), roomDeviceKey(roomBobPhone)),
    ]) {
      expect(
        (await core.open(control: control, signerSigningPublic: key)
                as FailureResult<SignedRoomControlEvent>)
            .failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
  });

  test('an event naming a signer other than its frame is refused', () async {
    final core = _Core(
      (operation, payload) => _ok(operation, [
        ..._frame(
          encodeRoomControlProjection(_rename(signerDevice: roomBobPhone)),
        ),
        ...List<int>.filled(32, 0x33),
      ]),
    );

    final result = await _adapter(
      core,
    ).open(control: _control(), signerSigningPublic: Uint8List(32));

    expect(
      (result as FailureResult<SignedRoomControlEvent>).failure,
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });

  test('the projection is the frame the native core reads', () {
    // `rename_projection` in `room_control.rs`, byte for byte.
    final event = RoomControlEvent(
      eventId: '01' * 16,
      roomId: '02' * 32,
      revision: 2,
      previousControlStateHash: '03' * 32,
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      createdMs: 1700000000000,
      operation: const RenameRoomOperation('Room'),
    );

    expect(encodeRoomControlProjection(event), [
      1,
      ...List<int>.filled(16, 1),
      ...List<int>.filled(32, 2),
      ..._u32(2),
      1,
      ...List<int>.filled(32, 3),
      ...protocolUuidBytes(roomAlice),
      ...protocolUuidBytes(roomAlicePhone),
      ..._u64(1700000000000),
      RoomControlKind.rename.wireValue,
      ..._frame(utf8.encode('Room')),
    ]);
  });

  test('every control kind survives the projection', () {
    final operations = <RoomControlOperation>[
      CreateRoomOperation(
        name: 'Standup',
        memberUserIds: [roomCarol, roomAlice, roomBob],
      ),
      AddRoomMembersOperation([roomDave, roomCarol]),
      RemoveRoomMemberOperation(roomBob),
      const RenameRoomOperation('Weekly'),
    ];
    for (final operation in operations) {
      final first = operation is CreateRoomOperation;
      final event = RoomControlEvent(
        eventId: '0f' * 16,
        roomId: _roomId,
        revision: first ? 1 : 2,
        previousControlStateHash: first ? null : _previous,
        signerUserId: roomAlice,
        signerDeviceId: roomAlicePhone,
        createdMs: 1700000000000,
        operation: operation,
      );

      final decoded = decodeRoomControlProjection(
        encodeRoomControlProjection(event),
      );

      expect(decoded.operation.kind, operation.kind);
      expect(
        encodeRoomControlProjection(decoded),
        encodeRoomControlProjection(event),
      );
      if (decoded.operation case CreateRoomOperation(:final memberUserIds)) {
        // In the order the native core requires, whatever order was given.
        expect(memberUserIds, [roomAlice, roomBob, roomCarol]);
      }
    }
    final reserved = Uint8List.fromList(
      encodeRoomControlProjection(
        RoomControlEvent(
          eventId: '0f' * 16,
          roomId: _roomId,
          revision: 2,
          previousControlStateHash: _previous,
          signerUserId: roomAlice,
          signerDeviceId: roomAlicePhone,
          createdMs: 1700000000000,
          operation: RemoveRoomMemberOperation(roomBob),
        ),
      ),
    );
    reserved[1 + 16 + 32 + 4 + 1 + 32 + 16 + 16 + 8] =
        RoomControlKind.reservedWireValue;
    expect(() => decodeRoomControlProjection(reserved), throwsFormatException);
  });
}

NativeRoomControlCrypto _adapter(_Core core) => NativeRoomControlCrypto(
  crypto: core,
  store: _Store(),
  localDeviceId: roomAlicePhone,
  clock: const _Clock(),
);

RoomControlEvent _rename({String signerDevice = roomAlicePhone}) =>
    RoomControlEvent(
      eventId: '0e' * 16,
      roomId: _roomId,
      revision: 2,
      previousControlStateHash: _previous,
      signerUserId: roomAlice,
      signerDeviceId: signerDevice,
      createdMs: 1700000000000,
      operation: const RenameRoomOperation('Renamed'),
    );

RoomSignedControlBytes _control() => RoomSignedControlBytes(
  signerUserId: roomAlice,
  signerDeviceId: roomAlicePhone,
  canonicalBytes: Uint8List.fromList(const [0xaa, 0xbb]),
  signature: Uint8List.fromList(List<int>.filled(64, 0x11)),
);

Result<PairwiseCryptoResponse> _ok(
  PairwiseCryptoOperation operation,
  List<int> body,
) => Result.success(
  PairwiseCryptoResponse(
    operation: operation,
    outcome: PairwiseCryptoOutcome.ok,
    body: Uint8List.fromList(body),
  ),
);

List<int> _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

List<int> _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value);

List<int> _frame(List<int> value) => [..._u32(value.length), ...value];

final class _Core implements PairwiseCryptoPort {
  _Core(this.answer);

  final Result<PairwiseCryptoResponse> Function(
    PairwiseCryptoOperation operation,
    Uint8List payload,
  )
  answer;
  final calls = <(PairwiseCryptoOperation, Uint8List)>[];

  @override
  Future<Result<PairwiseCryptoResponse>> pairwiseOperation({
    required PairwiseCryptoOperation operation,
    required Uint8List payload,
  }) async {
    calls.add((operation, Uint8List.fromList(payload)));
    return answer(operation, payload);
  }
}

final class _Store implements PairwiseTransportStore {
  @override
  Future<Result<PairwiseInboundPreparationContext>> readInboundContext({
    required String localDeviceId,
    Uint8List? sessionId,
  }) async => Result.success(
    PairwiseInboundPreparationContext(
      session: null,
      deviceState: PairwiseDeviceStateSnapshot(
        opaqueState: Uint8List.fromList(const [5, 5, 5]),
        stateVersion: 3,
      ),
      otherSessionsSkippedKeyCount: 0,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 30, 18);
}
