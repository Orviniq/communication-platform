import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'local_send_harness.dart';

/// A second device belonging to the local account, so a read receipt can come
/// from this user without coming from the device that is projecting.
const secondLocalDeviceId = '00000000-0000-0000-0000-000000000012';

/// A second peer device, so a receipt has more than one provenance to keep.
const secondPeerDeviceId = '00000000-0000-0000-0000-000000000023';

/// The conversation every commit in this harness belongs to.
final harnessConversationId = seededBytes(9, 32);

/// A 16-byte identifier that stays distinct past 256 of them.
///
/// [seededBytes] fills each byte from the seed, so it repeats every 256 seeds
/// and a long conversation would quietly reuse an event id — which the
/// projector would read as a fork rather than as a test setup mistake.
Uint8List sequentialId(int index) => Uint8List.fromList([
  (index >> 24) & 0xff,
  (index >> 16) & 0xff,
  (index >> 8) & 0xff,
  index & 0xff,
  ...List<int>.filled(12, 0xa5),
]);

/// One authenticated application event, ready to apply.
///
/// The shape the projector's own contract test builds privately, shared here
/// because the equivalence, cost and crash tests all need to build adversarial
/// sequences out of every event kind rather than out of message creates alone.
ApplicationEventCommit applicationCommit({
  required Uint8List eventId,
  required ApplicationEventKind kind,
  required String senderUser,
  required String senderDevice,
  required int counter,
  required ApplicationEventBody body,
  List<Uint8List> references = const [],
  ConversationKind conversationKind = ConversationKind.direct,
  String? peer = peerUserId,
  bool localOrigin = false,
  int? createdMs,
  Uint8List? canonicalBytes,
}) {
  final event = ApplicationEventRecord(
    version: ApplicationMessageProtocolV1.version,
    eventId: eventId,
    conversationId: harnessConversationId,
    kindValue: kind.wireValue,
    senderUserId: protocolUuidBytes(senderUser),
    senderDeviceId: protocolUuidBytes(senderDevice),
    senderCounter: counter,
    createdMs: createdMs ?? 1700000000000 + counter,
    references: references,
    body: body,
  );
  return ApplicationEventCommit(
    event: event,
    canonicalBytes:
        canonicalBytes ??
        Uint8List.fromList([kind.wireValue, counter & 0xff, ...eventId]),
    currentUserId: localUserId,
    currentDeviceId: localDeviceId,
    conversationKind: conversationKind.index,
    peerUserId: peer,
    localOrigin: localOrigin,
    authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
      1700000100000,
      isUtc: true,
    ),
  );
}

/// Applies [commit] the way production does: inside one write transaction.
Future<ApplicationApplyResult> applyCommit(
  LocalDatabase database,
  ApplicationEventCommit commit,
) => database.writeTransaction(
  () => DriftApplicationEventProjector(database).applyInsideTransaction(commit),
);

/// Runs the recovery path over [conversationId], as a fork or repair would.
Future<void> rebuildConversation(
  LocalDatabase database,
  Uint8List conversationId, {
  String currentUserId = localUserId,
}) => database.writeTransaction(
  () => DriftApplicationEventProjector(database)
      .rebuildConversationInsideTransaction(
        protocolBytesToHex(conversationId),
        currentUserId: currentUserId,
      ),
);

