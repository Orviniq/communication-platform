import 'dart:convert';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_access_adapters.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_send_preparation_adapter.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A group message on its way out, from the moment it is written to the moment
/// its last copy settles, against the real group store, the real audience
/// resolver and the real durable outbox (`backend/CLIENT_CONTRACT.md` §F).
///
/// A group message is one copy for each live device of each member. Only who
/// those devices are, the prekey claim, the signing call and the ratchet step
/// are stand-ins; the answers to `POST /envelopes` are recorded exactly as the
/// sync store records a real one.
const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberPhone = '40000000-0000-4000-8000-000000000001';
const _memberLaptop = '40000000-0000-4000-8000-000000000002';
const _second = '50000000-0000-4000-8000-000000000001';
const _secondDevice = '60000000-0000-4000-8000-000000000001';

void main() {
  final now = DateTime.utc(2026, 9, 13, 10);
  late LocalDatabase database;
  late DriftGroupRepository groups;
  late DriftSyncStore sync;
  late _Resolver resolver;
  late _Crypto crypto;
  late PairwiseFanoutCoordinator fanout;
  late PairwiseSendPreparationAdapter preparation;
  late GroupState group;
  late int counter;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    groups = DriftGroupRepository(database);
    sync = DriftSyncStore(database);
    resolver = _Resolver({
      _owner: [_device(_owner, _ownerDevice)],
      _member: [
        _device(_member, _memberPhone),
        _device(_member, _memberLaptop),
      ],
      _second: [_device(_second, _secondDevice)],
    });
    crypto = _Crypto();
    fanout = PairwiseFanoutCoordinator(
      store: DriftPairwiseTransportStore(database),
      liveDevices: resolver,
      claims: _Claims(resolver),
      crypto: crypto,
      clock: const _Clock(),
    );
    preparation = PairwiseSendPreparationAdapter(
      fanout,
      audience: DriftGroupSendAudienceResolver(
        database: database,
        groups: groups,
      ),
    );
    counter = 0;
    await database
        .into(database.secureSecrets)
        .insert(
          SecureSecretsCompanion.insert(
            secretId: 'current-device-key-state-v1',
            kind: 0,
            wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([7]),
            formatVersion: 2,
          ),
        );
    group = await _create(groups, [_member, _second]);
  });

  tearDown(() => database.close());

  /// Writes a group message the way a send does, and returns its event id.
  Future<String> write(String text) async {
    counter += 1;
    final eventIdBytes = Uint8List.fromList(
      List<int>.generate(16, (index) => (counter * 17 + index) & 0xff),
    );
    final eventId = protocolBytesToHex(eventIdBytes);
    final canonical = Uint8List.fromList(utf8.encode('group message $eventId'));
    final echoed = await fanout.commitLocalEcho(
      operationId: 'application:$eventId',
      eventId: eventId,
      currentUserId: _owner,
      currentDeviceId: _ownerDevice,
      // A group message names no peer, so its send addresses this account.
      peerUserId: _owner,
      openedOpaquePayload: canonical,
      applicationEvent: ApplicationEventCommit(
        event: ApplicationEventRecord(
          version: ApplicationMessageProtocolV1.version,
          eventId: eventIdBytes,
          conversationId: _hexBytes(group.groupId),
          kindValue: ApplicationEventKind.messageCreate.wireValue,
          senderUserId: protocolUuidBytes(_owner),
          senderDeviceId: protocolUuidBytes(_ownerDevice),
          senderCounter: counter,
          createdMs: now.millisecondsSinceEpoch + counter,
          references: const [],
          body: MessageCreateBody(messageId: eventIdBytes, text: text),
        ),
        canonicalBytes: canonical,
        currentUserId: _owner,
        currentDeviceId: _ownerDevice,
        conversationKind: ConversationKind.group.index,
        peerUserId: null,
        localOrigin: true,
        authenticatedAt: now,
      ),
    );
    expect(echoed, isA<Success<void>>());
    return eventId;
  }

  /// Seals the copies a written message is owed, as the delivery cycle does.
  Future<Result<void>> seal(String eventId) => preparation.prepare(
    PendingSendPreparation(
      operationId: 'application:$eventId',
      eventId: eventId,
      localUserId: _owner,
      localDeviceId: _ownerDevice,
      peerUserId: _owner,
      attempt: 0,
    ),
  );

  Future<OutboxBatch> nextBatch(DateTime at) async =>
      (await sync.beginNextOutboxBatch(now: at) as Success<OutboxBatch?>)
          .value!;

  /// Records what the server answered for [batch].
  Future<void> answer(
    OutboxBatch batch, {
    Set<String> stale = const {},
    Set<String> full = const {},
    DateTime? retryFullAt,
  }) async {
    final recorded = await sync.recordOutboxAcceptance(
      batch: batch,
      acceptance: OutboxAcceptance(
        accepted: batch.targets.length - stale.length - full.length,
        staleDeviceIds: stale,
        fullDeviceIds: full,
      ),
      now: now,
      retryFullAt: retryFullAt ?? now.add(const Duration(minutes: 5)),
    );
    expect(recorded, isA<Success<void>>());
  }

  Future<GroupMessageDelivery> delivery(String eventId) async =>
      (await groups.watchMessages(group.groupId).first)
          .singleWhere((message) => message.messageId == eventId)
          .delivery;

  Future<Map<String, GroupFanoutProgress>> progress() =>
      groups.watchFanoutProgress(group.groupId).first;

  Future<List<String>> copiesOf(String eventId) async => [
    for (final row
        in await (database.select(database.outboxOperations)
              ..where((row) => row.eventId.equals(eventId))
              ..orderBy([(row) => OrderingTerm.asc(row.recipientDeviceId)]))
            .get())
      row.recipientDeviceId,
  ];

  Future<List<String>> sessionDevices() async => [
    for (final row in await database.select(database.pairwiseSessions).get())
      row.remoteDeviceId,
  ];

  test('a group send makes one copy for each live device', () async {
    final eventId = await write('to everyone');
    expect(await delivery(eventId), GroupMessageDelivery.preparing);

    expect(await seal(eventId), isA<Success<void>>());

    expect(await copiesOf(eventId), [
      _memberPhone,
      _memberLaptop,
      _secondDevice,
    ]);
    expect(crypto.calls, hasLength(3));
    expect(await delivery(eventId), GroupMessageDelivery.queued);
    expect(await progress(), {eventId: GroupFanoutProgress(sent: 0, total: 3)});
  });

  test('a stale_devices answer removes the device from the set', () async {
    final first = await write('before the laptop was revoked');
    await seal(first);

    await answer(await nextBatch(now), stale: {_memberLaptop});

    // The laptop is gone. Its copy is settled, its session is deleted and its
    // owner's device list is queued to be read again, so the message is sent
    // once the two live devices have their copies.
    expect(await delivery(first), GroupMessageDelivery.sent);
    expect(await progress(), isEmpty);
    expect(await sessionDevices(), isNot(contains(_memberLaptop)));
    expect(
      (await database.select(database.staleDeviceRefreshRequests).get()).map(
        (row) => (row.userId, row.staleDeviceId),
      ),
      [(_member, _memberLaptop)],
    );

    // The device list read again no longer names the laptop, and the next
    // message is sealed for nobody else than the devices still in the set.
    resolver.devices[_member] = [_device(_member, _memberPhone)];
    final second = await write('after the laptop was revoked');
    expect(await seal(second), isA<Success<void>>());

    expect(await copiesOf(second), [_memberPhone, _secondDevice]);
  });

  test(
    'a full_devices answer keeps the device and sends its copy again later',
    () async {
      final eventId = await write('to a full mailbox');
      await seal(eventId);
      final retryAt = now.add(const Duration(minutes: 5));
      final first = await nextBatch(now);
      final sealed = first.targets
          .singleWhere((target) => target.recipientDeviceId == _secondDevice)
          .exactCiphertext;

      await answer(first, full: {_secondDevice}, retryFullAt: retryAt);

      // The device is live and only out of room: its copy waits, its session
      // stays, nobody's device list is read again, and the message is still
      // sending with two of its three copies out.
      expect(await delivery(eventId), GroupMessageDelivery.sending);
      expect(await progress(), {
        eventId: GroupFanoutProgress(sent: 2, total: 3),
      });
      expect(await sessionDevices(), contains(_secondDevice));
      expect(
        await database.select(database.staleDeviceRefreshRequests).get(),
        isEmpty,
      );
      final early = await sync.beginNextOutboxBatch(
        now: now.add(const Duration(minutes: 1)),
      );
      expect((early as Success<OutboxBatch?>).value, isNull);

      final retry = await nextBatch(retryAt);

      // The same bytes go again: nothing is encrypted a second time.
      expect(retry.targets.map((target) => target.recipientDeviceId), [
        _secondDevice,
      ]);
      expect(retry.targets.single.exactCiphertext, sealed);
      expect(crypto.calls, hasLength(3));

      await answer(retry);

      expect(await delivery(eventId), GroupMessageDelivery.sent);
      expect(await progress(), isEmpty);
    },
  );

  test('a removed member gets no more copies', () async {
    // Written while the second member was still in the group and sealed after
    // the removal: who a message is for is read when its copies are made.
    final pending = await write('written before the removal');

    final removed =
        await MutateGroup(
          repository: groups,
          crypto: const _GroupCrypto(),
          identity: _Identity(900),
          clock: const _Clock(),
        )(
          groupId: group.groupId,
          actorUserId: _owner,
          actorDeviceId: _ownerDevice,
          operation: RemoveGroupMemberOperation(_second),
        );
    expect(removed, isA<Success<GroupState>>());

    // The removal is owed once to the member it removes, so that member learns
    // of it. It is the last thing that member is owed.
    final transcript =
        (await groups.readTranscript(group.groupId)
                as Success<List<StoredGroupControl>>)
            .value;
    final owed =
        (await groups.readPendingOutbound() as Success<List<GroupOutboundWork>>)
            .value;
    expect(
      owed
          .singleWhere(
            (work) =>
                work.operationId == 'group-control:${transcript.last.eventId}',
          )
          .recipientUserIds,
      contains(_second),
    );

    expect(await seal(pending), isA<Success<void>>());
    expect(await copiesOf(pending), [_memberPhone, _memberLaptop]);

    final later = await write('written after the removal');
    expect(await seal(later), isA<Success<void>>());
    expect(await copiesOf(later), [_memberPhone, _memberLaptop]);
    expect(
      (await database.select(database.outboxOperations).get()).map(
        (row) => row.recipientUserId,
      ),
      isNot(contains(_second)),
    );
  });
}

