import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

const _local = '10000000-0000-4000-8000-000000000001';
const _localDevice = '20000000-0000-4000-8000-000000000001';
const _alice = '30000000-0000-4000-8000-000000000001';
const _bob = '40000000-0000-4000-8000-000000000001';

/// Every group change is one control event this device signs, committed with
/// the roster it leads to and the exact bytes it owes other devices. Nothing
/// here touches the network, and nothing here asks the server about a group.
void main() {
  late _Repository repository;
  late _Crypto crypto;
  late _Identity identity;

  CreateGroup createGroup() => CreateGroup(
    repository: repository,
    crypto: crypto,
    identity: identity,
    clock: const _Clock(),
  );

  Future<GroupState> create(List<String> members) async {
    final result = await createGroup()(
      currentUserId: _local,
      currentDeviceId: _localDevice,
      ownerDisplayName: 'Me',
      metadata: const GroupMetadata(name: '  Planning  '),
      selectedMembers: [
        for (final member in members)
          GroupMember(
            userId: member,
            displayName: 'Friend',
            role: GroupRole.member,
          ),
      ],
    );
    return (result as Success<GroupState>).value;
  }

  Future<Result<GroupState>> mutate(
    GroupState group,
    GroupControlOperation operation,
  ) =>
      MutateGroup(
        repository: repository,
        crypto: crypto,
        identity: identity,
        clock: const _Clock(),
      )(
        groupId: group.groupId,
        actorUserId: _local,
        actorDeviceId: _localDevice,
        operation: operation,
      );

  setUp(() {
    repository = _Repository();
    crypto = _Crypto();
    identity = _Identity();
  });

  group('creating a group', () {
    test('signs one create event and owes it to every member', () async {
      final group = await create([_bob, _alice]);

      expect(group.metadata.name, 'Planning');
      expect(group.controlRevision, 1);
      expect(group.lifecycle, GroupLifecycle.active);
      expect(group.member(_local)?.role, GroupRole.owner);
      expect(group.activeMembers.map((member) => member.userId), [
        _local,
        _alice,
        _bob,
      ]);
      final event = crypto.sealed.single;
      expect(event.revision, 1);
      expect(event.previousControlStateHash, isNull);
      expect(event.signerUserId, _local);
      expect(event.signerDeviceId, _localDevice);
      final operation = event.operation as CreateGroupOperation;
      expect(operation.invitationPolicy, GroupInvitationPolicy.ownerAndAdmins);
      expect(
        operation.historySharingPolicy,
        GroupHistorySharingPolicy.newMessagesOnly,
      );
      final commit = repository.commits.single;
      expect(commit.expectedPrevious, isNull);
      expect(commit.next, same(group));
      final signed = commit.prepared.controls.single;
      expect(signed.event, same(event));
      final work = commit.prepared.outbound.single;
      expect(work.operationId, 'group-control:${event.eventId}');
      expect(work.recipientUserIds, [_alice, _bob]);
      expect(work.recipientDeviceId, isNull);
      expect(work.includeOwnDevices, isTrue);
      final delivery =
          GroupSyncPayloadCodec.decode(work.payload) as GroupControlDelivery;
      expect(delivery.control.canonicalBytes, signed.canonicalBytes);
      expect(delivery.control.signature, signed.signature);
    });

    test('needs somebody besides its owner', () async {
      final result = await createGroup()(
        currentUserId: _local,
        currentDeviceId: _localDevice,
        ownerDisplayName: 'Me',
        metadata: const GroupMetadata(name: 'Alone'),
        selectedMembers: const [],
      );

      expect(
        (result as FailureResult<GroupState>).failure,
        const ValidationFailure(ValidationFailureKind.limitExceeded),
      );
      expect(crypto.sealed, isEmpty);
      expect(repository.commits, isEmpty);
    });

    test('whose commit fails reports no group', () async {
      repository.commitFailure = const StorageFailure(
        StorageFailureKind.unavailable,
      );

      final result = await createGroup()(
        currentUserId: _local,
        currentDeviceId: _localDevice,
        ownerDisplayName: 'Me',
        metadata: const GroupMetadata(name: 'Planning'),
        selectedMembers: [
          GroupMember(userId: _alice, displayName: '', role: GroupRole.member),
        ],
      );

      expect(
        (result as FailureResult<GroupState>).failure,
        const StorageFailure(StorageFailureKind.unavailable),
      );
      expect(repository.groups, isEmpty);
    });
  });

  group('changing a group', () {
    test(
      'sends an added member the transcript and everybody else the event',
      () async {
        final group = await create([_alice]);
        final created = repository.commits.single.prepared.controls.single;

        final result = await mutate(
          group,
          AddGroupMembersOperation([
            GroupMember(
              userId: _bob,
              displayName: 'Bob',
              role: GroupRole.member,
            ),
          ]),
        );

        final next = (result as Success<GroupState>).value;
        expect(next.controlRevision, 2);
        expect(next.member(_bob)?.isActive, isTrue);
        final commit = repository.commits.last;
        expect(commit.expectedPrevious, same(group));
        final added = commit.prepared.controls.single;
        expect(added.event.previousControlStateHash, group.controlStateHash);
        final outbound = commit.prepared.outbound;
        expect(outbound.map((work) => work.operationId), [
          'group-control:${added.event.eventId}',
          'group-transcript:${added.event.eventId}:$_bob',
        ]);
        expect(outbound[0].recipientUserIds, [_alice]);
        expect(outbound[0].includeOwnDevices, isTrue);
        expect(outbound[1].recipientUserIds, [_bob]);
        expect(outbound[1].includeOwnDevices, isFalse);
        final transcript =
            GroupSyncPayloadCodec.decode(outbound[1].payload)
                as GroupTranscriptPayload;
        expect(transcript.baseRevision, 0);
        expect(transcript.entries.map((entry) => entry.canonicalBytes), [
          created.canonicalBytes,
          added.canonicalBytes,
        ]);
      },
    );

    test('tells a removed member it was removed', () async {
      final group = await create([_alice, _bob]);

      final result = await mutate(group, RemoveGroupMemberOperation(_alice));

      expect(
        (result as Success<GroupState>).value.member(_alice)?.membership,
        GroupMembershipState.removed,
      );
      expect(
        repository.commits.last.prepared.outbound.single.recipientUserIds,
        [_alice, _bob],
      );
    });

    test('is refused while a member has not confirmed the state', () async {
      final group = await create([_alice]);
      repository.overlay = GroupLifecycle.stateRecoveryRequired;

      final result = await mutate(
        group,
        const RenameGroupOperation(GroupMetadata(name: 'Later')),
      );

      expect(
        (result as FailureResult<GroupState>).failure,
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      );
      expect(crypto.sealed, hasLength(1));
      expect(repository.commits, hasLength(1));
    });

    test('is refused to a member without the permission', () async {
      final group = GroupState(
        groupId: 'ef' * 32,
        metadata: const GroupMetadata(name: 'Theirs'),
        invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
        historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
        members: [
          GroupMember(userId: _alice, displayName: '', role: GroupRole.owner),
          GroupMember(userId: _local, displayName: '', role: GroupRole.member),
        ],
        controlRevision: 1,
        controlStateHash: 'cd' * 32,
      );
      repository.groups[group.groupId] = group;

      final result = await mutate(
        group,
        const RenameGroupOperation(GroupMetadata(name: 'Mine')),
      );

      expect(
        (result as FailureResult<GroupState>).failure,
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      );
      expect(crypto.sealed, isEmpty);
    });

    test('is never committed when the signed bytes say otherwise', () async {
      final group = await create([_alice, _bob]);
      // An owner cannot leave a group other members are still in.
      crypto.substitute = RemoveGroupMemberOperation(_local);

      final result = await mutate(
        group,
        const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
      );

      expect(
        (result as FailureResult<GroupState>).failure,
        const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
      expect(repository.commits, hasLength(1));
    });

    test(
      'refuses an add whose transcript would not fit one envelope',
      () async {
        final group = await create([_alice]);
        String hash(int revision) =>
            revision.toRadixString(16).padLeft(2, '0') * 32;
        repository.transcripts[group.groupId] = [
          for (var revision = 1; revision <= 13; revision += 1)
            StoredGroupControl(
              eventId: revision.toRadixString(16).padLeft(2, '0') * 16,
              revision: revision,
              previousControlStateHash: revision == 1
                  ? null
                  : hash(revision - 1),
              controlStateHash: hash(revision),
              signerUserId: _local,
              signerDeviceId: _localDevice,
              canonicalBytes: Uint8List(
                SignedGroupControlEvent.maximumCanonicalBytes,
              ),
              signature: Uint8List(SignedGroupControlEvent.signatureBytes),
            ),
        ];
        final long = group.copyWith(
          controlRevision: 13,
          controlStateHash: hash(13),
        );
        repository.groups[group.groupId] = long;

        final result = await mutate(
          long,
          AddGroupMembersOperation([
            GroupMember(
              userId: _bob,
              displayName: 'Bob',
              role: GroupRole.member,
            ),
          ]),
        );

        expect(
          (result as FailureResult<GroupState>).failure,
          const ValidationFailure(ValidationFailureKind.limitExceeded),
        );
        expect(repository.commits, hasLength(1));
      },
    );
  });

  group('sending a message', () {
    test('goes to the group from an active member', () async {
      final group = await create([_alice]);
      final sender = _Sender();

      final result =
          await SendGroupMessage(repository: repository, sender: sender)(
            groupId: group.groupId,
            senderUserId: _local,
            senderDeviceId: _localDevice,
            text: '  hello  ',
          );

      expect(result, isA<Success<void>>());
      expect(sender.sent, [(group.groupId, 'hello')]);
    });

    test('is refused while the roster may be stale', () async {
      final group = await create([_alice]);
      repository.overlay = GroupLifecycle.stateRecoveryRequired;
      final sender = _Sender();

      final result =
          await SendGroupMessage(repository: repository, sender: sender)(
            groupId: group.groupId,
            senderUserId: _local,
            senderDeviceId: _localDevice,
            text: 'hello',
          );

      expect(
        (result as FailureResult<void>).failure,
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      );
      expect(sender.sent, isEmpty);
    });
  });
}

typedef _Commit = ({
  GroupState? expectedPrevious,
  GroupState next,
  PreparedGroupTransition prepared,
});

final class _Repository implements GroupRepositoryPort {
  final groups = <String, GroupState>{};
  final transcripts = <String, List<StoredGroupControl>>{};
  final commits = <_Commit>[];
  Failure? commitFailure;
  GroupLifecycle? overlay;

  @override
  Future<Result<GroupState?>> readGroup(String groupId) async {
    final group = groups[groupId];
    final lifecycle = overlay;
    return Result.success(
      group == null || lifecycle == null
          ? group
          : group.copyWith(lifecycle: lifecycle),
    );
  }

  @override
  Future<Result<List<StoredGroupControl>>> readTranscript(
    String groupId, {
    int afterRevision = 0,
  }) async => Result.success([
    for (final entry in transcripts[groupId] ?? const <StoredGroupControl>[])
      if (entry.revision > afterRevision) entry,
  ]);

  @override
  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  }) async {
    final failure = commitFailure;
    if (failure != null) return Result.failure(failure);
    commits.add((
      expectedPrevious: expectedPrevious,
      next: next,
      prepared: prepared,
    ));
    groups[next.groupId] = next;
    (transcripts[next.groupId] ??= []).addAll(
      prepared.controls.map((control) => control.stored),
    );
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Stands in for the native signing call. [substitute] makes it return bytes
/// that say something other than what it was asked to sign.
final class _Crypto implements GroupControlCryptoPort {
  final sealed = <GroupControlEvent>[];
  GroupControlOperation? substitute;

  @override
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event) async {
    sealed.add(event);
    final operation = substitute;
    return Result.success(
      SignedGroupControlEvent(
        event: operation == null
            ? event
            : GroupControlEvent(
                eventId: event.eventId,
                groupId: event.groupId,
                revision: event.revision,
                previousControlStateHash: event.previousControlStateHash,
                signerUserId: event.signerUserId,
                signerDeviceId: event.signerDeviceId,
                createdMs: event.createdMs,
                operation: operation,
              ),
        controlStateHash: event.eventId * 2,
        canonicalBytes: Uint8List.fromList(utf8.encode(event.eventId)),
        signature: Uint8List(SignedGroupControlEvent.signatureBytes),
      ),
    );
  }

  @override
  Future<Result<SignedGroupControlEvent>> open({
    required GroupSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) => throw UnimplementedError();
}

final class _Identity implements GroupIdentityPort {
  var _issued = 0;

  @override
  Future<Result<Uint8List>> randomIdentifier() async {
    _issued += 1;
    return Result.success(
      Uint8List.fromList(
        List<int>.generate(16, (index) => (_issued * 31 + index) & 0xff),
      ),
    );
  }
}

final class _Sender implements GroupMessageSenderPort {
  final sent = <(String, String)>[];

  @override
  Future<Result<void>> sendText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String text,
  }) async {
    sent.add((groupId, text));
    return const Result.success(null);
  }
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 12);
}
