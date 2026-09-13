import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temporaryDirectory;
  late File databaseFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'local-db-migration-',
    );
    databaseFile = File('${temporaryDirectory.path}/representative.sqlite');
    final legacy = sqlite3.open(databaseFile.path)
      ..execute('CREATE TABLE legacy_marker (value TEXT NOT NULL)')
      ..execute("INSERT INTO legacy_marker VALUES ('recoverable')")
      ..execute('PRAGMA user_version = 0');
    legacy.close();
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'initial migration upgrades a representative version-zero database',
    () async {
      final database = LocalDatabase(NativeDatabase(databaseFile));

      await database.customSelect('SELECT 1').getSingle();

      expect(
        await database.customSelect('SELECT * FROM legacy_marker').get(),
        hasLength(1),
      );
      expect(
        await database
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await database.close();
    },
  );

  test(
    'version-one upgrade preserves data and adds the enrollment journal',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.customStatement(
        "INSERT INTO local_preferences "
        "(preference_key, value_ciphertext, value_version) "
        "VALUES ('preserved', X'010203', 1)",
      );
      await current.close();

      final versionOne = sqlite3.open(databaseFile.path)
        ..execute('DROP TABLE enrollment_intent')
        ..execute('DROP TABLE inbox_event_deduplication')
        ..execute('DROP TABLE stale_device_refresh_requests')
        ..execute('DROP TABLE pairwise_session_alternates')
        ..execute('DROP TABLE pairwise_replay_markers')
        ..execute('DROP TABLE pairwise_opened_payloads')
        ..execute('DROP TABLE pairwise_local_applications')
        ..execute('DROP TABLE pairwise_consumed_prekeys')
        ..execute('DROP TABLE prekey_maintenance_plans')
        ..execute('ALTER TABLE secure_secrets DROP COLUMN state_revision')
        ..execute(
          'ALTER TABLE devices DROP COLUMN last_signed_prekey_rotation_unix_day',
        )
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN remote_user_id')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN session_id')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN skipped_key_count')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN disposition')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN repair_state')
        ..execute(
          'ALTER TABLE pairwise_sessions DROP COLUMN repair_authorization',
        )
        ..execute(
          'ALTER TABLE pairwise_sessions DROP COLUMN last_authenticated_at',
        )
        ..execute('ALTER TABLE inbox_envelopes DROP COLUMN opaque_event_id')
        ..execute('ALTER TABLE inbox_envelopes DROP COLUMN dependency_class')
        ..execute('ALTER TABLE inbox_envelopes DROP COLUMN attempt_count')
        ..execute('ALTER TABLE inbox_envelopes DROP COLUMN next_attempt_at')
        ..execute('ALTER TABLE outbox_operations DROP COLUMN recipient_user_id')
        ..execute('ALTER TABLE outbox_operations DROP COLUMN next_attempt_at')
        ..execute('ALTER TABLE outbox_operations DROP COLUMN last_attempt_at')
        ..execute('ALTER TABLE outbox_operations DROP COLUMN terminal_at')
        ..execute('ALTER TABLE sync_checkpoint DROP COLUMN queue_gap_state')
        ..execute('ALTER TABLE sync_checkpoint DROP COLUMN drain_requested')
        ..execute('ALTER TABLE sync_checkpoint DROP COLUMN connection_phase')
        ..execute('ALTER TABLE sync_checkpoint DROP COLUMN reconnect_attempt')
        ..execute('ALTER TABLE sync_checkpoint DROP COLUMN reconnect_at')
        ..execute(
          'ALTER TABLE sync_checkpoint DROP COLUMN last_successful_sync_at',
        );
      _dropPieceFourteenSchema(versionOne);
      _dropPieceEighteenSchema(versionOne);
      versionOne.execute('PRAGMA user_version = 1');
      versionOne.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));
      await upgraded.customSelect('SELECT 1').getSingle();

      expect(
        await upgraded
            .customSelect(
              "SELECT preference_key FROM local_preferences "
              "WHERE preference_key = 'preserved'",
            )
            .getSingle(),
        isNotNull,
      );
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name = 'inbox_event_deduplication'",
            )
            .getSingle(),
        isNotNull,
      );
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE type = 'table' AND name = 'enrollment_intent'",
            )
            .getSingle(),
        isNotNull,
      );
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );

  test(
    'version-three upgrade adds bounded pairwise transaction state',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.customStatement(
        "INSERT INTO pairwise_sessions "
        "(local_device_id, remote_device_id, opaque_crypto_state_handle, "
        "state_version) VALUES "
        "('00000000-0000-0000-0000-000000000001', "
        "'00000000-0000-0000-0000-000000000002', X'01', 1)",
      );
      await current.close();

      final versionThree = sqlite3.open(databaseFile.path)
        ..execute('DROP TABLE pairwise_session_alternates')
        ..execute('DROP TABLE pairwise_replay_markers')
        ..execute('DROP TABLE pairwise_opened_payloads')
        ..execute('DROP TABLE pairwise_local_applications')
        ..execute('DROP TABLE pairwise_consumed_prekeys')
        ..execute('DROP TABLE prekey_maintenance_plans')
        ..execute('ALTER TABLE secure_secrets DROP COLUMN state_revision')
        ..execute(
          'ALTER TABLE devices DROP COLUMN last_signed_prekey_rotation_unix_day',
        )
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN remote_user_id')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN session_id')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN skipped_key_count')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN disposition')
        ..execute('ALTER TABLE pairwise_sessions DROP COLUMN repair_state')
        ..execute(
          'ALTER TABLE pairwise_sessions DROP COLUMN repair_authorization',
        )
        ..execute(
          'ALTER TABLE pairwise_sessions DROP COLUMN last_authenticated_at',
        );
      _dropPieceFourteenSchema(versionThree);
      _dropPieceEighteenSchema(versionThree);
      versionThree.execute('PRAGMA user_version = 3');
      versionThree.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));
      await upgraded.customSelect('SELECT 1').getSingle();

      final legacy = await upgraded
          .customSelect(
            'SELECT session_id, skipped_key_count, repair_state '
            'FROM pairwise_sessions',
          )
          .getSingle();
      expect(legacy.data['session_id'], isNull);
      expect(legacy.read<int>('skipped_key_count'), 0);
      expect(legacy.read<int>('repair_state'), 0);
      for (final table in const [
        'pairwise_session_alternates',
        'pairwise_replay_markers',
        'pairwise_opened_payloads',
        'pairwise_local_applications',
        'pairwise_consumed_prekeys',
        'prekey_maintenance_plans',
      ]) {
        expect(
          await upgraded
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                "AND name = '$table'",
              )
              .getSingle(),
          isNotNull,
        );
      }
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );

  test(
    'failed migration rolls back and leaves the old database recoverable',
    () async {
      final database = LocalDatabase(
        NativeDatabase(databaseFile),
        migrationHooks: _FailAfterSchemaCreation(),
      );

      await expectLater(
        database.customSelect('SELECT 1').getSingle(),
        throwsA(anything),
      );
      await database.close();

      final recovered = sqlite3.open(databaseFile.path);
      final marker = recovered
          .select('SELECT value FROM legacy_marker')
          .single['value'];
      final newTables = recovered.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages'",
      );
      final version = recovered
          .select('PRAGMA user_version')
          .single['user_version'];
      recovered.close();

      expect(marker, 'recoverable');
      expect(newTables, isEmpty);
      expect(version, 0);
    },
  );

  test('version-five upgrade adds piece-fifteen local flags safely', () async {
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.customStatement(
      "INSERT INTO conversations "
      "(conversation_id, kind, list_projection_ciphertext, sort_key) "
      "VALUES ('conversation', 0, X'01', 1)",
    );
    await current.customStatement(
      "INSERT INTO messages "
      "(message_id, conversation_id, current_event_id, "
      "projection_ciphertext, status, revision, created_at) "
      "VALUES ('message', 'conversation', 'event', X'01', 0, 0, 0)",
    );
    await current.close();

    final versionFive = sqlite3.open(databaseFile.path)
      ..execute('ALTER TABLE conversations DROP COLUMN pinned')
      ..execute('ALTER TABLE messages DROP COLUMN starred');
    _dropPieceEighteenSchema(versionFive);
    versionFive.execute('PRAGMA user_version = 5');
    versionFive.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));
    final row = await upgraded
        .customSelect(
          "SELECT starred FROM messages WHERE message_id = 'message'",
        )
        .getSingle();
    expect(row.read<int>('starred'), 0);
    final conversation = await upgraded
        .customSelect(
          "SELECT pinned FROM conversations "
          "WHERE conversation_id = 'conversation'",
        )
        .getSingle();
    expect(conversation.read<int>('pinned'), 0);
    await upgraded.close();
  });

  test(
    'version-eight upgrade preserves data and adds no KeyPackage table',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.customStatement(
        "INSERT INTO local_preferences "
        "(preference_key, value_ciphertext, value_version) "
        "VALUES ('piece-19-preserved', X'09', 1)",
      );
      await current.close();

      // Schema 9 added only the KeyPackage maintenance table, and this build no
      // longer creates it, so nothing has to be taken away before the database
      // is stamped back to 8.
      final versionEight = sqlite3.open(databaseFile.path)
        ..execute('PRAGMA user_version = 8');
      versionEight.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));
      await upgraded.customSelect('SELECT 1').getSingle();

      expect(
        await upgraded
            .customSelect(
              "SELECT preference_key FROM local_preferences "
              "WHERE preference_key = 'piece-19-preserved'",
            )
            .getSingle(),
        isNotNull,
      );
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name = 'mls_key_package_maintenance_states'",
            )
            .get(),
        isEmpty,
      );
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );

  // Schema 12 adds the durable one-shot alert marker. An upgrade must leave
  // every existing message unalerted rather than alerted: a marker fabricated
  // as spent would silence the first message an upgraded install receives,
  // while an unspent marker on an old message costs at most one alert saying
  // something is waiting, which is true.
  test('version-eleven upgrade adds an unspent alert marker', () async {
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.close();

    final versionEleven = sqlite3.open(databaseFile.path)
      ..execute('ALTER TABLE messages DROP COLUMN alerted')
      ..execute(
        'INSERT INTO conversations (conversation_id, kind, '
        'list_projection_ciphertext, sort_key) VALUES (?, ?, ?, ?)',
        <Object?>[
          'conversation-v11',
          0,
          Uint8List.fromList(const [1]),
          0,
        ],
      )
      ..execute(
        'INSERT INTO messages (message_id, conversation_id, current_event_id, '
        'projection_ciphertext, status, revision, created_at, unread) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'message-v11',
          'conversation-v11',
          'event-v11',
          Uint8List.fromList(const [2]),
          4,
          0,
          0,
          1,
        ],
      )
      ..execute('PRAGMA user_version = 11');
    versionEleven.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));
    final row = await upgraded
        .customSelect("SELECT * FROM messages WHERE message_id = 'message-v11'")
        .getSingle();

    expect(row.read<int>('alerted'), 0);
    expect(
      row.read<int>('unread'),
      1,
      reason: 'the upgrade adds a column and rewrites no projection',
    );
    expect(
      await upgraded
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle(),
      LocalDatabase.currentSchemaVersion,
    );
    await upgraded.close();
  });

  test(
    'version-fifteen upgrade adds the owed-send queue and nothing else',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.close();

      final versionFifteen = sqlite3.open(databaseFile.path)
        ..execute('DROP TABLE pending_send_preparations')
        ..execute(
          'INSERT INTO conversations (conversation_id, kind, '
          'list_projection_ciphertext, sort_key, tombstoned, pinned, '
          'unread_count) VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'conversation-v15',
            0,
            Uint8List.fromList(const [1]),
            0,
            0,
            0,
            0,
          ],
        )
        ..execute(
          'INSERT INTO messages (message_id, conversation_id, current_event_id, '
          'projection_ciphertext, status, revision, created_at, unread) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'message-v15',
            'conversation-v15',
            'event-v15',
            Uint8List.fromList(const [2]),
            3,
            0,
            0,
            0,
          ],
        )
        ..execute('PRAGMA user_version = 15');
      versionFifteen.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));

      expect(
        await upgraded.select(upgraded.pendingSendPreparations).get(),
        isEmpty,
      );
      final message = await upgraded
          .customSelect(
            "SELECT * FROM messages WHERE message_id = 'message-v15'",
          )
          .getSingle();
      // Nothing is back-filled and nothing is repaired: every message already on
      // a device either has its outbox rows or has reached a terminal state, so
      // there is no send this table would have been holding.
      expect(message.read<int>('status'), 3);
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );

  test(
    'version-sixteen upgrade indexes a populated database without moving a row',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.close();

      final versionSixteen = sqlite3.open(databaseFile.path);
      _dropPhaseTwoIndexes(versionSixteen);
      versionSixteen
        ..execute(
          'INSERT INTO conversations (conversation_id, kind, '
          'list_projection_ciphertext, sort_key, tombstoned, pinned, '
          'unread_count) VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'conversation-v16',
            0,
            Uint8List.fromList(const [1]),
            42,
            0,
            0,
            1,
          ],
        )
        ..execute('PRAGMA user_version = 16');
      for (var index = 0; index < 64; index += 1) {
        versionSixteen
          ..execute(
            'INSERT INTO messages (message_id, conversation_id, '
            'current_event_id, projection_ciphertext, status, revision, '
            'created_at, ordering_ms, ordering_event_id, pinned, unread) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'message-v16-$index',
              'conversation-v16',
              'event-v16-$index',
              Uint8List.fromList(const [2]),
              3,
              0,
              index,
              1700000000000 + index,
              'event-v16-$index',
              index == 7 ? 1 : 0,
              index == 63 ? 1 : 0,
            ],
          )
          ..execute(
            'INSERT INTO attachments (attachment_id, message_id, '
            'encrypted_descriptor, transfer_state) VALUES (?, ?, ?, ?)',
            <Object?>[
              'attachment-v16-$index',
              'message-v16-$index',
              Uint8List.fromList(const [3]),
              0,
            ],
          );
      }
      versionSixteen.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));
      await upgraded.customSelect('SELECT 1').getSingle();

      // Every index this schema declares now exists, by name, on the table it
      // names. `CREATE INDEX` is the whole of the upgrade: no table is dropped,
      // re-keyed or rewritten.
      final indexes = await upgraded
          .customSelect(
            "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' "
            "AND name NOT LIKE 'sqlite_autoindex%'",
          )
          .map(
            (row) =>
                '${row.read<String>('name')} on ${row.read<String>('tbl_name')}',
          )
          .get();
      expect(indexes, <String>{
        'messages_conversation_ordering on messages',
        'messages_pinned_by_conversation on messages',
        'messages_unread_by_conversation on messages',
        'application_events_conversation_apply_state on application_events',
        'application_events_sender_counter on application_events',
        'attachments_by_message on attachments',
        'outbox_operations_by_event on outbox_operations',
      });

      // And every row is exactly the row it was.
      final messages = await upgraded
          .customSelect(
            "SELECT * FROM messages WHERE conversation_id = 'conversation-v16' "
            'ORDER BY ordering_ms ASC',
          )
          .get();
      expect(messages, hasLength(64));
      expect(messages.first.read<String>('message_id'), 'message-v16-0');
      expect(messages.last.read<int>('unread'), 1);
      expect(
        messages
            .where((row) => row.read<int>('pinned') == 1)
            .single
            .read<String>('message_id'),
        'message-v16-7',
      );
      expect(
        await upgraded
            .customSelect('SELECT COUNT(*) AS total FROM attachments')
            .map((row) => row.read<int>('total'))
            .getSingle(),
        64,
      );
      expect(
        await upgraded
            .customSelect(
              "SELECT sort_key FROM conversations "
              "WHERE conversation_id = 'conversation-v16'",
            )
            .map((row) => row.read<int>('sort_key'))
            .getSingle(),
        42,
      );
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      // Idempotent, because the declaration carries `IF NOT EXISTS`: a
      // database that already holds these indexes re-runs the step cleanly.
      expect(
        await upgraded.customSelect('PRAGMA quick_check').getSingle(),
        isNotNull,
      );
      await upgraded.close();
    },
  );

  test(
    'version-seventeen upgrade indexes the history a device already holds',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.close();

      final versionSeventeen = sqlite3.open(databaseFile.path);
      _dropPhaseThreeSchema(versionSeventeen);
      versionSeventeen
        ..execute(
          'INSERT INTO conversations (conversation_id, kind, '
          'list_projection_ciphertext, sort_key, tombstoned, pinned, '
          'peer_user_id, unread_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            _conversationV17,
            0,
            Uint8List.fromList(const [1]),
            1700000000002,
            0,
            0,
            _peerV17,
            0,
          ],
        )
        ..execute('PRAGMA user_version = 17');
      for (var index = 0; index < 3; index += 1) {
        final messageId = _messageV17(index);
        versionSeventeen
          ..execute(
            'INSERT INTO messages (message_id, conversation_id, '
            'current_event_id, projection_ciphertext, status, revision, '
            'created_at, sender_user_id, sender_device_id, ordering_ms, '
            'ordering_event_id, delivered_receipt_sent) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              messageId,
              _conversationV17,
              messageId,
              Uint8List.fromList('old $index'.codeUnits),
              5,
              0,
              1700000000,
              _peerV17,
              _peerDeviceV17,
              1700000000000 + index,
              messageId,
              1,
            ],
          )
          // The create, whose message id lives inside the projected body and
          // nowhere else. This is the row the back-fill has to decode: without
          // it, an edit arriving after the upgrade would fold the edit alone
          // and find no message to edit.
          ..execute(
            'INSERT INTO application_events (event_id, conversation_id, kind, '
            'sender_user_id, sender_device_id, sender_counter, created_ms, '
            'ordering_ms, canonical_event, body_projection, apply_state, '
            'local_origin, local_device_id) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              messageId,
              _conversationV17,
              1,
              _peerV17,
              _peerDeviceV17,
              index + 1,
              1700000000000 + index,
              1700000000000 + index,
              Uint8List.fromList(const [9]),
              Uint8List.fromList(
                utf8.encode(
                  jsonEncode(<String, Object?>{
                    'message_id': messageId,
                    'text': 'old $index',
                    'content_type': 0,
                    'attachments': <Object?>[],
                    'reply_to': null,
                    'quote': null,
                    'references': <Object?>[],
                  }),
                ),
              ),
              0,
              0,
              '',
            ],
          );
      }
      // A pin, whose target is already a column, and a receipt naming all
      // three, whose targets are a list. The two shapes the back-fill has to
      // recognise, and the one kind it can read straight out of SQL.
      versionSeventeen
        ..execute(
          'INSERT INTO application_events (event_id, conversation_id, kind, '
          'sender_user_id, sender_device_id, sender_counter, created_ms, '
          'ordering_ms, canonical_event, body_projection, apply_state, '
          'target_message_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'pin-v17',
            _conversationV17,
            5,
            _peerV17,
            _peerDeviceV17,
            4,
            1700000000010,
            1700000000010,
            Uint8List.fromList(const [9]),
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'target': _messageV17(0),
                  'pinned': true,
                  'references': <Object?>[_messageV17(0)],
                }),
              ),
            ),
            0,
            _messageV17(0),
          ],
        )
        ..execute(
          'INSERT INTO application_events (event_id, conversation_id, kind, '
          'sender_user_id, sender_device_id, sender_counter, created_ms, '
          'ordering_ms, canonical_event, body_projection, apply_state) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'receipt-v17',
            _conversationV17,
            7,
            _localV17,
            _localDeviceV17,
            1,
            1700000000011,
            1700000000011,
            Uint8List.fromList(const [9]),
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'message_ids': [
                    for (var index = 0; index < 3; index += 1)
                      _messageV17(index),
                  ],
                  'references': [
                    for (var index = 0; index < 3; index += 1)
                      _messageV17(index),
                  ],
                }),
              ),
            ),
            0,
          ],
        );
      versionSeventeen.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));
      await upgraded.customSelect('SELECT 1').getSingle();

      // Every stored event now has its targets beside it: one per create, one
      // for the pin, three for the receipt.
      final targets = await upgraded
          .customSelect(
            'SELECT message_id, event_id FROM application_event_targets '
            'ORDER BY event_id, message_id',
          )
          .map(
            (row) =>
                '${row.read<String>('event_id')} -> '
                '${row.read<String>('message_id')}',
          )
          .get();
      expect(targets, <String>{
        for (var index = 0; index < 3; index += 1)
          '${_messageV17(index)} -> ${_messageV17(index)}',
        'pin-v17 -> ${_messageV17(0)}',
        for (var index = 0; index < 3; index += 1)
          'receipt-v17 -> ${_messageV17(index)}',
      });
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND name = 'messages_unread_by_conversation'",
            )
            .get(),
        hasLength(1),
      );

      // And nothing else moved. The step adds a table and an index; it rewrites
      // no row and it does not project.
      final messages = await upgraded
          .customSelect('SELECT * FROM messages ORDER BY ordering_ms ASC')
          .get();
      expect(messages, hasLength(3));
      expect(
        messages.first.read<Uint8List>('projection_ciphertext'),
        Uint8List.fromList('old 0'.codeUnits),
      );
      expect(messages.first.read<int>('status'), 5);
      expect(messages.every((row) => row.read<int>('pinned') == 0), isTrue);
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      expect(
        await upgraded.customSelect('PRAGMA quick_check').getSingle(),
        isNotNull,
      );

      // The point of the back-fill, end to end: an edit arriving after the
      // upgrade folds against a create this device stored before it. Without
      // the index rows the fold would see the edit alone, find no message to
      // edit, and quietly drop it.
      await upgraded.writeTransaction(
        () => DriftApplicationEventProjector(upgraded).applyInsideTransaction(
          ApplicationEventCommit(
            event: ApplicationEventRecord(
              version: ApplicationMessageProtocolV1.version,
              eventId: _bytesV17('11111111111111111111111111111111'),
              conversationId: _bytesV17(_conversationV17),
              kindValue: ApplicationEventKind.messageEdit.wireValue,
              senderUserId: protocolUuidBytes(_peerV17),
              senderDeviceId: protocolUuidBytes(_peerDeviceV17),
              senderCounter: 5,
              createdMs: 1700000000020,
              references: [_bytesV17(_messageV17(0))],
              body: MessageEditBody(
                targetMessageId: _bytesV17(_messageV17(0)),
                replacementText: 'edited after the upgrade',
                revision: 2,
              ),
            ),
            canonicalBytes: Uint8List.fromList(const [7, 7, 7]),
            currentUserId: _localV17,
            currentDeviceId: _localDeviceV17,
            conversationKind: 0,
            peerUserId: _peerV17,
            localOrigin: false,
            authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
              1700000100000,
              isUtc: true,
            ),
          ),
        ),
      );
      final edited = await upgraded
          .customSelect(
            'SELECT projection_ciphertext, pinned FROM messages '
            'WHERE message_id = ?',
            variables: [Variable<String>(_messageV17(0))],
          )
          .getSingle();
      expect(
        utf8.decode(edited.read<Uint8List>('projection_ciphertext')),
        'edited after the upgrade',
      );
      // And the pin stored before the upgrade came back with it, which is the
      // whole fact set for that message and not only the event just applied.
      expect(edited.read<int>('pinned'), 1);

      await upgraded.close();
    },
  );

  test('version-eighteen upgrade drops the activity day it stored', () async {
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.close();

    // A device at 18 has the column, because every build up to this one
    // created it. This build does not, so it has to be put back before the
    // step has anything to drop.
    final versionEighteen = sqlite3.open(databaseFile.path)
      ..execute('ALTER TABLE devices ADD COLUMN last_active_date TEXT NULL')
      ..execute(
        'INSERT INTO users (user_id, activated, '
        'directory_entry_ciphertext, local_state) VALUES (?, ?, ?, ?)',
        <Object?>[
          _userV19,
          1,
          Uint8List.fromList(const [1]),
          0,
        ],
      )
      ..execute(
        'INSERT INTO devices (device_id, user_id, public_bundle, '
        'revocation_state, created_date, last_active_date, is_current_device, '
        'owner_listing) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          _deviceV19,
          _userV19,
          Uint8List.fromList(const [2]),
          0,
          '2026-08-01',
          '2026-09-02',
          1,
          1,
        ],
      )
      ..execute('PRAGMA user_version = 18');
    versionEighteen.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));

    final columns = await upgraded
        .customSelect('PRAGMA table_info("devices")')
        .map((row) => row.read<String>('name'))
        .get();
    expect(columns, isNot(contains('last_active_date')));
    // The rest of the row is untouched: the drop is one column, not a rewrite
    // of what identifies a device.
    final device = await upgraded
        .customSelect(
          'SELECT * FROM devices WHERE device_id = ?',
          variables: [Variable<String>(_deviceV19)],
        )
        .getSingle();
    expect(device.read<String>('created_date'), '2026-08-01');
    expect(device.read<int>('is_current_device'), 1);
    expect(
      await upgraded
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle(),
      LocalDatabase.currentSchemaVersion,
    );
    await upgraded.close();
  });

  test('the drop tolerates a database that never had the column', () async {
    // A development build that already took this change and was then stamped
    // back reaches the step with nothing to drop. `createAll` no longer makes
    // the column, so this is the shape the check exists for, and an upgrade
    // that failed here would leave the application unable to open its storage.
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.close();

    final stampedBack = sqlite3.open(databaseFile.path)
      ..execute('PRAGMA user_version = 18');
    stampedBack.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));

    final columns = await upgraded
        .customSelect('PRAGMA table_info("devices")')
        .map((row) => row.read<String>('name'))
        .get();
    expect(columns, isNot(contains('last_active_date')));
    expect(
      await upgraded
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle(),
      LocalDatabase.currentSchemaVersion,
    );
    await upgraded.close();
  });

  test(
    'version-nineteen upgrade drops the KeyPackage maintenance table',
    () async {
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.customStatement(
        "INSERT INTO local_preferences "
        "(preference_key, value_ciphertext, value_version) "
        "VALUES ('schema-20-preserved', X'14', 1)",
      );
      await current.close();

      // A closed-beta device at 19 has the table and may hold a row in it.
      // This build no longer creates it, so it is put back the way schema 9
      // made it before the step has anything to drop.
      final versionNineteen = sqlite3.open(databaseFile.path)
        ..execute(_keyPackageMaintenanceTableV19)
        ..execute(
          'INSERT INTO mls_key_package_maintenance_states '
          '(device_id, stage, planned_kind, exact_upload_projection) '
          'VALUES (?, ?, ?, ?)',
          <Object?>[
            _deviceV19,
            1,
            0,
            Uint8List.fromList(const [4]),
          ],
        )
        ..execute('PRAGMA user_version = 19');
      versionNineteen.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));

      // The table and its primary-key index both go.
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE tbl_name = 'mls_key_package_maintenance_states'",
            )
            .get(),
        isEmpty,
      );
      // One table, not a rewrite of what sat beside it.
      expect(
        await upgraded
            .customSelect(
              "SELECT preference_key FROM local_preferences "
              "WHERE preference_key = 'schema-20-preserved'",
            )
            .get(),
        hasLength(1),
      );
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );

  test('the table drop tolerates a database that never had it', () async {
    // A database this build created and something stamped back to 19 has no
    // table, because `createAll` no longer makes one. An upgrade that failed
    // here would leave the application unable to open its storage.
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.close();

    final stampedBack = sqlite3.open(databaseFile.path)
      ..execute('PRAGMA user_version = 19');
    stampedBack.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));

    expect(
      await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE tbl_name = 'mls_key_package_maintenance_states'",
          )
          .get(),
      isEmpty,
    );
    expect(
      await upgraded
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle(),
      LocalDatabase.currentSchemaVersion,
    );
    await upgraded.close();
  });

  test('version-twenty-one upgrade replaces the MLS group tables', () async {
    final current = LocalDatabase(NativeDatabase(databaseFile));
    await current.customSelect('SELECT 1').getSingle();
    await current.close();

    // The group tables are put back the way schema 21 made them, holding a
    // group only the MLS stack could have written: a conversation, a queued
    // MLS object, and an envelope held back for a re-admission.
    final versionTwentyOne = sqlite3.open(databaseFile.path)
      ..execute('DROP TABLE group_state_requests')
      ..execute('DROP TABLE group_outbound_objects')
      ..execute('DROP TABLE group_control_events')
      ..execute('DROP TABLE group_states')
      ..execute(_mlsGroupsTableV21)
      ..execute(_groupControlEventsTableV21)
      ..execute(_groupOutboundObjectsTableV21)
      ..execute(_membershipsTableV21)
      ..execute(
        'INSERT INTO mls_groups (group_id, accepted_epoch, state_version, '
        'control_revision, lifecycle) VALUES (?, ?, ?, ?, ?)',
        <Object?>[_groupV21, 4, 2, 3, 0],
      )
      ..execute(
        'INSERT INTO group_outbound_objects (operation_id, group_id, '
        'event_id, epoch, mls_object, delivery_state) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>[
          'operation-v21',
          _groupV21,
          'event-v21',
          4,
          Uint8List.fromList(const [1]),
          1,
        ],
      )
      ..execute(
        'INSERT INTO conversations (conversation_id, kind, '
        "list_projection_ciphertext, sort_key) VALUES (?, 1, X'01', 1)",
        <Object?>[_groupV21],
      )
      ..execute(
        'INSERT INTO conversations (conversation_id, kind, '
        "list_projection_ciphertext, sort_key) "
        "VALUES ('direct-v21', 0, X'01', 1)",
      )
      ..execute(
        'INSERT INTO inbox_envelopes (envelope_id, sequence, '
        "envelope_ciphertext, processing_state) "
        "VALUES ('held-v21', 1, X'01', 5)",
      )
      ..execute('PRAGMA user_version = 21');
    versionTwentyOne.close();

    final upgraded = LocalDatabase(NativeDatabase(databaseFile));

    final tables = await upgraded
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row.read<String>('name'))
        .get();
    expect(tables, isNot(contains('mls_groups')));
    expect(tables, isNot(contains('memberships')));
    expect(
      tables,
      containsAll(<String>[
        'group_states',
        'group_control_events',
        'group_outbound_objects',
        'group_state_requests',
      ]),
    );
    expect(
      await upgraded.customSelect('SELECT * FROM group_outbound_objects').get(),
      isEmpty,
    );
    final controlColumns = await upgraded
        .customSelect('PRAGMA table_info(group_control_events)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(controlColumns, isNot(contains('epoch')));
    expect(controlColumns, isNot(contains('mls_commit_hash')));
    expect(controlColumns, contains('canonical_control'));

    Future<int> tombstoned(String conversationId) => upgraded
        .customSelect(
          'SELECT tombstoned FROM conversations WHERE conversation_id = ?',
          variables: [Variable<String>(conversationId)],
        )
        .map((row) => row.read<int>('tombstoned'))
        .getSingle();
    expect(await tombstoned(_groupV21), 1);
    expect(await tombstoned('direct-v21'), 0);
    expect(
      await upgraded
          .customSelect(
            'SELECT processing_state FROM inbox_envelopes '
            "WHERE envelope_id = 'held-v21'",
          )
          .map((row) => row.read<int>('processing_state'))
          .getSingle(),
      0,
    );
    expect(
      await upgraded
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle(),
      LocalDatabase.currentSchemaVersion,
    );
    await upgraded.close();
  });

  test(
    'the group table replacement tolerates a database this build made',
    () async {
      // A database this build created and something stamped back to 21 already
      // has the new group tables. An upgrade that failed on them would leave
      // the application unable to open its storage.
      final current = LocalDatabase(NativeDatabase(databaseFile));
      await current.customSelect('SELECT 1').getSingle();
      await current.close();

      final stampedBack = sqlite3.open(databaseFile.path)
        ..execute('PRAGMA user_version = 21');
      stampedBack.close();

      final upgraded = LocalDatabase(NativeDatabase(databaseFile));

      final tables = await upgraded
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row.read<String>('name'))
          .get();
      expect(
        tables,
        containsAll(<String>['group_states', 'group_state_requests']),
      );
      expect(
        await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle(),
        LocalDatabase.currentSchemaVersion,
      );
      await upgraded.close();
    },
  );
}

