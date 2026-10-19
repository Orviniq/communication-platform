import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberDevice = '60000000-0000-4000-8000-000000000001';
const _outsider = '40000000-0000-4000-8000-000000000001';
const _envelope = '50000000-0000-4000-8000-000000000001';
final _groupA = 'a1' * 32;
final _groupB = 'b2' * 32;
final _groupC = 'c3' * 32;

/// A group's roster is client state (`backend/CLIENT_CONTRACT.md` §F): the
/// projection, the signed transcript that justifies it, the bytes it still
/// owes, and the requests it still waits on all live in this store.
void main() {
  late LocalDatabase database;
  late DriftGroupRepository repository;

  Future<({GroupState group, SignedGroupControlEvent create})> commitCreate(
    String groupId, {
    String localUserId = _owner,
    List<GroupOutboundWork> outbound = const [],
  }) async {
    final create = _signed(
      groupId,
      revision: 1,
      previous: null,
      operation: _createOperation(),
    );
    final group = _apply(null, create, localUserId: localUserId);
    final committed = await repository.commitTransition(
      expectedPrevious: null,
      next: group,
      prepared: PreparedGroupTransition(controls: [create], outbound: outbound),
    );
    expect(committed, isA<Success<void>>());
    return (group: group, create: create);
  }

  Future<GroupState> stored(String groupId) async =>
      (await repository.readStoredGroup(groupId) as Success<GroupState?>)
          .value!;

  Future<List<Message>> groupMessages() => (database.select(
    database.messages,
  )..where((row) => row.conversationId.equals(_groupA))).get();

  Future<GroupState> projected(String groupId) async =>
      (await repository.readGroup(groupId) as Success<GroupState?>).value!;

  Future<(QueueGapState, int)> gap(DriftSyncStore sync) async {
    final projection =
        (await sync.readProjection() as Success<SyncProjection>).value;
    return (
      projection.queueGapState,
      projection.highestContiguousAcknowledgedSequence,
    );
  }

  Future<void> drainWithGap(DriftSyncStore sync) async {
    final persisted = await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: _envelope,
            sequence: 6,
            exactCiphertext: Uint8List(1024),
          ),
        ],
        hasMore: false,
        prunedThrough: 5,
      ),
    );
    expect(persisted, isA<Success<void>>());
  }

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftGroupRepository(database);
  });

  tearDown(() => database.close());

  test(
    'a group reads back exactly as committed, with its transcript',
    () async {
      final (:group, :create) = await commitCreate(_groupA);

      final read = await stored(_groupA);
      expect(read.groupId, _groupA);
      expect(read.metadata, group.metadata);
      expect(read.invitationPolicy, group.invitationPolicy);
      expect(read.historySharingPolicy, group.historySharingPolicy);
      expect(read.members, group.members);
      expect(read.controlRevision, 1);
      expect(read.controlStateHash, create.controlStateHash);
      expect(read.lifecycle, GroupLifecycle.active);
      expect((await projected(_groupA)).lifecycle, GroupLifecycle.active);

      final transcript =
          (await repository.readTranscript(_groupA)
                  as Success<List<StoredGroupControl>>)
              .value;
      expect(transcript.single.eventId, create.event.eventId);
      expect(transcript.single.previousControlStateHash, isNull);
      expect(transcript.single.controlStateHash, create.controlStateHash);
      expect(transcript.single.signerUserId, _owner);
      expect(transcript.single.signerDeviceId, _ownerDevice);
      expect(transcript.single.canonicalBytes, create.canonicalBytes);
      expect(transcript.single.signature, create.signature);

      final conversation = await database
          .select(database.conversations)
          .getSingle();
      expect(conversation.conversationId, _groupA);
      expect(conversation.kind, ConversationKind.group.index);
      expect(utf8.decode(conversation.displayTitleCiphertext!), 'Stored');
    },
  );

  test(
    'a transition built on a state another commit replaced is refused whole',
    () async {
      final (:group, :create) = await commitCreate(_groupA);
      final first = _signed(
        _groupA,
        revision: 2,
        previous: create,
        operation: const RenameGroupOperation(GroupMetadata(name: 'First')),
      );
      final second = _signed(
        _groupA,
        revision: 2,
        previous: create,
        operation: const RenameGroupOperation(GroupMetadata(name: 'Second')),
        branch: 1,
      );
      expect(
        await repository.commitTransition(
          expectedPrevious: group,
          next: _apply(group, first),
          prepared: PreparedGroupTransition(controls: [first]),
        ),
        isA<Success<void>>(),
      );

      final result = await repository.commitTransition(
        expectedPrevious: group,
        next: _apply(group, second),
        prepared: PreparedGroupTransition(
          controls: [second],
          outbound: [_work(_groupA, 'never-queued')],
        ),
      );

      expect(
        (result as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      expect((await stored(_groupA)).metadata.name, 'First');
      expect(
        (await repository.readTranscript(_groupA)
                as Success<List<StoredGroupControl>>)
            .value
            .map((entry) => entry.eventId),
        [create.event.eventId, first.event.eventId],
      );
      expect(
        await database.select(database.groupOutboundObjects).get(),
        isEmpty,
      );
    },
  );

  test('a transition that does not continue its own base is refused', () async {
    final (:group, :create) = await commitCreate(_groupA);
    final rename = _signed(
      _groupA,
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );

    final result = await repository.commitTransition(
      expectedPrevious: null,
      next: _apply(group, rename),
      prepared: PreparedGroupTransition(controls: [rename]),
    );

    expect(
      (result as FailureResult<void>).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
    expect((await stored(_groupA)).controlRevision, 1);
  });

  test('owed bytes are queued once and routed once', () async {
    final work = _work(_groupA, 'group-control:first', includeOwnDevices: true);
    await commitCreate(_groupA, outbound: [work]);
    await database.transaction(
      () => repository.queueOutboundInsideTransaction(work),
    );

    final pending =
        (await repository.readPendingOutbound()
                as Success<List<GroupOutboundWork>>)
            .value;
    expect(pending, hasLength(1));
    expect(pending.single.operationId, work.operationId);
    expect(pending.single.eventId, work.eventId);
    expect(pending.single.payload, work.payload);
    expect(pending.single.recipientUserIds, [_member]);
    expect(pending.single.recipientDeviceId, isNull);
    expect(pending.single.includeOwnDevices, isTrue);

    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      (await repository.readPendingOutbound()
              as Success<List<GroupOutboundWork>>)
          .value,
      isEmpty,
    );
    expect(
      (await repository.markOutboundRouted(operationId: 'missing')
              as FailureResult<void>)
          .failure,
      const ValidationFailure(ValidationFailureKind.conflict),
    );
  });

  test(
    'a queue gap asks every active group, and closes when the last one answers',
    () async {
      await commitCreate(_groupA);
      await commitCreate(_groupB);
      // A group this device is not in cannot be answered for it.
      await commitCreate(_groupC, localUserId: _outsider);
      final sync = DriftSyncStore(database);

      await drainWithGap(sync);

      final requests = await database.select(database.groupStateRequests).get();
      expect(
        requests.map((row) => (row.groupId, row.reason)),
        unorderedEquals([(_groupA, 0), (_groupB, 0)]),
      );
      expect(
        (await projected(_groupA)).lifecycle,
        GroupLifecycle.stateRecoveryRequired,
      );
      expect((await stored(_groupA)).lifecycle, GroupLifecycle.active);
      expect(await gap(sync), (QueueGapState.recoveryRequired, 0));

      expect(
        await repository.retireStateRequest(_groupA),
        isA<Success<void>>(),
      );

      expect(await gap(sync), (QueueGapState.recoveryRequired, 0));

      expect(
        await repository.retireStateRequest(_groupB),
        isA<Success<void>>(),
      );

      expect(await gap(sync), (QueueGapState.clear, 5));
      expect((await projected(_groupA)).lifecycle, GroupLifecycle.active);
    },
  );

  test('a queue gap with no group to ask closes at once', () async {
    await commitCreate(_groupC, localUserId: _outsider);
    final sync = DriftSyncStore(database);

    await drainWithGap(sync);

    expect(await database.select(database.groupStateRequests).get(), isEmpty);
    expect(await gap(sync), (QueueGapState.clear, 5));
  });

  test(
    'a closing gap releases envelopes already acknowledged above it',
    () async {
      await commitCreate(_groupA);
      final sync = DriftSyncStore(database);
      await drainWithGap(sync);
      // Nothing waits on the gap, so the envelope above it is opened and
      // acknowledged while the group's request is still open.
      await (database.update(database.inboxEnvelopes)).write(
        InboxEnvelopesCompanion(
          processingState: Value(InboxProcessingState.acknowledged.index),
        ),
      );

      await repository.retireStateRequest(_groupA);

      expect(await gap(sync), (QueueGapState.clear, 6));
      expect(await database.select(database.inboxEnvelopes).get(), isEmpty);
    },
  );

  test(
    'requests for unknown groups are bounded, and an open one is kept',
    () async {
      for (
        var index = 0;
        index < DriftGroupRepository.maximumStateRequests + 3;
        index += 1
      ) {
        await repository.openStateRequest(
          groupId: index.toRadixString(16).padLeft(64, '0'),
          peerUserId: _member,
        );
      }

      expect(
        await database.select(database.groupStateRequests).get(),
        hasLength(DriftGroupRepository.maximumStateRequests),
      );

      await repository.openStateRequest(groupId: '0' * 64, peerUserId: _owner);

      final first = await (database.select(
        database.groupStateRequests,
      )..where((row) => row.groupId.equals('0' * 64))).getSingle();
      expect(first.peerUserId, _member);
      expect(first.reason, 1);
    },
  );

  test(
    'a sent request records who was asked, and waits before asking again',
    () async {
      await repository.openStateRequest(groupId: _groupA, peerUserId: _member);
      final requestedAt = DateTime.utc(2026, 9, 13, 12);
      final work = _work(_groupA, 'group-state-request:$_groupA:1');

      expect(
        await repository.recordStateRequestSent(
          groupId: _groupA,
          peerUserId: _owner,
          work: work,
          requestedAt: requestedAt,
        ),
        isA<Success<void>>(),
      );

      final row = await database
          .select(database.groupStateRequests)
          .getSingle();
      expect(row.peerUserId, _owner);
      expect(row.attempts, 1);
      expect(row.requestedAt!.toUtc(), requestedAt);
      expect(
        (await repository.readPendingOutbound()
                as Success<List<GroupOutboundWork>>)
            .value
            .single
            .operationId,
        work.operationId,
      );

      Future<List<GroupStateRequest>> due(DateTime retryBefore) async =>
          (await repository.readDueStateRequests(retryBefore: retryBefore)
                  as Success<List<GroupStateRequest>>)
              .value;
      expect(
        await due(requestedAt.subtract(const Duration(seconds: 1))),
        isEmpty,
      );
      final again = (await due(requestedAt)).single;
      expect(again.reason, GroupStateRequestReason.behind);
      expect(again.peerUserId, _owner);
      expect(again.attempts, 1);

      final unopened = await repository.recordStateRequestSent(
        groupId: _groupB,
        peerUserId: _owner,
        work: _work(_groupB, 'group-state-request:$_groupB:1'),
        requestedAt: requestedAt,
      );
      expect(
        (unopened as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
    },
  );

  test(
    'a confirmation retires only the request for the state it saw',
    () async {
      final (:group, :create) = await commitCreate(_groupA);
      await repository.openStateRequest(groupId: _groupA, peerUserId: _member);

      await database.transaction(
        () => repository.confirmStateCurrentInsideTransaction(
          groupId: _groupA,
          controlRevision: 2,
          controlStateHash: group.controlStateHash,
        ),
      );

      expect(
        await database.select(database.groupStateRequests).get(),
        hasLength(1),
      );

      await database.transaction(
        () => repository.confirmStateCurrentInsideTransaction(
          groupId: _groupA,
          controlRevision: 1,
          controlStateHash: create.controlStateHash,
        ),
      );

      expect(await database.select(database.groupStateRequests).get(), isEmpty);
    },
  );

  test(
    'a fork quarantines the group; a refused event only leaves a record',
    () async {
      await commitCreate(_groupA);
      GroupQuarantineRecord record(GroupQuarantineReason reason) =>
          GroupQuarantineRecord(
            groupId: _groupA,
            reason: reason,
            opaqueDigest: Uint8List(32),
            receivedAt: DateTime.utc(2026, 9, 13),
          );

      await database.transaction(
        () => repository.quarantineInsideTransaction(
          record(GroupQuarantineReason.unauthorizedControl),
          retainLifecycle: true,
        ),
      );

      expect((await stored(_groupA)).lifecycle, GroupLifecycle.active);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(1),
      );

      await database.transaction(
        () => repository.quarantineInsideTransaction(
          record(GroupQuarantineReason.siblingControl),
          retainLifecycle: false,
        ),
      );

      final forked = await stored(_groupA);
      expect(forked.lifecycle, GroupLifecycle.forkQuarantined);
      expect(forked.quarantineReason, GroupQuarantineReason.siblingControl);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(2),
      );
    },
  );

  test('storage that does not read back intact fails closed', () async {
    final (:group, :create) = await commitCreate(_groupA);
    final rename = _signed(
      _groupA,
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );
    await repository.commitTransition(
      expectedPrevious: group,
      next: _apply(group, rename),
      prepared: PreparedGroupTransition(controls: [rename]),
    );

    await (database.update(
      database.groupControlEvents,
    )..where((row) => row.revision.equals(2))).write(
      GroupControlEventsCompanion(
        previousControlStateHash: Value(Uint8List(32)),
      ),
    );

    expect(
      (await repository.readTranscript(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );

    await (database.update(database.groupStates)).write(
      GroupStatesCompanion(
        controlProjectionCiphertext: Value(
          Uint8List.fromList(utf8.encode('{}')),
        ),
      ),
    );

    expect(
      (await repository.readStoredGroup(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
    expect(
      (await repository.readGroup(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
  });

  group('leaving, or being removed, deletes the group from this phone '
      '(ADR-096 D1, D2)', () {
    final messageOne = _messageId(0x11);
    final messageTwo = _messageId(0x12);

    Future<ApplicationApplyResult> project(ApplicationEventCommit commit) =>
        database.writeTransaction(
          () => DriftApplicationEventProjector(
            database,
          ).applyInsideTransaction(commit),
        );

    /// The group of [commitCreate] with this account as its member, two
    /// messages, a reaction, a read, a draft and an attachment row.
    Future<({GroupState group, SignedGroupControlEvent create})>
    groupWithHistory() async {
      final created = await commitCreate(_groupA, localUserId: _member);
      await project(_groupEvent(_groupA, 0x11, sender: _owner));
      await project(_groupEvent(_groupA, 0x12, sender: _member));
      await project(
        _groupEvent(
          _groupA,
          0x13,
          sender: _owner,
          kind: ApplicationEventKind.reactionSet,
          target: messageTwo,
        ),
      );
      await project(
        _groupEvent(
          _groupA,
          0x14,
          sender: _owner,
          kind: ApplicationEventKind.receiptRead,
          target: messageTwo,
        ),
      );
      await (database.update(
        database.conversations,
      )..where((row) => row.conversationId.equals(_groupA))).write(
        ConversationsCompanion(
          draftCiphertext: Value(Uint8List.fromList(utf8.encode('unsent'))),
        ),
      );
      await database
          .into(database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              attachmentId: 'attachment-one',
              messageId: protocolBytesToHex(messageOne),
              encryptedDescriptor: Uint8List.fromList(const [1]),
              transferState: 0,
            ),
          );
      // The history is there before the change.
      expect(await groupMessages(), hasLength(2));
      expect(
        await database.select(database.messageReactions).get(),
        isNot(isEmpty),
      );
      expect(await database.select(database.receipts).get(), isNot(isEmpty));
      return created;
    }

    Future<GroupState> commitNext(
      GroupState previous,
      SignedGroupControlEvent signed,
    ) async {
      final next = _apply(previous, signed, localUserId: _member);
      expect(
        await repository.commitTransition(
          expectedPrevious: previous,
          next: next,
          prepared: PreparedGroupTransition(controls: [signed]),
        ),
        isA<Success<void>>(),
      );
      return next;
    }

    Future<Conversation> conversation() => (database.select(
      database.conversations,
    )..where((row) => row.conversationId.equals(_groupA))).getSingle();

    Future<List<String>> listed() async => [
      for (final summary in await DriftConversationDomainRepository(
        database,
      ).watchConversations(_member).first)
        summary.conversationId,
    ];

    Future<void> expectGone() async {
      final row = await conversation();
      expect(row.tombstoned, isTrue);
      expect(row.draftCiphertext, isNull);
      expect(row.unreadCount, 0);
      expect(row.listProjectionCiphertext, isEmpty);
      expect(await listed(), isNot(contains(_groupA)));
      expect(await groupMessages(), isEmpty);
      expect(await database.select(database.messageReactions).get(), isEmpty);
      expect(await database.select(database.receipts).get(), isEmpty);
      expect(await database.select(database.attachments).get(), isEmpty);
      final facts = await (database.select(
        database.storedApplicationEvents,
      )..where((row) => row.conversationId.equals(_groupA))).get();
      expect(facts, hasLength(4));
      expect(facts.map((fact) => fact.applyState), everyElement(4));
    }

    test('a signed leave of this account deletes it, with its rows, and '
        'keeps the signed state', () async {
      final (:group, :create) = await groupWithHistory();
      expect(await listed(), contains(_groupA));

      await commitNext(
        group,
        _signed(
          _groupA,
          revision: 2,
          previous: create,
          operation: RemoveGroupMemberOperation(_member),
          signer: _member,
        ),
      );

      await expectGone();
      final state = await stored(_groupA);
      expect(state.lifecycle, GroupLifecycle.left);
      expect(state.controlRevision, 2);
      expect(
        (await repository.readTranscript(_groupA)
                as Success<List<StoredGroupControl>>)
            .value,
        hasLength(2),
      );
    });

    test('a removal signed by the owner deletes it the same way', () async {
      final (:group, :create) = await groupWithHistory();

      await commitNext(
        group,
        _signed(
          _groupA,
          revision: 2,
          previous: create,
          operation: RemoveGroupMemberOperation(_member),
        ),
      );

      await expectGone();
      expect((await stored(_groupA)).lifecycle, GroupLifecycle.removed);
    });

    test('a retired fact folds back nothing: not a rebuild, not a late '
        'reaction, and a replay is a duplicate', () async {
      final (:group, :create) = await groupWithHistory();
      await commitNext(
        group,
        _signed(
          _groupA,
          revision: 2,
          previous: create,
          operation: RemoveGroupMemberOperation(_member),
          signer: _member,
        ),
      );

      await database.writeTransaction(
        () => DriftApplicationEventProjector(
          database,
        ).rebuildConversationInsideTransaction(_groupA, currentUserId: _member),
      );
      expect(await groupMessages(), isEmpty);

      final late = await project(
        _groupEvent(
          _groupA,
          0x15,
          sender: _owner,
          kind: ApplicationEventKind.reactionSet,
          target: messageOne,
        ),
      );
      expect(late.disposition, ApplicationApplyDisposition.applied);
      expect(await groupMessages(), isEmpty);

      final replay = await project(_groupEvent(_groupA, 0x11, sender: _owner));
      expect(replay.disposition, ApplicationApplyDisposition.duplicate);
      expect(await groupMessages(), isEmpty);
    });

    test('an addition after a removal brings the group back to Chats with no '
        'old history (ADR-096 D2)', () async {
      final (:group, :create) = await groupWithHistory();
      final removal = _signed(
        _groupA,
        revision: 2,
        previous: create,
        operation: RemoveGroupMemberOperation(_member),
      );
      final removed = await commitNext(group, removal);
      await expectGone();

      final back = await commitNext(
        removed,
        _signed(
          _groupA,
          revision: 3,
          previous: removal,
          operation: AddGroupMembersOperation([
            GroupMember(
              userId: _member,
              displayName: 'Member',
              role: GroupRole.member,
            ),
          ]),
        ),
      );

      expect(back.lifecycle, GroupLifecycle.active);
      expect((await stored(_groupA)).lifecycle, GroupLifecycle.active);
      expect((await conversation()).tombstoned, isFalse);
      expect(await listed(), contains(_groupA));
      expect(await groupMessages(), isEmpty);

      await project(_groupEvent(_groupA, 0x21, sender: _owner, text: 'again'));
      final messages = await groupMessages();
      expect(messages.map((message) => message.messageId), [
        protocolBytesToHex(_messageId(0x21)),
      ]);
    });

    test('a change that keeps this account in the group clears no '
        'tombstone the user set', () async {
      final (:group, :create) = await groupWithHistory();
      expect(
        await DriftConversationDomainRepository(
          database,
        ).deleteConversationForMe(_groupA),
        isA<Success<void>>(),
      );

      await commitNext(
        group,
        _signed(
          _groupA,
          revision: 2,
          previous: create,
          operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
        ),
      );

      expect((await conversation()).tombstoned, isTrue);
      expect(await groupMessages(), hasLength(2));
    });
  });

  group("a group message's delivery", () {
    Future<void> message(
      String messageId,
      MessageTransportState status, {
      String sender = _owner,
    }) => database
        .into(database.messages)
        .insert(
          MessagesCompanion.insert(
            messageId: messageId,
            conversationId: _groupA,
            currentEventId: messageId,
            projectionCiphertext: Uint8List.fromList(utf8.encode(messageId)),
            status: status.index,
            revision: 0,
            createdAt: DateTime.utc(2026, 9, 13),
            senderUserId: Value(sender),
            orderingEventId: Value(messageId),
          ),
        );

    Future<void> copy(
      String messageId,
      String deviceId,
      OutboxAttemptState state,
    ) => database
        .into(database.outboxOperations)
        .insert(
          OutboxOperationsCompanion.insert(
            operationId: 'application:$messageId',
            eventId: messageId,
            recipientDeviceId: deviceId,
            recipientUserId: const Value(_member),
            batchIndex: 0,
            exactRecipientCiphertext: Uint8List(1024),
            attemptState: state.index,
          ),
        );

    test('counts accepted copies of the devices still in the set', () async {
      await commitCreate(_groupA);
      await message('m1', MessageTransportState.partiallyAccepted);
      await copy('m1', 'd1', OutboxAttemptState.accepted);
      await copy('m1', 'd2', OutboxAttemptState.accepted);
      await copy('m1', 'd3', OutboxAttemptState.queued);
      // A full mailbox waits for its retry and is still owed its copy.
      await copy('m1', 'd4', OutboxAttemptState.retryWait);
      // A device the server reported as gone is owed nothing.
      await copy('m1', 'd5', OutboxAttemptState.stale);
      await message('m2', MessageTransportState.relayAccepted);
      await copy('m2', 'd1', OutboxAttemptState.accepted);

      final progress = await repository.watchFanoutProgress(_groupA).first;

      expect(progress, {'m1': GroupFanoutProgress(sent: 2, total: 4)});
    });
  });
}

SignedGroupControlEvent _signed(
  String groupId, {
  required int revision,
  required SignedGroupControlEvent? previous,
  required GroupControlOperation operation,
  int branch = 0,
  String signer = _owner,
}) {
  final marker = ((branch << 4) | revision).toRadixString(16).padLeft(2, '0');
  final eventId = '${groupId.substring(0, 16)}${marker * 8}';
  return SignedGroupControlEvent(
    event: GroupControlEvent(
      eventId: eventId,
      groupId: groupId,
      revision: revision,
      previousControlStateHash: previous?.controlStateHash,
      signerUserId: signer,
      signerDeviceId: _ownerDevice,
      createdMs: 1700000000000 + revision,
      operation: operation,
    ),
    controlStateHash: '${groupId.substring(0, 32)}${marker * 16}',
    canonicalBytes: Uint8List.fromList(utf8.encode('control $eventId')),
    signature: Uint8List.fromList(List<int>.filled(64, revision)),
  );
}

Uint8List _messageId(int seed) => Uint8List.fromList(List.filled(16, seed));

/// One application event of [groupId]'s conversation, as a member's device
/// sent it: a message, or a reaction or a read of [target].
ApplicationEventCommit _groupEvent(
  String groupId,
  int seed, {
  required String sender,
  ApplicationEventKind kind = ApplicationEventKind.messageCreate,
  Uint8List? target,
  String text = 'said in the group',
}) {
  final eventId = _messageId(seed);
  final event = ApplicationEventRecord(
    version: ApplicationMessageProtocolV1.version,
    eventId: eventId,
    conversationId: Uint8List.fromList([
      for (var index = 0; index < groupId.length; index += 2)
        int.parse(groupId.substring(index, index + 2), radix: 16),
    ]),
    kindValue: kind.wireValue,
    senderUserId: protocolUuidBytes(sender),
    senderDeviceId: protocolUuidBytes(
      sender == _owner ? _ownerDevice : _memberDevice,
    ),
    senderCounter: seed,
    createdMs: 1700000000000 + seed * 1000,
    references: [?target],
    body: switch (kind) {
      ApplicationEventKind.reactionSet => ReactionSetBody(
        targetMessageId: target!,
        emoji: '\u{1F44D}',
      ),
      ApplicationEventKind.receiptRead => ReceiptBody(messageIds: [target!]),
      _ => MessageCreateBody(messageId: eventId, text: text),
    },
  );
  return ApplicationEventCommit(
    event: event,
    canonicalBytes: Uint8List.fromList([seed, kind.wireValue, ...eventId]),
    currentUserId: _member,
    currentDeviceId: _memberDevice,
    conversationKind: ConversationKind.group.index,
    peerUserId: null,
    localOrigin: false,
    authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
      1700000300000,
      isUtc: true,
    ),
  );
}

GroupState _apply(
  GroupState? previous,
  SignedGroupControlEvent signed, {
  String localUserId = _owner,
}) =>
    (const GroupControlStateMachine().apply(
              previous: previous,
              signedControl: signed,
              localUserId: localUserId,
            )
            as GroupControlAccepted)
        .state;

CreateGroupOperation _createOperation() => CreateGroupOperation(
  metadata: const GroupMetadata(name: 'Stored', description: 'Kept here'),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: [
    GroupMember(
      userId: _owner,
      displayName: 'Owner',
      role: GroupRole.owner,
      verified: true,
    ),
    GroupMember(userId: _member, displayName: 'Member', role: GroupRole.member),
  ],
);

GroupOutboundWork _work(
  String groupId,
  String operationId, {
  bool includeOwnDevices = false,
}) => GroupOutboundWork(
  operationId: operationId,
  groupId: groupId,
  eventId: operationId,
  payload: Uint8List.fromList(const [1, 2, 3]),
  recipientUserIds: const [_member],
  includeOwnDevices: includeOwnDevices,
);
