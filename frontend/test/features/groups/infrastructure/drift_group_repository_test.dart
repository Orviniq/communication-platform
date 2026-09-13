import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '00000000-0000-0000-0000-000000000001';
const _member = '00000000-0000-0000-0000-000000000002';
const _missing = '00000000-0000-0000-0000-000000000003';
const _device = '10000000-0000-0000-0000-000000000001';

void main() {
  late LocalDatabase database;
  late DriftGroupRepository repository;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftGroupRepository(database);
    await _insertUser(database, _owner);
    await _insertUser(database, _member);
  });

  tearDown(() => database.close());

  test(
    'MLS state, control, membership, projection, and outbox commit atomically',
    () async {
      final result = await _create(repository, _member, seed: 100);
      expect(result, isA<Success<GroupState>>());
      final state = (result as Success<GroupState>).value;

      expect(await database.select(database.mlsGroups).get(), hasLength(1));
      expect(
        await database.select(database.groupControlEvents).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.groupOutboundObjects).get(),
        hasLength(1),
      );
      expect(await database.select(database.memberships).get(), hasLength(2));
      expect(
        (await database.select(database.groupOutboundObjects).getSingle())
            .deliveryState,
        0,
      );
      expect(
        (await repository.readGroup(state.groupId)),
        isA<Success<GroupState?>>(),
      );
      expect(
        await repository.readVerifiedTranscript(state.groupId),
        isA<FailureResult<List<GroupControlTranscriptEntry>>>(),
      );
    },
  );

  test(
    'foreign-key persistence failure rolls back every group table',
    () async {
      final result = await _create(repository, _missing, seed: 110);

      expect(result, isA<FailureResult<GroupState>>());
      expect(
        (result as FailureResult<GroupState>).failure,
        isA<StorageFailure>(),
      );
      expect(await database.select(database.mlsGroups).get(), isEmpty);
      expect(await database.select(database.conversations).get(), isEmpty);
      expect(await database.select(database.groupControlEvents).get(), isEmpty);
      expect(
        await database.select(database.groupOutboundObjects).get(),
        isEmpty,
      );
      expect(await database.select(database.memberships).get(), isEmpty);
    },
  );

  test(
    'queue gap overlays a blocking rejoin state without guessing MLS state',
    () async {
      final created = await _create(repository, _member, seed: 120);
      final state = (created as Success<GroupState>).value;
      final before = await repository.readOpaqueMlsState(state.groupId);

      await (database.update(database.mlsGroups)
            ..where((row) => row.groupId.equals(state.groupId)))
          .write(const MlsGroupsCompanion(queueGapRecoveryState: Value(1)));
      final projection = await repository.readGroup(state.groupId);
      final after = await repository.readOpaqueMlsState(state.groupId);

      expect(
        (projection as Success<GroupState?>).value!.lifecycle,
        GroupLifecycle.queueGapRejoinRequired,
      );
      expect(
        (after as Success<Uint8List?>).value,
        orderedEquals((before as Success<Uint8List?>).value!),
      );
    },
  );

  test('exact recipient work moves idempotently into routed state', () async {
    final created = await _create(repository, _member, seed: 130);
    expect(created, isA<Success<GroupState>>());
    await database
        .update(database.groupOutboundObjects)
        .write(const GroupOutboundObjectsCompanion(deliveryState: Value(1)));

    final pending = await repository.readPendingOutbound();
    expect(pending, isA<Success<List<GroupOutboundWork>>>());
    final work = (pending as Success<List<GroupOutboundWork>>).value.single;
    expect(work.recipientUserIds, [_owner, _member]);
    expect(work.openedMlsPayload, isNotEmpty);

    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      (await database.select(database.groupOutboundObjects).getSingle())
          .deliveryState,
      2,
    );
    expect(
      (await repository.readPendingOutbound()
              as Success<List<GroupOutboundWork>>)
          .value,
      isEmpty,
    );
  });

  test(
    'Welcome commits consumed KeyPackage and new group atomically',
    () async {
      await database
          .into(database.devices)
          .insert(
            DevicesCompanion.insert(
              deviceId: _device,
              userId: _owner,
              publicBundle: Uint8List.fromList([1]),
              revocationState: 0,
              isCurrentDevice: const Value(true),
            ),
          );
      await database
          .into(database.secureSecrets)
          .insert(
            SecureSecretsCompanion.insert(
              secretId: 'beta-pq-mls-key-packages-v1',
              kind: 2,
              wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([50]),
              formatVersion: 1,
            ),
          );
      final intent = GroupCreationIntent(
        creatorUserId: _owner,
        creatorDeviceId: _device,
        metadata: const GroupMetadata(name: 'Joined team'),
        members: [
          GroupMember(
            userId: _owner,
            displayName: 'Owner',
            role: GroupRole.owner,
            verified: true,
            deviceIds: const [_device],
          ),
          GroupMember(
            userId: _member,
            displayName: 'Member',
            role: GroupRole.member,
          ),
        ],
        createdMs: 1,
      );
      final preview = DevelopmentInMemoryGroupMls.forTests(seed: 150);
      final outbound =
          (await preview.prepareCreate(intent)
                  as Success<PreparedGroupTransition>)
              .value;
      final incoming = PreparedGroupTransition(
        signedControl: outbound.signedControl,
        newOpaqueMlsState: outbound.newOpaqueMlsState,
        mlsObject: outbound.mlsObject,
        mutationId: 'welcome-${outbound.signedControl.event.eventId}',
        recipientUserIds: const [],
        outbound: false,
        consumedKeyPackageState: ConsumedGroupKeyPackageState(
          deviceId: _device,
          expectedStateRevision: 1,
          nextSealedState: Uint8List.fromList([51]),
        ),
        controlTranscriptEntry: GroupControlTranscriptEntry(
          signedControl: outbound.signedControl,
          signedPayload: Uint8List.fromList('CPGCV001'.codeUnits),
          signerAuthenticationProof: Uint8List.fromList('CPBRV001'.codeUnits),
        ),
      );
      final applied =
          const GroupControlStateMachine().apply(
                previous: null,
                signedControl: incoming.signedControl,
                localUserId: _owner,
              )
              as GroupControlAccepted;

      final result = await repository.commitTransition(
        expectedPrevious: null,
        next: applied.state,
        prepared: incoming,
        developmentPreviewOnly: false,
      );

      expect(result, isA<Success<void>>());
      final secret = await database.select(database.secureSecrets).getSingle();
      expect(secret.wrappedCiphertextOrOpaqueHandle, [51]);
      expect(secret.stateRevision, 2);
      expect(await database.select(database.mlsGroups).get(), hasLength(1));
      final transcript = await repository.readVerifiedTranscript(
        applied.state.groupId,
      );
      expect(
        (transcript as Success<List<GroupControlTranscriptEntry>>).value,
        hasLength(1),
      );
      expect(
        await database.select(database.groupOutboundObjects).get(),
        isEmpty,
      );
    },
  );

  test('received application commits state without outbound work', () async {
    final created = await _create(repository, _member, seed: 160);
    final state = (created as Success<GroupState>).value;
    await database.delete(database.groupOutboundObjects).go();
    const messageId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    final result = await repository.commitMessage(
      expectedGroup: state,
      prepared: PreparedGroupMessage(
        groupId: state.groupId,
        messageId: messageId,
        senderUserId: _member,
        senderDeviceId: '20000000-0000-0000-0000-000000000001',
        text: 'received safely',
        createdMs: 1_700_000_000_004,
        epoch: state.acceptedEpoch,
        newOpaqueMlsState: Uint8List.fromList([201]),
        mlsObject: Uint8List.fromList([202]),
        operationId: 'beta-group-inbound-message-$messageId',
        recipientUserIds: const [],
        outbound: false,
      ),
      developmentPreviewOnly: false,
    );

    expect(result, isA<Success<void>>());
    expect(await database.select(database.groupOutboundObjects).get(), isEmpty);
    expect(
      (await database.select(database.messages).getSingle()).status,
      MessageTransportState.received.index,
    );
    expect(
      (await repository.readOpaqueMlsState(state.groupId)
              as Success<Uint8List?>)
          .value,
      [201],
    );
  });
}

Future<Result<GroupState>> _create(
  DriftGroupRepository repository,
  String memberId, {
  required int seed,
}) =>
    CreateGroup(
      repository: repository,
      crypto: DevelopmentInMemoryGroupMls.forTests(seed: seed),
      clock: const _Clock(),
      developmentPreviewOnly: true,
    )(
      currentUserId: _owner,
      currentDeviceId: _device,
      ownerDisplayName: 'Owner',
      metadata: const GroupMetadata(name: 'Team'),
      selectedMembers: [
        GroupMember(
          userId: memberId,
          displayName: 'Member',
          role: GroupRole.member,
        ),
      ],
    );

Future<void> _insertUser(LocalDatabase database, String id) => database
    .into(database.users)
    .insert(
      UsersCompanion.insert(
        userId: id,
        activated: true,
        directoryEntryCiphertext: Uint8List.fromList([1]),
        localState: 0,
      ),
    );

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 2, 12);
}