const _userV19 = '00000000-0000-0000-0000-0000000000a1';
const _deviceV19 = '00000000-0000-0000-0000-0000000000d1';
const _groupV21 = 'group-v21';

/// The group tables as schema 21 created them, before schema 22 replaced them.
const _mlsGroupsTableV21 =
    'CREATE TABLE "mls_groups" ("group_id" TEXT NOT NULL, '
    '"accepted_epoch" INTEGER NOT NULL CHECK("accepted_epoch" >= 0), '
    '"state_version" INTEGER NOT NULL CHECK("state_version" > 0), '
    '"queue_gap_recovery_state" INTEGER NOT NULL DEFAULT 0 '
    'CHECK("queue_gap_recovery_state" BETWEEN 0 AND 2), '
    '"control_projection_ciphertext" BLOB NULL, '
    '"control_revision" INTEGER NOT NULL DEFAULT 0 '
    'CHECK("control_revision" >= 0), '
    '"control_state_hash" BLOB NULL, '
    '"lifecycle" INTEGER NOT NULL DEFAULT 0 '
    'CHECK("lifecycle" BETWEEN 0 AND 6), '
    '"pending_mutation_id" TEXT NULL, '
    'PRIMARY KEY ("group_id"))';

const _groupControlEventsTableV21 =
    'CREATE TABLE "group_control_events" ("event_id" TEXT NOT NULL, '
    '"group_id" TEXT NOT NULL '
    'REFERENCES mls_groups (group_id) ON DELETE CASCADE, '
    '"revision" INTEGER NOT NULL CHECK("revision" > 0), '
    '"previous_control_state_hash" BLOB NULL, '
    '"control_state_hash" BLOB NOT NULL, '
    '"mls_commit_hash" BLOB NULL, '
    '"epoch" INTEGER NOT NULL CHECK("epoch" >= 0), '
    '"signer_user_id" TEXT NOT NULL, '
    '"signer_device_id" TEXT NOT NULL, '
    '"operation_kind" INTEGER NOT NULL '
    'CHECK("operation_kind" BETWEEN 1 AND 8), '
    '"deterministic_projection" TEXT NULL, '
    '"canonical_control" BLOB NOT NULL, '
    '"signature" BLOB NOT NULL, '
    '"signed_payload" BLOB NULL, '
    '"signer_authentication_proof" BLOB NULL, '
    '"apply_state" INTEGER NOT NULL CHECK("apply_state" BETWEEN 0 AND 2), '
    '"created_ms" INTEGER NOT NULL CHECK("created_ms" >= 0), '
    'PRIMARY KEY ("event_id"), UNIQUE ("group_id", "revision"))';

