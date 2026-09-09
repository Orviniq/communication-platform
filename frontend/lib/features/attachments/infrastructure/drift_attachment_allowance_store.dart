import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';

/// The day's uploaded total, in the encrypted preference table.
///
/// One row holding one UTC day and one count. It is a row rather than a table
/// for the same reason the published limits are: it is a single small fact that
/// a new day discards, and a table would be a schema migration for something
/// with no history worth keeping.
///
/// It lives behind the same non-exportable Keystore-wrapped key as everything
/// else durable, so a logout wipe takes it with the rest rather than leaving
/// one account's upload volume behind for the next person on the phone. That
/// volume is not a secret the server does not already hold, but it is a fact
/// about a person, and none of those outlive the session that made them.
final class DriftAttachmentAllowanceStore implements AttachmentAllowancePort {
  const DriftAttachmentAllowanceStore(this.database);

  static const allowanceKey = 'attachments.daily_allowance.v1';

  final LocalDatabase database;

  @override
  Future<AttachmentDailyAllowance> read(DateTime now) async {
    try {
      final row =
          await (database.select(database.localPreferences)
                ..where((entry) => entry.preferenceKey.equals(allowanceKey)))
              .getSingleOrNull();
      return _decode(row?.valueCiphertext, now);
    } on Object {
      return AttachmentDailyAllowance.empty(now);
    }
  }

  @override
  Future<void> record({required int bytes, required DateTime now}) async {
    try {
      final spent = (await read(now)).spend(bytes: bytes, now: now);
      await database.writeTransaction<void>(() async {
        await database
            .into(database.localPreferences)
            .insertOnConflictUpdate(
              LocalPreferencesCompanion.insert(
                preferenceKey: allowanceKey,
                valueCiphertext: Uint8List.fromList(
                  utf8.encode(
                    jsonEncode({
                      'day': spent.day.toIso8601String(),
                      'spent_bytes': spent.spentBytes,
                    }),
                  ),
                ),
                valueVersion: 1,
              ),
            );
      });
    } on Object {
      // Deliberately swallowed. The bytes reached the server whatever happened
      // here, and the only consequence is that this client believes it has
      // room the server has already spent — which the server corrects with the
      // `413` it would have sent in any case.
    }
  }

  AttachmentDailyAllowance _decode(Uint8List? stored, DateTime now) {
    if (stored == null) {
      return AttachmentDailyAllowance.empty(now);
    }
    try {
      final json = jsonDecode(utf8.decode(stored));
      if (json is! Map<String, Object?>) {
        return AttachmentDailyAllowance.empty(now);
      }
      final day = json['day'];
      final spent = json['spent_bytes'];
      if (day is! String || spent is! int || spent < 0) {
        return AttachmentDailyAllowance.empty(now);
      }
      return AttachmentDailyAllowance(
        day: utcDayOf(DateTime.parse(day)),
        spentBytes: spent,
      );
    } on Object {
      return AttachmentDailyAllowance.empty(now);
    }
  }
}
