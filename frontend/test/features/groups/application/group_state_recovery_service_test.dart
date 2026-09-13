import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_state_recovery_service.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

const _local = '10000000-0000-4000-8000-000000000001';
const _localDevice = '20000000-0000-4000-8000-000000000001';
const _owner = '30000000-0000-4000-8000-000000000001';
const _admin = '40000000-0000-4000-8000-000000000001';
const _member = '50000000-0000-4000-8000-000000000001';
final _groupId = 'ab' * 32;
final _hash = 'cd' * 32;
final _now = DateTime.utc(2026, 9, 13, 12);

/// `backend/CLIENT_CONTRACT.md` §H: after a lost envelope, repair the pairwise
/// session through its authenticated path, then ask a member for the group's
/// control state. Never ask to be removed and added back.
void main() {
  late List<String> log;
  late _Repository repository;
  late _Repair repair;
  late GroupStateRecoveryService service;

  setUp(() {
    log = [];
    repository = _Repository(log);
    repair = _Repair(log);
    service = GroupStateRecoveryService(
      repository: repository,
      repair: repair,
      clock: const _Clock(),
      currentUserId: _local,
      currentDeviceId: _localDevice,
    );
  });

  test(
    'a gap repairs the session with the owner, then asks the owner',
    () async {
      repository.groups[_groupId] = _group();
      repository.due.add(_request(GroupStateRequestReason.queueGap));

      final result = await service.requestDueStates();

      expect((result as Success<int>).value, 1);
      expect(log, ['repair $_owner', 'request $_owner']);
      expect(repair.calls, [(_localDevice, _owner)]);
      expect(repository.retryBefore, _now.subtract(const Duration(hours: 6)));
      final sent = repository.sent.single;
      expect(sent.requestedAt, _now);
      expect(
        sent.work.operationId,
        'group-state-request:$_groupId:${_now.millisecondsSinceEpoch}',
      );
      expect(sent.work.recipientUserIds, [_owner]);
      expect(sent.work.recipientDeviceId, isNull);
      expect(sent.work.includeOwnDevices, isFalse);
      final payload =
          GroupSyncPayloadCodec.decode(sent.work.payload)
              as GroupStateRequestPayload;
      expect(payload.groupId, _groupId);
      expect(payload.haveRevision, 4);
      expect(payload.haveStateHash, _hash);
      expect(repository.retired, isEmpty);
    },
  );

  test('an unanswered gap request goes to the next member in line', () async {
    repository.groups[_groupId] = _group();

    // Owner, then admins, then members, each in user-id order.
    for (final (attempts, expected) in [
      (1, _admin),
      (2, _member),
      (3, _owner),
    ]) {
      repository.due
        ..clear()
        ..add(_request(GroupStateRequestReason.queueGap, attempts: attempts));
      repository.sent.clear();

      await service.requestDueStates();

      expect(repository.sent.single.peerUserId, expected);
    }
  });

  test('a gap no member can answer is retired, not sent', () async {
    // Nobody else is active, or this device no longer follows the group.
    for (final group in [
      _group(othersActive: false),
      _group(localMembership: GroupMembershipState.removed),
    ]) {
      repository.groups[_groupId] = group;
      repository.due
        ..clear()
        ..add(_request(GroupStateRequestReason.queueGap));
      repository.retired.clear();

      final result = await service.requestDueStates();

      expect((result as Success<int>).value, 0);
      expect(repository.retired, [_groupId]);
      expect(repository.sent, isEmpty);
      expect(repair.calls, isEmpty);
    }
  });

  test(
    'an event this device was behind on asks its sender, and is given up',
    () async {
      repository.groups[_groupId] = _group();
      repository.due.add(
        _request(GroupStateRequestReason.behind, peerUserId: _member),
      );

      await service.requestDueStates();

      expect(repository.sent.single.peerUserId, _member);
      expect(repair.calls, isEmpty);

      repository.sent.clear();
      repository.due
        ..clear()
        ..add(
          _request(
            GroupStateRequestReason.behind,
            peerUserId: _member,
            attempts: 3,
          ),
        );

      await service.requestDueStates();

      expect(repository.sent, isEmpty);
      expect(repository.retired, [_groupId]);
    },
  );

  test(
    'a group this device does not hold is asked for from the start',
    () async {
      repository.due.add(
        _request(GroupStateRequestReason.behind, peerUserId: _member),
      );

      await service.requestDueStates();

      final payload =
          GroupSyncPayloadCodec.decode(repository.sent.single.work.payload)
              as GroupStateRequestPayload;
      expect(payload.haveRevision, 0);
      expect(payload.haveStateHash, isNull);
    },
  );

  test('a repair that cannot start still sends the request', () async {
    repository.groups[_groupId] = _group();
    repository.due.add(_request(GroupStateRequestReason.queueGap));
    repair.result = const Result.failure(
      TransportFailure(TransportFailureKind.timeout),
    );

    final result = await service.requestDueStates();

    expect(
      (result as FailureResult<int>).failure,
      const TransportFailure(TransportFailureKind.timeout),
    );
    expect(repository.sent.single.peerUserId, _owner);
  });
}

