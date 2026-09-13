import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/domain/local_storage_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_conversation_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDatabase database;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('initial schema contains every documented logical table', () async {
    await database.customSelect('SELECT 1').getSingle();
    expect(database.allTables.map((table) => table.actualTableName).toSet(), {
      'account_session',
      'secure_secrets',
      'account_identity',
      'enrollment_intent',
      'users',
      'profiles',
      'devices',
      'device_log',
      'device_log_mutations',
      'security_posture',
      'pairwise_sessions',
      'pairwise_session_alternates',
      'prekeys',
      'prekey_maintenance_plans',
      'mls_groups',
      'group_control_events',
      'group_outbound_objects',
      'conversations',
      'memberships',
      'messages',
      'message_events',
      'application_events',
      'application_event_targets',
      'unsupported_application_events',
      'application_sender_counters',
      'message_reactions',
      'pending_application_receipts',
      'attachments',
      'inbox_envelopes',
      'outbox_operations',
      'inbox_event_deduplication',
      'pairwise_replay_markers',
      'pairwise_opened_payloads',
      'pairwise_local_applications',
      'pending_send_preparations',
      'pairwise_consumed_prekeys',
      'stale_device_refresh_requests',
      'receipts',
      'voice_rooms',
      'history_transfers',
      'history_transfer_batches',
      'sync_checkpoint',
      'local_preferences',
      'quarantine',
    });
    expect(database.schemaVersion, LocalDatabase.currentSchemaVersion);
  });

  test(
    'database uniqueness and foreign-key constraints are authoritative',
    () async {
      await database
          .into(database.users)
          .insert(
            UsersCompanion.insert(
              userId: 'opaque-user-1',
              activated: true,
              directoryEntryCiphertext: Uint8List.fromList([1, 2, 3]),
              localState: 0,
            ),
          );
      await database
          .into(database.profiles)
          .insert(
            ProfilesCompanion.insert(
              userId: 'opaque-user-1',
              profileCiphertext: Uint8List.fromList([7, 8, 9]),
              version: 1,
              verificationState: 0,
            ),
          );
      await expectLater(
        database
            .into(database.profiles)
            .insert(
              ProfilesCompanion.insert(
                userId: 'missing-user',
                profileCiphertext: Uint8List.fromList([1]),
                version: 1,
                verificationState: 0,
              ),
            ),
        throwsA(anything),
      );

      await database
          .into(database.inboxEnvelopes)
          .insert(
            InboxEnvelopesCompanion.insert(
              envelopeId: 'envelope-a',
              sequence: 4,
              envelopeCiphertext: Uint8List.fromList([4, 4]),
              processingState: 0,
            ),
          );
      await expectLater(
        database
            .into(database.inboxEnvelopes)
            .insert(
              InboxEnvelopesCompanion.insert(
                envelopeId: 'envelope-b',
                sequence: 4,
                envelopeCiphertext: Uint8List.fromList([5, 5]),
                processingState: 0,
              ),
            ),
        throwsA(anything),
      );

      final recipient = OutboxOperationsCompanion.insert(
        operationId: 'operation-a',
        eventId: 'event-a',
        recipientDeviceId: 'device-a',
        batchIndex: 0,
        exactRecipientCiphertext: Uint8List.fromList([8, 8]),
        attemptState: 0,
      );
      await database.into(database.outboxOperations).insert(recipient);
      await expectLater(
        database.into(database.outboxOperations).insert(recipient),
        throwsA(anything),
      );
    },
  );

  test('authenticated event application is exactly once and atomic', () async {
    final repository = DriftConversationProjectionRepository(database);
    final event = _event();

    final first = await repository.applyAuthenticatedEvent(event);
    final duplicate = await repository.applyAuthenticatedEvent(event);

    expect(first, isA<Success<bool>>());
    expect((first as Success<bool>).value, isTrue);
    expect((duplicate as Success<bool>).value, isFalse);
    expect(await database.select(database.messageEvents).get(), hasLength(1));
    expect(await database.select(database.messages).get(), hasLength(1));
  });

  test('failed transaction publishes no partial reactive projection', () async {
    final emissions = <int>[];
    final committed = Completer<void>();
    final subscription = database.watchConversationRows().listen((rows) {
      emissions.add(rows.length);
      if (rows.length == 1 && !committed.isCompleted) committed.complete();
    });
    await pumpEventQueue();
    expect(emissions, [0]);

    await expectLater(
      database.writeTransaction<void>(() async {
        await database
            .into(database.conversations)
            .insert(
              ConversationsCompanion.insert(
                conversationId: 'rolled-back',
                kind: 0,
                listProjectionCiphertext: Uint8List.fromList([1, 9]),
                sortKey: 1,
              ),
            );
        throw StateError('fault injection');
      }),
      throwsStateError,
    );
    await pumpEventQueue();
    expect(emissions, isNotEmpty);
    expect(emissions, everyElement(0));

    await database
        .into(database.conversations)
        .insert(
          ConversationsCompanion.insert(
            conversationId: 'committed',
            kind: 0,
            listProjectionCiphertext: Uint8List.fromList([2, 9]),
            sortKey: 2,
          ),
        );
    await committed.future.timeout(const Duration(seconds: 2));
    expect(emissions.last, 1);
    expect(emissions.where((count) => count > 0), [1]);
    await subscription.cancel();
  });
}

StoredMessageEvent _event() {
  return StoredMessageEvent(
    eventId: 'event-1',
    messageId: 'message-1',
    conversationId: 'conversation-1',
    eventKind: 0,
    authenticatedCiphertext: Uint8List.fromList([90, 91, 92]),
    messageStatus: 0,
    revision: 0,
    createdAt: DateTime.utc(2026, 7, 27),
    conversationKind: 0,
    conversationProjectionCiphertext: Uint8List.fromList([80, 81]),
    sortKey: 1,
  );
}
