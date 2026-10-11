import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/attachment_descriptor_fixture.dart';
import '../../support/local_send_harness.dart';

/// ADR-089 D9: the database keeps `queued`, `ready` and `expired`, and a cache
/// id and an expiry with `ready` only.
void main() {
  late LocalDatabase database;
  late DriftAttachmentLocalState store;
  final capability = testCapability(1);
  const cacheId = '00112233445566778899aabbccddeeff';
  final expiresAt = DateTime.utc(2026, 10, 17, 9, 30);

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftAttachmentLocalState(database);
    await applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(1),
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        counter: 1,
        body: MessageCreateBody(
          messageId: sequentialId(100),
          text: '',
          contentType: MessageContentType.attachment,
          attachments: [
            testAttachmentDescriptor(
              capability: capability,
              displayName: 'minutes.pdf',
              mimeType: 'application/pdf',
            ),
          ],
        ),
      ),
    );
  });

  tearDown(() => database.close());

  Future<AttachmentLocalState?> read(String id) async =>
      (await store.read(id) as Success<AttachmentLocalState?>).value;

  Future<List<CachedAttachmentEntry>> cached() async =>
      (await store.listCached() as Success<List<CachedAttachmentEntry>>).value;

  Future<Attachment> row() => (database.select(
    database.attachments,
  )..where((row) => row.attachmentId.equals(capability))).getSingle();

  Future<void> setRaw(AttachmentsCompanion values) async {
    await (database.update(
      database.attachments,
    )..where((row) => row.attachmentId.equals(capability))).write(values);
  }

  test(
    'reads the message, the descriptor and a not-downloaded state',
    () async {
      final state = (await read(capability))!;

      expect(state.messageId, protocolBytesToHex(sequentialId(100)));
      expect(state.descriptor.capabilityId, capability);
      expect(state.descriptor.displayName, 'minutes.pdf');
      expect(state.state, AttachmentTransferState.queued);
      expect(state.cacheId, isNull);
      expect(state.expiresAt, isNull);
      expect(await read(testCapability(2)), isNull);
    },
  );

  test('marks a file cached, moves its expiry, and clears it again', () async {
    expect(
      await store.markCached(
        attachmentId: capability,
        cacheId: cacheId,
        expiresAt: expiresAt,
      ),
      isA<Success<void>>(),
    );
    var stored = await row();
    expect(stored.transferState, AttachmentTransferState.ready.index);
    expect(utf8.decode(stored.boundedCacheHandleCiphertext!), cacheId);
    var state = (await read(capability))!;
    expect(state.state, AttachmentTransferState.ready);
    expect(state.cacheId, cacheId);
    expect(state.expiresAt, expiresAt);
    expect(state.expiresAt!.isUtc, isTrue);

    final later = expiresAt.add(const Duration(days: 2));
    expect(
      await store.touch(attachmentId: capability, expiresAt: later),
      isA<Success<void>>(),
    );
    expect((await read(capability))!.expiresAt, later);

    expect(await store.clearCache(capability), isA<Success<void>>());
    stored = await row();
    expect(stored.transferState, AttachmentTransferState.queued.index);
    expect(stored.boundedCacheHandleCiphertext, isNull);
    expect(stored.cacheExpiresAt, isNull);

    expect(
      await store.touch(attachmentId: capability, expiresAt: later),
      _conflict,
      reason: 'only a cached file has an expiry to move',
    );

    await store.markCached(
      attachmentId: capability,
      cacheId: cacheId,
      expiresAt: expiresAt,
    );
    expect(await store.markExpired(capability), isA<Success<void>>());
    stored = await row();
    expect(stored.transferState, AttachmentTransferState.expired.index);
    expect(stored.boundedCacheHandleCiphertext, isNull);
    expect(stored.cacheExpiresAt, isNull);
    state = (await read(capability))!;
    expect(state.state, AttachmentTransferState.expired);
  });

  test('a write that needs the row fails without one, and one that takes a '
      'file away succeeds', () async {
    final missing = testCapability(2);

    expect(
      await store.markCached(
        attachmentId: missing,
        cacheId: cacheId,
        expiresAt: expiresAt,
      ),
      _conflict,
    );
    expect(
      await store.touch(attachmentId: missing, expiresAt: expiresAt),
      _conflict,
    );
    expect(await store.clearCache(missing), isA<Success<void>>());
    expect(await store.markExpired(missing), isA<Success<void>>());
  });

  test('refuses every state other than queued, ready and expired', () async {
    final refused = AttachmentTransferState.values.toSet().difference(
      persistedAttachmentStates,
    );
    expect(refused, hasLength(10));

    for (final state in refused) {
      expect(
        () => store.write(capability, state: state),
        throwsArgumentError,
        reason: state.name,
      );
      expect(
        () => store.write(
          capability,
          state: state,
          cacheId: cacheId,
          expiresAt: expiresAt,
        ),
        throwsArgumentError,
        reason: state.name,
      );
    }
    // A cache id and an expiry go with `ready`, and only with it.
    expect(
      () => store.write(capability, state: AttachmentTransferState.ready),
      throwsArgumentError,
    );
    expect(
      () => store.write(
        capability,
        state: AttachmentTransferState.queued,
        cacheId: cacheId,
        expiresAt: expiresAt,
      ),
      throwsArgumentError,
    );
    expect(
      () => store.markCached(
        attachmentId: capability,
        cacheId: capability,
        expiresAt: expiresAt,
      ),
      throwsArgumentError,
      reason: 'a capability is not a cache id',
    );

    final stored = await row();
    expect(stored.transferState, AttachmentTransferState.queued.index);
    expect(stored.boundedCacheHandleCiphertext, isNull);
  });

  test('a row that claims more than it holds reads as not downloaded, and '
      'lists with no claim', () async {
    await setRaw(
      AttachmentsCompanion(
        transferState: Value(AttachmentTransferState.ready.index),
        boundedCacheHandleCiphertext: Value(
          Uint8List.fromList(utf8.encode('not-a-cache-id')),
        ),
        cacheExpiresAt: Value(expiresAt),
      ),
    );
    expect((await read(capability))!.state, AttachmentTransferState.queued);
    var listed = await cached();
    expect(listed.single.attachmentId, capability);
    expect(listed.single.cacheId, isNull);
    expect(listed.single.expiresAt, isNull);

    // A state another build may have written, which this one does not keep.
    await setRaw(
      AttachmentsCompanion(
        transferState: Value(AttachmentTransferState.sending.index),
        boundedCacheHandleCiphertext: const Value(null),
        cacheExpiresAt: const Value(null),
      ),
    );
    expect((await read(capability))!.state, AttachmentTransferState.queued);
    listed = await cached();
    expect(listed, isEmpty);

    await store.markCached(
      attachmentId: capability,
      cacheId: cacheId,
      expiresAt: expiresAt,
    );
    listed = await cached();
    expect(listed.single.cacheId, cacheId);
    expect(listed.single.expiresAt, expiresAt);
  });

  test('says nothing about an attachment when printed', () async {
    await store.markCached(
      attachmentId: capability,
      cacheId: cacheId,
      expiresAt: expiresAt,
    );
    final printed = [
      (await read(capability)).toString(),
      (await cached()).single.toString(),
    ].join('\n');

    for (final secret in [capability, cacheId, 'minutes', 'pdf']) {
      expect(printed, isNot(contains(secret)));
    }
  });
}

final _conflict = isA<FailureResult<void>>().having(
  (result) => result.failure,
  'failure',
  isA<ValidationFailure>().having(
    (failure) => failure.kind,
    'kind',
    ValidationFailureKind.conflict,
  ),
);