const _groupOutboundObjectsTableV21 =
    'CREATE TABLE "group_outbound_objects" ("operation_id" TEXT NOT NULL, '
    '"group_id" TEXT NOT NULL '
    'REFERENCES mls_groups (group_id) ON DELETE CASCADE, '
    '"event_id" TEXT NOT NULL, '
    '"epoch" INTEGER NOT NULL CHECK("epoch" >= 0), '
    '"mls_object" BLOB NOT NULL, '
    "\"recipient_user_ids_json\" TEXT NOT NULL DEFAULT '[]', "
    '"delivery_state" INTEGER NOT NULL '
    'CHECK("delivery_state" BETWEEN 0 AND 2), '
    '"created_at" INTEGER NOT NULL DEFAULT 0, '
    'PRIMARY KEY ("operation_id"))';

const _membershipsTableV21 =
    'CREATE TABLE "memberships" ("conversation_id" TEXT NOT NULL '
    'REFERENCES conversations (conversation_id) ON DELETE CASCADE, '
    '"user_id" TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE, '
    '"role_policy_projection_ciphertext" BLOB NOT NULL, '
    'PRIMARY KEY ("conversation_id", "user_id"))';

/// `mls_key_package_maintenance_states` as schema 9 created it, copied from
/// `sqlite_master` before its declaration was deleted.
const _keyPackageMaintenanceTableV19 =
    'CREATE TABLE "mls_key_package_maintenance_states" ('
    '"device_id" TEXT NOT NULL, '
    '"stage" INTEGER NOT NULL CHECK("stage" BETWEEN 0 AND 3), '
    '"expected_state_revision" INTEGER NOT NULL DEFAULT 0 '
    'CHECK("expected_state_revision" >= 0), '
    '"planned_kind" INTEGER NULL '
    'CHECK("planned_kind" IS NULL OR "planned_kind" BETWEEN 0 AND 1), '
    '"exact_upload_projection" BLOB NULL, '
    '"last_resort_uploaded" INTEGER NOT NULL DEFAULT 0 '
    'CHECK ("last_resort_uploaded" IN (0, 1)), '
    '"updated_at" INTEGER NOT NULL '
    "DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)), "
    'PRIMARY KEY ("device_id"))';

