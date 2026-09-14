import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_inbound_coordinator.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberDevice = '40000000-0000-4000-8000-000000000001';
const _outsider = '50000000-0000-4000-8000-000000000001';
const _outsiderDevice = '60000000-0000-4000-8000-000000000001';
const _envelope = '70000000-0000-4000-8000-000000000001';
final _groupId = 'ab' * 32;

/// The server checks nothing about a group, so the receiving device checks
/// everything: the signature under the key the device list vouches for, the
/// chain, and the signer's authority. The core's signature check is a stand-in
/// here that accepts exactly the events this suite signed, under exactly the
/// key of the device that signed them.
void main() {
  late _Repository repository;
  late _Crypto crypto;
  late _LiveDevices liveDevices;

  Future<Result<GroupInboundPreparation>> receive(
    GroupSyncPayload payload, {
    String localUserId = _member,
    String senderUserId = _owner,
    String senderDeviceId = _ownerDevice,
  }) =>
      GroupInboundCoordinator(
        repository: repository,
        crypto: crypto,
        liveDevices: liveDevices,
        clock: const _Clock(),
        localUserId: localUserId,
      ).prepare(
        envelopeId: _envelope,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        payload: GroupSyncPayloadCodec.encode(payload),
      );

  SignedGroupControlEvent event(
    int revision,
    SignedGroupControlEvent? previous,
    GroupControlOperation operation, {
    int branch = 0,
  }) => crypto.sign(
    revision: revision,
    previous: previous,
    operation: operation,
    branch: branch,
  );

  setUp(() {
    repository = _Repository();
    crypto = _Crypto();
    liveDevices = _LiveDevices({
      _owner: [_live(_owner, _ownerDevice)],
      _member: [_live(_member, _memberDevice)],
      _outsider: [_live(_outsider, _outsiderDevice)],
    });
  });

  group('a control event', () {
    test('relayed by a device other than its signer is refused', () async {
      final create = event(1, null, _create());

      final result = await receive(
        _delivery(create),
        senderUserId: _outsider,
        senderDeviceId: _outsiderDevice,
      );

      expect(
        (result as FailureResult<GroupInboundPreparation>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
      expect(crypto.opened, 0);
    });

    test('whose signature does not verify is refused', () async {
      final create = event(1, null, _create());
      final forged = GroupSignedControlBytes(
        signerUserId: _owner,
        signerDeviceId: _ownerDevice,
        canonicalBytes: create.canonicalBytes,
        signature: Uint8List(SignedGroupControlEvent.signatureBytes),
      );

      final result = await receive(GroupControlDelivery(forged));

      expect(
        (result as FailureResult<GroupInboundPreparation>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    });

    test('from a device its account no longer lists is refused', () async {
      final create = event(1, null, _create());
      liveDevices.devices[_owner] = [];

      final result = await receive(_delivery(create));

      expect(
        (result as FailureResult<GroupInboundPreparation>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
      expect(crypto.opened, 0);
    });

    test('that extends the held chain commits as one transition', () async {
      final create = event(1, null, _create());
      repository.hold([create], localUserId: _member);
      final held = repository.groups[_groupId];
      final rename = event(2, create, _rename('Renamed'));

      final result = await receive(_delivery(rename));

      final commit = _commit<PreparedGroupInboxTransition>(result);
      expect(commit.opaqueEventId, 'group-control:${rename.event.eventId}');
      expect(commit.senderUserId, _owner);
      expect(commit.senderDeviceId, _ownerDevice);
      expect(commit.expectedPrevious, same(held));
      expect(commit.next.metadata.name, 'Renamed');
      expect(commit.next.controlRevision, 2);
      expect(commit.prepared.controls.single, same(rename));
      expect(commit.prepared.completesStateRequest, isFalse);
    });

    test('beyond the held chain asks its sender for what came first', () async {
      final create = event(1, null, _create());
      repository.hold([create], localUserId: _member);
      final rename = event(2, create, _rename('Renamed'));
      final again = event(3, rename, _rename('Again'));

      final result = await receive(_delivery(again));

      final commit = _commit<PreparedGroupInboxStateRequest>(result);
      expect(commit.groupId, _groupId);
      expect(commit.peerUserId, _owner);
    });

    test('for a group this device is not in changes nothing', () async {
      final create = event(1, null, _create(members: [_owner, _outsider]));

      final result = await receive(_delivery(create));

      expect(
        (result as Success<GroupInboundPreparation>).value,
        isA<GroupInboundNoChange>(),
      );
    });

    test('this device already passed is a duplicate or a fork', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      repository.hold([create, rename], localUserId: _member);

      final duplicate = await receive(_delivery(create));

      expect(
        (duplicate as Success<GroupInboundPreparation>).value,
        isA<GroupInboundNoChange>(),
      );

      final sibling = event(2, create, _rename('Elsewhere'), branch: 1);

      final forked = await receive(_delivery(sibling));

      final commit = _commit<PreparedGroupInboxQuarantine>(forked);
      expect(commit.record.reason, GroupQuarantineReason.siblingControl);
      expect(commit.retainLifecycle, isFalse);
    });

    test('its signer was not allowed to make is dropped, not forked', () async {
      final create = event(1, null, _create());
      repository.hold([create], localUserId: _owner);
      // Signed by a real member device, but a member may not rename.
      final rename = crypto.sign(
        revision: 2,
        previous: create,
        operation: _rename('Mine'),
        signerUserId: _member,
        signerDeviceId: _memberDevice,
      );

      final result = await receive(
        _delivery(rename),
        localUserId: _owner,
        senderUserId: _member,
        senderDeviceId: _memberDevice,
      );

      final commit = _commit<PreparedGroupInboxQuarantine>(result);
      expect(commit.record.reason, GroupQuarantineReason.unauthorizedControl);
      expect(commit.retainLifecycle, isTrue);
    });
  });

  group('a state request', () {
    test('from a member is answered on the device that asked', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      final again = event(3, rename, _rename('Again'));
      repository.hold([create, rename, again], localUserId: _owner);

      final result = await receive(
        GroupStateRequestPayload(
          groupId: _groupId,
          haveRevision: 1,
          haveStateHash: create.controlStateHash,
        ),
        localUserId: _owner,
        senderUserId: _member,
        senderDeviceId: _memberDevice,
      );

      final commit = _commit<PreparedGroupInboxOutbound>(result);
      expect(commit.opaqueEventId, 'group-state-request:$_envelope');
      expect(commit.work.operationId, 'group-state-response:$_envelope');
      expect(commit.work.recipientUserIds, [_member]);
      expect(commit.work.recipientDeviceId, _memberDevice);
      expect(commit.work.includeOwnDevices, isFalse);
      final transcript =
          GroupSyncPayloadCodec.decode(commit.work.payload)
              as GroupTranscriptPayload;
      expect(transcript.baseRevision, 1);
      expect(transcript.baseStateHash, create.controlStateHash);
      expect(transcript.entries.map((entry) => entry.signature), [
        rename.signature,
        again.signature,
      ]);
    });

    test('from a member on another branch is sent everything', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      repository.hold([create, rename], localUserId: _owner);

      final result = await receive(
        GroupStateRequestPayload(
          groupId: _groupId,
          haveRevision: 2,
          haveStateHash: 'ee' * 32,
        ),
        localUserId: _owner,
        senderUserId: _member,
        senderDeviceId: _memberDevice,
      );

      final commit = _commit<PreparedGroupInboxOutbound>(result);
      final transcript =
          GroupSyncPayloadCodec.decode(commit.work.payload)
              as GroupTranscriptPayload;
      expect(transcript.baseRevision, 0);
      expect(transcript.baseStateHash, isNull);
      expect(transcript.entries, hasLength(2));
    });

    test('from somebody outside the group learns nothing', () async {
      final create = event(1, null, _create());
      repository.hold([create], localUserId: _owner);

      final result = await receive(
        GroupStateRequestPayload(
          groupId: _groupId,
          haveRevision: 0,
          haveStateHash: null,
        ),
        localUserId: _owner,
        senderUserId: _outsider,
        senderDeviceId: _outsiderDevice,
      );

      expect(
        (result as Success<GroupInboundPreparation>).value,
        isA<GroupInboundNoChange>(),
      );
    });
  });

  group('a transcript', () {
    test('replays a group this device was added to', () async {
      final create = event(1, null, _create(members: [_owner, _outsider]));
      final add = event(
        2,
        create,
        AddGroupMembersOperation([
          GroupMember(userId: _member, displayName: '', role: GroupRole.member),
        ]),
      );

      final result = await receive(_transcript([create, add]));

      final commit = _commit<PreparedGroupInboxTransition>(result);
      expect(commit.opaqueEventId, 'group-transcript:$_envelope');
      expect(commit.expectedPrevious, isNull);
      expect(commit.next.lifecycle, GroupLifecycle.active);
      expect(commit.next.member(_member)?.isActive, isTrue);
      expect(commit.prepared.controls, [create, add]);
      expect(commit.prepared.completesStateRequest, isTrue);
    });

    test('applies what follows the held state as one transition', () async {
      final create = event(1, null, _create());
      repository.hold([create], localUserId: _member);
      final held = repository.groups[_groupId];
      final rename = event(2, create, _rename('Renamed'));
      final again = event(3, rename, _rename('Again'));

      final result = await receive(_transcript([rename, again], after: create));

      final commit = _commit<PreparedGroupInboxTransition>(result);
      expect(commit.expectedPrevious, same(held));
      expect(commit.next.controlRevision, 3);
      expect(commit.next.metadata.name, 'Again');
      expect(commit.prepared.controls, [rename, again]);
      expect(commit.prepared.completesStateRequest, isTrue);
    });

    test('with nothing after the held state confirms it', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      repository.hold([create, rename], localUserId: _member);

      final result = await receive(_transcript(const [], after: rename));

      final commit = _commit<PreparedGroupInboxStateCurrent>(result);
      expect(commit.groupId, _groupId);
      expect(commit.controlRevision, 2);
      expect(commit.controlStateHash, rename.controlStateHash);
    });

    test('that contradicts the held chain quarantines the group', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      repository.hold([create, rename], localUserId: _member);
      final sibling = event(2, create, _rename('Elsewhere'), branch: 1);

      final result = await receive(_transcript([create, sibling]));

      final commit = _commit<PreparedGroupInboxQuarantine>(result);
      expect(commit.record.reason, GroupQuarantineReason.siblingControl);
      expect(commit.retainLifecycle, isFalse);
      expect(commit.completesStateRequest, isTrue);
    });

    test('whose entries do not chain is refused', () async {
      final create = event(1, null, _create());
      final rename = event(2, create, _rename('Renamed'));
      final again = event(3, rename, _rename('Again'));

      final result = await receive(_transcript([create, again]));

      expect(
        (result as FailureResult<GroupInboundPreparation>).failure,
        const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    });
  });

  test('bytes that are not one group payload are refused', () async {
    final result =
        await GroupInboundCoordinator(
          repository: repository,
          crypto: crypto,
          liveDevices: liveDevices,
          clock: const _Clock(),
          localUserId: _member,
        ).prepare(
          envelopeId: _envelope,
          senderUserId: _owner,
          senderDeviceId: _ownerDevice,
          payload: Uint8List.fromList(GroupSyncProtocolV1.magic),
        );

    expect(
      (result as FailureResult<GroupInboundPreparation>).failure,
      const SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  });
}

T _commit<T extends PreparedGroupInboxCommit>(
  Result<GroupInboundPreparation> result,
) =>
    ((result as Success<GroupInboundPreparation>).value as GroupInboundChange)
            .commit
        as T;

CreateGroupOperation _create({
  List<String> members = const [_owner, _member],
}) => CreateGroupOperation(
  metadata: const GroupMetadata(name: 'Inbound'),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: [
    for (final member in members)
      GroupMember(
        userId: member,
        displayName: '',
        role: member == _owner ? GroupRole.owner : GroupRole.member,
      ),
  ],
);

RenameGroupOperation _rename(String name) =>
    RenameGroupOperation(GroupMetadata(name: name));

GroupControlDelivery _delivery(SignedGroupControlEvent signed) =>
    GroupControlDelivery(GroupSignedControlBytes.fromSigned(signed));

GroupTranscriptPayload _transcript(
  List<SignedGroupControlEvent> entries, {
  SignedGroupControlEvent? after,
}) => GroupTranscriptPayload(
  groupId: _groupId,
  baseRevision: after?.event.revision ?? 0,
  baseStateHash: after?.controlStateHash,
  entries: entries.map(GroupSignedControlBytes.fromSigned),
);

GroupAuthenticatedLiveDevice _live(String userId, String deviceId) =>
    GroupAuthenticatedLiveDevice(
      userId: userId,
      deviceId: deviceId,
      signingPublic: _signingKey(deviceId),
    );

Uint8List _signingKey(String deviceId) =>
    Uint8List.fromList(List<int>.filled(32, deviceId.codeUnitAt(0)));

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _Repository implements GroupRepositoryPort {
  final groups = <String, GroupState>{};
  final transcripts = <String, List<StoredGroupControl>>{};

  void hold(
    List<SignedGroupControlEvent> chain, {
    required String localUserId,
  }) {
    GroupState? state;
    for (final signed in chain) {
      state =
          (const GroupControlStateMachine().apply(
                    previous: state,
                    signedControl: signed,
                    localUserId: localUserId,
                  )
                  as GroupControlAccepted)
              .state;
    }
    groups[_groupId] = state!;
    transcripts[_groupId] = [for (final signed in chain) signed.stored];
  }

  @override
  Future<Result<GroupState?>> readStoredGroup(String groupId) async =>
      Result.success(groups[groupId]);

  @override
  Future<Result<List<StoredGroupControl>>> readTranscript(
    String groupId, {
    int afterRevision = 0,
  }) async => Result.success([
    for (final entry in transcripts[groupId] ?? const <StoredGroupControl>[])
      if (entry.revision > afterRevision) entry,
  ]);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Accepts exactly the events [sign] made, under the key of the device that
/// signed each one.
final class _Crypto implements GroupControlCryptoPort {
  final _events = <String, SignedGroupControlEvent>{};
  var opened = 0;

  SignedGroupControlEvent sign({
    required int revision,
    required SignedGroupControlEvent? previous,
    required GroupControlOperation operation,
    int branch = 0,
    String signerUserId = _owner,
    String signerDeviceId = _ownerDevice,
  }) {
    final marker = ((branch << 4) | revision).toRadixString(16).padLeft(2, '0');
    final signed = SignedGroupControlEvent(
      event: GroupControlEvent(
        eventId: marker * 16,
        groupId: _groupId,
        revision: revision,
        previousControlStateHash: previous?.controlStateHash,
        signerUserId: signerUserId,
        signerDeviceId: signerDeviceId,
        createdMs: 1700000000000 + revision,
        operation: operation,
      ),
      controlStateHash: marker * 32,
      canonicalBytes: Uint8List.fromList(utf8.encode('control $marker')),
      signature: Uint8List.fromList(
        List<int>.filled(64, (branch << 4) | revision),
      ),
    );
    _events['control $marker'] = signed;
    return signed;
  }

  @override
  Future<Result<SignedGroupControlEvent>> open({
    required GroupSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) async {
    opened += 1;
    final signed = _events[utf8.decode(control.canonicalBytes)];
    if (signed == null ||
        signed.event.signerDeviceId != control.signerDeviceId ||
        !_sameBytes(signed.signature, control.signature) ||
        !_sameBytes(signerSigningPublic, _signingKey(control.signerDeviceId))) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(signed);
  }

  @override
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event) =>
      throw UnimplementedError();
}

final class _LiveDevices implements GroupLiveDeviceResolverPort {
  _LiveDevices(this.devices);

  final Map<String, List<GroupAuthenticatedLiveDevice>> devices;

  @override
  Future<Result<List<GroupAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId) async =>
      Result.success(devices[userId] ?? const []);
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 12);
}