Future<GroupState> _create(
  DriftGroupRepository repository,
  List<String> members,
) async {
  final created =
      await CreateGroup(
            repository: repository,
            crypto: const _GroupCrypto(),
            identity: _Identity(800),
            clock: const _Clock(),
          )(
            currentUserId: _owner,
            currentDeviceId: _ownerDevice,
            ownerDisplayName: 'Owner',
            metadata: const GroupMetadata(name: 'Fan-out'),
            selectedMembers: [
              for (final member in members)
                GroupMember(
                  userId: member,
                  displayName: 'Member',
                  role: GroupRole.member,
                ),
            ],
          )
          as Success<GroupState>;
  return created.value;
}

VerifiedPairwiseLiveDevice _device(String userId, String deviceId) =>
    VerifiedPairwiseLiveDevice(
      userId: userId,
      device: PeerPublicDevice(
        deviceId: deviceId,
        identityPublic: _bytes(64, 1),
        registrationId: 1,
        bundleVersion: 1,
        crossSignature: _bytes(64, 2),
      ),
      selfSigningPublic: _bytes(32, 3),
    );

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));

Uint8List _hexBytes(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);

final class _Identity implements GroupIdentityPort {
  _Identity(this.seed);

  final int seed;
  var _issued = 0;

  @override
  Future<Result<Uint8List>> randomIdentifier() async {
    _issued += 1;
    return Result.success(
      Uint8List.fromList(
        List<int>.generate(
          16,
          (index) => (seed * 7 + _issued * 13 + index) & 0xff,
        ),
      ),
    );
  }
}

