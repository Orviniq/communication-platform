import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:communication_platform/features/groups/infrastructure/native_group_control_crypto.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _user = '10000000-0000-4000-8000-000000000001';
const _device = '20000000-0000-4000-8000-000000000001';
const _other = '30000000-0000-4000-8000-000000000001';
final _groupId = 'ab' * 32;
final _previous = 'cd' * 32;

/// The adapter frames requests for the native core and reads its answers. It
/// signs nothing and verifies nothing itself: the core stand-in here records
/// exactly what it was handed and returns what the test tells it to.
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

      final signed = (result as Success<SignedGroupControlEvent>).value;
      expect(signed.event, same(event));
      expect(signed.canonicalBytes, [0xaa, 0xbb]);
      expect(signed.signature, List<int>.filled(64, 0x11));
      expect(signed.controlStateHash, '22' * 32);
      final (operation, payload) = core.calls.single;
      expect(operation, PairwiseCryptoOperation.sealGroupControl);
      final day =
          DateTime.utc(2026, 9, 13).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay;
      expect(payload, [
        ..._frame(const [5, 5, 5]),
        ..._u32(day),
        ..._frame(encodeGroupControlProjection(event)),
      ]);
    },
  );

  test('a device signs only as itself', () async {
    final core = _Core((operation, payload) => throw StateError('unreached'));

    final result = await _adapter(core).seal(_rename(signerDevice: _other));

    expect(
      (result as FailureResult<SignedGroupControlEvent>).failure,
      const ValidationFailure(ValidationFailureKind.invalidInput),
    );
    expect(core.calls, isEmpty);
  });

  test('opening checks under the given key and decodes the event', () async {
    final event = _rename();
    final core = _Core(
      (operation, payload) => _ok(operation, [
        ..._frame(encodeGroupControlProjection(event)),
        ...List<int>.filled(32, 0x33),
      ]),
    );
    final control = GroupSignedControlBytes(
      signerUserId: _user,
      signerDeviceId: _device,
      canonicalBytes: Uint8List.fromList(const [0xaa, 0xbb]),
      signature: Uint8List.fromList(List<int>.filled(64, 0x11)),
    );

    final result = await _adapter(core).open(
      control: control,
      signerSigningPublic: Uint8List.fromList(List<int>.filled(32, 7)),
    );

    final opened = (result as Success<SignedGroupControlEvent>).value;
    expect(opened.event.eventId, event.eventId);
    expect(opened.event.revision, 2);
    expect(opened.event.previousControlStateHash, _previous);
    expect(
      (opened.event.operation as RenameGroupOperation).metadata.name,
      'Renamed',
    );
    expect(opened.controlStateHash, '33' * 32);
    expect(opened.canonicalBytes, control.canonicalBytes);
    expect(opened.signature, control.signature);
    final (operation, payload) = core.calls.single;
    expect(operation, PairwiseCryptoOperation.openGroupControl);
    expect(payload, [
      ...List<int>.filled(32, 7),
      ..._frame(const [0xaa, 0xbb]),
      ...List<int>.filled(64, 0x11),
    ]);
  });

  test('a signature the core refuses is unauthenticated input', () async {
    final core = _Core(
      (operation, payload) => const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      ),
    );

    final result = await _adapter(
      core,
    ).open(control: _control(), signerSigningPublic: Uint8List(32));

    expect(
      (result as FailureResult<SignedGroupControlEvent>).failure,
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });

  test('an event naming a signer other than its frame is refused', () async {
    final core = _Core(
      (operation, payload) => _ok(operation, [
        ..._frame(encodeGroupControlProjection(_rename(signerDevice: _other))),
        ...List<int>.filled(32, 0x33),
      ]),
    );

    final result = await _adapter(
      core,
    ).open(control: _control(), signerSigningPublic: Uint8List(32));

    expect(
      (result as FailureResult<SignedGroupControlEvent>).failure,
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });

  test('every control kind survives the projection', () {
    final operations = <GroupControlOperation>[
      CreateGroupOperation(
        metadata: const GroupMetadata(name: 'Team', description: 'Planning'),
        invitationPolicy: GroupInvitationPolicy.allMembers,
        historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
        members: [
          GroupMember(
            userId: _user,
            displayName: 'Local name',
            role: GroupRole.owner,
            verified: true,
          ),
          GroupMember(
            userId: _other,
            displayName: 'Other',
            role: GroupRole.member,
          ),
        ],
      ),
      AddGroupMembersOperation([
        GroupMember(
          userId: _other,
          displayName: 'Other',
          role: GroupRole.member,
        ),
      ]),
      RemoveGroupMemberOperation(_other),
      ChangeGroupRoleOperation(targetUserId: _other, role: GroupRole.admin),
      const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    ];
    for (final operation in operations) {
      final first = operation is CreateGroupOperation;
      final event = GroupControlEvent(
        eventId: '0f' * 16,
        groupId: _groupId,
        revision: first ? 1 : 2,
        previousControlStateHash: first ? null : _previous,
        signerUserId: _user,
        signerDeviceId: _device,
        createdMs: 1700000000000,
        operation: operation,
      );

      final decoded = decodeGroupControlProjection(
        encodeGroupControlProjection(event),
      );

      expect(decoded.operation.kind, operation.kind);
      expect(
        encodeGroupControlProjection(decoded),
        encodeGroupControlProjection(event),
      );
      if (decoded.operation case CreateGroupOperation(
        :final members,
        :final metadata,
      )) {
        expect(members.map((member) => member.role), [
          GroupRole.owner,
          GroupRole.member,
        ]);
        // Names and verification are this device's own and are never signed.
        expect(members.every((member) => member.displayName.isEmpty), isTrue);
        expect(members.every((member) => !member.verified), isTrue);
        expect(metadata.description, 'Planning');
      }
      if (decoded.operation case ChangeGroupRoleOperation(:final role)) {
        expect(role, GroupRole.admin);
      }
    }
  });
}

NativeGroupControlCrypto _adapter(_Core core) => NativeGroupControlCrypto(
  crypto: core,
  store: _Store(),
  localDeviceId: _device,
  clock: const _Clock(),
);

GroupControlEvent _rename({String signerDevice = _device}) => GroupControlEvent(
  eventId: '0e' * 16,
  groupId: _groupId,
  revision: 2,
  previousControlStateHash: _previous,
  signerUserId: _user,
  signerDeviceId: signerDevice,
  createdMs: 1700000000000,
  operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
);

GroupSignedControlBytes _control() => GroupSignedControlBytes(
  signerUserId: _user,
  signerDeviceId: _device,
  canonicalBytes: Uint8List.fromList(const [1]),
  signature: Uint8List(SignedGroupControlEvent.signatureBytes),
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
  DateTime now() => DateTime.utc(2026, 9, 13, 18);
}