/// Everything the projector owns, as one comparable value.
///
/// Every column of `messages` is included, the preserved local-only ones most
/// of all: the incremental path claims to carry exactly what a rebuild carries,
/// and a snapshot that omitted them could not tell the difference. `apply_state`
/// comes along because it is what decides whether a fact is in the fold at all.
Future<String> projectionSnapshot(LocalDatabase database) async {
  Object? normalize(Object? value) => switch (value) {
    final Uint8List bytes => protocolBytesToHex(bytes),
    final DateTime time => time.toUtc().toIso8601String(),
    _ => value,
  };
  Future<List<Object?>> rows(String sql) async => [
    for (final row in await database.customSelect(sql).get())
      row.data.map((key, value) => MapEntry(key, normalize(value))),
  ];
  return const JsonEncoder.withIndent('  ').convert({
    'conversations': await rows(
      'SELECT conversation_id, kind, peer_user_id, '
      'list_projection_ciphertext, sort_key, last_activity_event_id, '
      'unread_count, tombstoned FROM conversations ORDER BY conversation_id',
    ),
    'messages': await rows(
      'SELECT * FROM messages ORDER BY conversation_id, message_id',
    ),
    'reactions': await rows(
      'SELECT * FROM message_reactions ORDER BY message_id, reacting_user_id',
    ),
    'receipts': await rows(
      'SELECT * FROM receipts ORDER BY message_id, user_id, device_id',
    ),
    'attachments': await rows(
      'SELECT * FROM attachments ORDER BY message_id, attachment_id',
    ),
    'events': await rows(
      'SELECT event_id, apply_state FROM application_events ORDER BY event_id',
    ),
  });
}

/// A third opinion on the conversation-level aggregates.
///
/// Both projection paths share one SQL definition of the preview, the ordering
/// key, the last activity and the unread count, which makes them equal to each
/// other by construction and says nothing about whether either is right. This
/// recomputes all four in Dart from the rows that are actually there, which is
/// the rule the rebuild used to apply in memory.
Future<void> expectAggregatesRecomputed(LocalDatabase database) async {
  for (final conversation
      in await database.select(database.conversations).get()) {
    final rows =
        await (database.select(database.messages)..where(
              (row) => row.conversationId.equals(conversation.conversationId),
            ))
            .get();
    Message? latest;
    var unread = 0;
    for (final message in rows) {
      if (message.unread) {
        unread += 1;
      }
      final newer =
          latest == null ||
          message.orderingMs > latest.orderingMs ||
          (message.orderingMs == latest.orderingMs &&
              message.orderingEventId.compareTo(latest.orderingEventId) > 0);
      if (newer) {
        latest = message;
      }
    }
    final where = 'conversation ${conversation.conversationId}';
    expect(conversation.unreadCount, unread, reason: where);
    expect(conversation.sortKey, latest?.orderingMs ?? 0, reason: where);
    expect(
      conversation.lastActivityEventId,
      latest?.orderingEventId,
      reason: where,
    );
    expect(
      conversation.listProjectionCiphertext,
      latest == null ? Uint8List(0) : await _expectedPreview(database, latest),
      reason: where,
    );
  }
}

/// The text of [latest], or, for a message with an attachment and no caption,
/// the name of its first attachment (ADR-089 D10).
Future<Uint8List> _expectedPreview(
  LocalDatabase database,
  Message latest,
) async {
  if (latest.projectionCiphertext.isNotEmpty || latest.deletedForEveryone) {
    return latest.projectionCiphertext;
  }
  final rows = await database
      .customSelect(
        'SELECT encrypted_descriptor FROM attachments WHERE message_id = ? '
        'ORDER BY rowid',
        variables: [Variable<String>(latest.messageId)],
      )
      .get();
  if (rows.isEmpty) {
    return Uint8List(0);
  }
  final stored = jsonDecode(
    utf8.decode(rows.first.read<Uint8List>('encrypted_descriptor')),
  );
  return stored is Map<String, Object?> && stored['name'] is String
      ? Uint8List.fromList(utf8.encode(stored['name']! as String))
      : Uint8List(0);
}

/// Discards the projection, keeping the log and the local-only columns with it.
///
/// What is left is a database that has every authenticated fact and no derived
/// state at all, which is the only starting point from which a rebuild proves
/// something about the *preserved* columns as well as the derived ones.
Future<void> discardProjection(
  LocalDatabase database,
  Uint8List conversationId,
) async {
  final id = protocolBytesToHex(conversationId);
  await (database.delete(
    database.messages,
  )..where((row) => row.conversationId.equals(id))).go();
  await (database.update(
    database.conversations,
  )..where((row) => row.conversationId.equals(id))).write(
    ConversationsCompanion(
      listProjectionCiphertext: Value(Uint8List(0)),
      sortKey: Value(0),
      lastActivityEventId: Value(null),
      unreadCount: Value(0),
    ),
  );
}