const _conversationV17 =
    '0909090909090909090909090909090909090909090909090909090909090909';
const _peerV17 = '00000000-0000-0000-0000-000000000002';
const _peerDeviceV17 = '00000000-0000-0000-0000-000000000022';
const _localV17 = '00000000-0000-0000-0000-000000000001';
const _localDeviceV17 = '00000000-0000-0000-0000-000000000011';

String _messageV17(int index) => '0000000${index}a5a5a5a5a5a5a5a5a5a5a5a5';

Uint8List _bytesV17(String hex) => Uint8List.fromList([
  for (var index = 0; index < hex.length; index += 2)
    int.parse(hex.substring(index, index + 2), radix: 16),
]);

/// The table and the index schema 18 adds, as a device at 17 does not have them.
void _dropPhaseThreeSchema(Database database) {
  database
    ..execute('DROP INDEX IF EXISTS messages_unread_by_conversation')
    ..execute('DROP TABLE IF EXISTS application_event_targets');
}

void _dropPieceFourteenSchema(Database database) {
  // Before the columns, because an index that names a column is what stops
  // SQLite dropping it. These arrived with schema 17, so every schema this
  // helper reconstructs predates all of them.
  _dropPhaseTwoIndexes(database);
  for (final table in const [
    'application_event_targets',
    'application_events',
    'unsupported_application_events',
    'application_sender_counters',
    'message_reactions',
    'pending_application_receipts',
  ]) {
    database.execute('DROP TABLE $table');
  }
  for (final column in const [
    'peer_user_id',
    'last_activity_event_id',
    'unread_count',
    'muted_until',
    'draft_ciphertext',
    'pinned',
  ]) {
    database.execute('ALTER TABLE conversations DROP COLUMN $column');
  }
  for (final column in const [
    'sender_user_id',
    'sender_device_id',
    'reply_to_message_id',
    'quote_fallback_ciphertext',
    'ordering_ms',
    'ordering_event_id',
    'timestamp_state',
    'deleted_for_everyone',
    'deleted_for_me',
    'pinned',
    'starred',
    'unread',
  ]) {
    database.execute('ALTER TABLE messages DROP COLUMN $column');
  }
}

void _dropPhaseTwoIndexes(Database database) {
  for (final index in const [
    'messages_conversation_ordering',
    'messages_pinned_by_conversation',
    'messages_unread_by_conversation',
    'application_events_conversation_apply_state',
    'application_events_sender_counter',
    'attachments_by_message',
    'outbox_operations_by_event',
  ]) {
    database.execute('DROP INDEX IF EXISTS $index');
  }
}

void _dropPieceEighteenSchema(Database database) {
  // The group tables piece 18 reshaped are replaced whole by schema 22, so an
  // older database needs only the conversation column taken back.
  database.execute(
    'ALTER TABLE conversations DROP COLUMN display_title_ciphertext',
  );
}

final class _FailAfterSchemaCreation extends StorageMigrationHooks {
  @override
  Future<void> afterUpgrade(int from, int to) {
    throw StateError('fault-injected migration failure');
  }
}