/// Stands in for the native signing operation. Nothing here opens what it
/// returns, so it only has to be stable and well formed.
final class _GroupCrypto implements GroupControlCryptoPort {
  const _GroupCrypto();

  @override
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event) async =>
      Result.success(
        SignedGroupControlEvent(
          event: event,
          controlStateHash: '${event.eventId}${event.eventId}',
          canonicalBytes: Uint8List.fromList(utf8.encode(event.eventId)),
          signature: Uint8List(SignedGroupControlEvent.signatureBytes),
        ),
      );

  @override
  Future<Result<SignedGroupControlEvent>> open({
    required GroupSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) => throw UnimplementedError();
}

final class _Resolver implements PairwiseLiveDeviceResolverPort {
  _Resolver(this.devices);

  final Map<String, List<VerifiedPairwiseLiveDevice>> devices;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async => Result.success(devices[userId]!);
}

final class _Claims implements PairwiseSelectiveClaimPort {
  const _Claims(this.resolver);

  final _Resolver resolver;

  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    final live = resolver.devices[userId]!;
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: live,
        claims: {
          for (final deviceId in deviceIds)
            deviceId: VerifiedPairwiseClaim(
              device: live.singleWhere((device) => device.deviceId == deviceId),
              bundle: ClaimedPrekeyBundle(
                deviceId: deviceId,
                registrationId: 1,
                identityPublic: _bytes(64, 1),
                signedPrekeyId: 1,
                signedPrekeyPublic: _bytes(32, 2),
                signedPrekeySignature: _bytes(64, 3),
                crossSignature: _bytes(64, 4),
                bundleVersion: 1,
                pqSignedPrekeyId: 2,
                pqSignedPrekeyPublic: _bytes(1184, 5),
                pqSignedPrekeySignature: _bytes(64, 6),
              ),
            ),
        },
      ),
    );
  }
}

/// Stands in for the reviewed native ratchet step and counts its calls, so a
/// copy that was encrypted twice shows up as an extra call.
final class _Crypto implements PairwiseOutboundPreparationPort {
  final calls = <String>[];

  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async {
    calls.add(recipient.deviceId);
    final marker = calls.length;
    return Result.success(
      PairwisePreparedOutbound(
        exactCiphertext: _bytes(1024, marker),
        sessionId: context.primary?.sessionId ?? _bytes(16, marker),
        nextOpaqueSessionState: _bytes(32, marker),
        nextSkippedKeyCount: 0,
        disposition: PairwiseSessionDisposition.primaryBidirectional,
      ),
    );
  }
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 9);
}
