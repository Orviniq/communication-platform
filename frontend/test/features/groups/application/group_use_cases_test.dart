import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '00000000-0000-0000-0000-000000000001';
const _member = '00000000-0000-0000-0000-000000000002';
const _device = '10000000-0000-0000-0000-000000000001';

void main() {
  test('persistence failure exposes no prepared group state', () async {
    final repository = _MemoryGroupRepository()..failCommits = true;
    final useCase = CreateGroup(
      repository: repository,
      crypto: DevelopmentInMemoryGroupMls.forTests(seed: 10),
      clock: const _Clock(),
      developmentPreviewOnly: true,
    );

    final result = await useCase(
      currentUserId: _owner,
      currentDeviceId: _device,
      ownerDisplayName: 'Owner',
      metadata: const GroupMetadata(name: 'Team'),
      selectedMembers: [
        GroupMember(
          userId: _member,
          displayName: 'Member',
          role: GroupRole.member,
        ),
      ],
    );

    expect(result, isA<FailureResult<GroupState>>());
    expect(
      (result as FailureResult<GroupState>).failure,
      isA<StorageFailure>(),
    );
    expect(repository.state, isNull);
    expect(repository.opaqueState, isNull);
  });

  test(
    'stale concurrent mutation fails without replacing accepted state',
    () async {
      final repository = _MemoryGroupRepository();
      final crypto = DevelopmentInMemoryGroupMls.forTests(seed: 20);
      final create = CreateGroup(
        repository: repository,
        crypto: crypto,
        clock: const _Clock(),
        developmentPreviewOnly: true,
      );
      final created = await create(
        currentUserId: _owner,
        currentDeviceId: _device,
        ownerDisplayName: 'Owner',
        metadata: const GroupMetadata(name: 'Team'),
        selectedMembers: [
          GroupMember(
            userId: _member,
            displayName: 'Member',
            role: GroupRole.member,
          ),
        ],
      );
      final original = (created as Success<GroupState>).value;
      final first = await crypto.prepareControl(
        current: original,
        currentOpaqueMlsState: repository.opaqueState!,
        operation: const UpdateGroupMetadataOperation(
          GroupMetadata(name: 'First'),
        ),
        actorUserId: _owner,
        actorDeviceId: _device,
        createdMs: 101,
      );
      final second = await crypto.prepareControl(
        current: original,
        currentOpaqueMlsState: repository.opaqueState!,
        operation: const UpdateGroupMetadataOperation(
          GroupMetadata(name: 'Second'),
        ),
        actorUserId: _owner,
        actorDeviceId: _device,
        createdMs: 102,
      );
      final firstPrepared = (first as Success<PreparedGroupTransition>).value;
      final secondPrepared = (second as Success<PreparedGroupTransition>).value;
      const machine = GroupControlStateMachine();
      final firstState =
          (machine.apply(
                    previous: original,
                    signedControl: firstPrepared.signedControl,
                    localUserId: _owner,
                  )
                  as GroupControlAccepted)
              .state;
      final firstCommit = await repository.commitTransition(
        expectedPrevious: original,
        next: firstState,
        prepared: firstPrepared,
        developmentPreviewOnly: true,
      );
      expect(firstCommit, isA<Success<void>>());

      final secondState =
          (machine.apply(
                    previous: original,
                    signedControl: secondPrepared.signedControl,
                    localUserId: _owner,
                  )
                  as GroupControlAccepted)
              .state;
      final stale = await repository.commitTransition(
        expectedPrevious: original,
        next: secondState,
        prepared: secondPrepared,
        developmentPreviewOnly: true,
      );
      expect(stale, isA<FailureResult<void>>());
      expect(repository.state!.metadata.name, 'First');
    },
  );

  test(
    'malformed incoming control is quarantined and blocks mutations',
    () async {
      final repository = _MemoryGroupRepository();
      final preview = DevelopmentInMemoryGroupMls.forTests(seed: 30);
      final create = CreateGroup(
        repository: repository,
        crypto: preview,
        clock: const _Clock(),
        developmentPreviewOnly: true,
      );
      final created = await create(
        currentUserId: _owner,
        currentDeviceId: _device,
        ownerDisplayName: 'Owner',
        metadata: const GroupMetadata(name: 'Team'),
        selectedMembers: [
          GroupMember(
            userId: _member,
            displayName: 'Member',
            role: GroupRole.member,
          ),
        ],
      );
      final state = (created as Success<GroupState>).value;
      final apply = ApplyIncomingGroupControl(
        repository: repository,
        crypto: _IncomingFailureCrypto(preview),
        clock: const _Clock(),
        localUserId: _owner,
        localDeviceId: _device,
      );

      final result = await apply(
        groupId: state.groupId,
        mlsObject: Uint8List.fromList([1, 2, 3]),
        opaqueDigest: Uint8List(32),
      );

      expect(result, isA<Success<GroupControlApplyResult>>());
      expect(repository.quarantines, hasLength(1));
      expect(repository.state!.lifecycle, GroupLifecycle.controlQuarantined);
      expect(GroupAuthorization.permissionsFor(repository.state!, _owner), {
        GroupPermission.viewHistory,
      });
    },
  );
}