GroupState _group({
  bool othersActive = true,
  GroupMembershipState localMembership = GroupMembershipState.active,
}) => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Recovery'),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: othersActive
      ? [
          GroupMember(
            userId: _local,
            displayName: '',
            role: GroupRole.member,
            membership: localMembership,
          ),
          GroupMember(userId: _owner, displayName: '', role: GroupRole.owner),
          GroupMember(userId: _admin, displayName: '', role: GroupRole.admin),
          GroupMember(userId: _member, displayName: '', role: GroupRole.member),
        ]
      : [
          GroupMember(userId: _local, displayName: '', role: GroupRole.owner),
          GroupMember(
            userId: _owner,
            displayName: '',
            role: GroupRole.member,
            membership: GroupMembershipState.removed,
          ),
        ],
  controlRevision: 4,
  controlStateHash: _hash,
  lifecycle: localMembership == GroupMembershipState.removed
      ? GroupLifecycle.removed
      : GroupLifecycle.active,
);

GroupStateRequest _request(
  GroupStateRequestReason reason, {
  String? peerUserId,
  int attempts = 0,
}) => GroupStateRequest(
  groupId: _groupId,
  reason: reason,
  peerUserId: peerUserId,
  attempts: attempts,
  requestedAt: null,
);

typedef _Sent = ({
  String peerUserId,
  GroupOutboundWork work,
  DateTime requestedAt,
});

final class _Repository implements GroupRepositoryPort {
  _Repository(this.log);

  final List<String> log;
  final groups = <String, GroupState>{};
  final due = <GroupStateRequest>[];
  final sent = <_Sent>[];
  final retired = <String>[];
  DateTime? retryBefore;

  @override
  Future<Result<List<GroupStateRequest>>> readDueStateRequests({
    required DateTime retryBefore,
    int limit = 8,
  }) async {
    this.retryBefore = retryBefore;
    return Result.success(List.of(due));
  }

  @override
  Future<Result<GroupState?>> readStoredGroup(String groupId) async =>
      Result.success(groups[groupId]);

  @override
  Future<Result<void>> recordStateRequestSent({
    required String groupId,
    required String peerUserId,
    required GroupOutboundWork work,
    required DateTime requestedAt,
  }) async {
    log.add('request $peerUserId');
    sent.add((peerUserId: peerUserId, work: work, requestedAt: requestedAt));
    return const Result.success(null);
  }

  @override
  Future<Result<void>> retireStateRequest(String groupId) async {
    retired.add(groupId);
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Repair implements GroupSessionRepairPort {
  _Repair(this.log);

  final List<String> log;
  final calls = <(String, String)>[];
  Result<int> result = const Result.success(1);

  @override
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  }) async {
    log.add('repair $remoteUserId');
    calls.add((localDeviceId, remoteUserId));
    return result;
  }
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => _now;
}