final class _MemoryGroupRepository implements GroupRepositoryPort {
  GroupState? state;
  Uint8List? opaqueState;
  bool failCommits = false;
  final quarantines = <GroupQuarantineRecord>[];
  final messages = <GroupMessage>[];

  @override
  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
    required bool developmentPreviewOnly,
  }) async {
    if (failCommits) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    if ((expectedPrevious == null && state != null) ||
        (expectedPrevious != null &&
            (state?.controlRevision != expectedPrevious.controlRevision ||
                state?.controlStateHash !=
                    expectedPrevious.controlStateHash))) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    state = next;
    opaqueState = Uint8List.fromList(prepared.newOpaqueMlsState);
    return const Result.success(null);
  }

  @override
  Future<Result<void>> commitMessage({
    required GroupState expectedGroup,
    required PreparedGroupMessage prepared,
    required bool developmentPreviewOnly,
  }) async {
    messages.add(
      GroupMessage(
        messageId: prepared.messageId,
        groupId: prepared.groupId,
        senderUserId: prepared.senderUserId,
        text: prepared.text,
        createdMs: prepared.createdMs,
        localPreviewOnly: developmentPreviewOnly,
      ),
    );
    opaqueState = Uint8List.fromList(prepared.newOpaqueMlsState);
    return const Result.success(null);
  }

  @override
  Future<Result<GroupState?>> readGroup(String groupId) async =>
      Result.success(state);

  @override
  Future<Result<Uint8List?>> readOpaqueMlsState(String groupId) async =>
      Result.success(opaqueState);

  @override
  Future<Result<void>> quarantine(GroupQuarantineRecord record) async {
    quarantines.add(record);
    state = state!.copyWith(
      lifecycle: GroupLifecycle.controlQuarantined,
      quarantineReason: record.reason,
    );
    return const Result.success(null);
  }

  @override
  Future<Result<List<GroupState>>> readGroupsPendingEviction({
    int limit = 20,
  }) async => const Result.success([]);

  @override
  Future<Result<List<GroupOutboundWork>>> readPendingOutbound({
    int limit = 20,
  }) async => const Result.success([]);

  @override
  Future<Result<void>> markOutboundRouted({
    required String operationId,
  }) async => const Result.success(null);

  @override
  Stream<GroupState?> watchGroup(String groupId) => Stream.value(state);

  @override
  Stream<List<GroupMessage>> watchMessages(String groupId) =>
      Stream.value(List.unmodifiable(messages));
}

final class _IncomingFailureCrypto implements GroupMlsCryptoPort {
  const _IncomingFailureCrypto(this.delegate);
  final GroupMlsCryptoPort delegate;

  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) => delegate.probeIncomingTransport(mlsObject);

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => delegate.inspectIncomingWelcome(
    mlsObject: mlsObject,
    localUserId: localUserId,
    localDeviceId: localDeviceId,
  );

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    SecurityFailure(SecurityFailureKind.malformedServerResponse),
  );

  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => delegate.inspectIncomingApplication(
    current: current,
    currentOpaqueMlsState: currentOpaqueMlsState,
    mlsObject: mlsObject,
    localUserId: localUserId,
    localDeviceId: localDeviceId,
  );

  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) => delegate.prepareControl(
    current: current,
    currentOpaqueMlsState: currentOpaqueMlsState,
    operation: operation,
    actorUserId: actorUserId,
    actorDeviceId: actorDeviceId,
    createdMs: createdMs,
  );

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) => delegate.prepareCreate(intent);

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) => delegate.prepareApplicationMessage(
    current: current,
    currentOpaqueMlsState: currentOpaqueMlsState,
    senderUserId: senderUserId,
    senderDeviceId: senderDeviceId,
    text: text,
    createdMs: createdMs,
  );

  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) => delegate.reconcileFork(
    current: current,
    currentOpaqueMlsState: currentOpaqueMlsState,
    siblingCommits: siblingCommits,
    localUserId: localUserId,
    localDeviceId: localDeviceId,
  );
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 2, 12);
}
