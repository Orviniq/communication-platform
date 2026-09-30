import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'restart preserves ciphertext state without plaintext web fixtures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'local-db-restart-',
      );
      final file = File('${directory.path}/web-shaped.sqlite');
      const forbiddenFixtures = [
        'meet me after sunset',
        'medical-results.pdf',
        'Alice Personal Profile',
        'Private Strategy Room',
        'sunset search token',
      ];
      final opaqueCiphertext = Uint8List.fromList([
        0x89,
        0x2a,
        0xd1,
        0x04,
        0x7f,
        0xee,
        0x31,
        0xb8,
      ]);

      var database = LocalDatabase(NativeDatabase(file));
      await database
          .into(database.users)
          .insert(
            UsersCompanion.insert(
              userId: 'opaque-user-reference',
              activated: true,
              directoryEntryCiphertext: opaqueCiphertext,
              localState: 0,
            ),
          );
      await database
          .into(database.profiles)
          .insert(
            ProfilesCompanion.insert(
              userId: 'opaque-user-reference',
              profileCiphertext: opaqueCiphertext,
              version: 1,
              verificationState: 1,
            ),
          );
      // A room's name and roster live inside its control projection.
      await database
          .into(database.roomStates)
          .insert(
            RoomStatesCompanion.insert(
              roomId: 'opaque-room-reference',
              stateVersion: 1,
              controlProjectionCiphertext: opaqueCiphertext,
              controlRevision: 1,
              controlStateHash: opaqueCiphertext,
              lifecycle: 0,
            ),
          );
      await database
          .into(database.conversations)
          .insert(
            ConversationsCompanion.insert(
              conversationId: 'opaque-conversation-reference',
              kind: 0,
              listProjectionCiphertext: opaqueCiphertext,
              sortKey: 1,
            ),
          );
      await database.close();

      database = LocalDatabase(NativeDatabase(file));
      final profile = await database.select(database.profiles).getSingle();
      final room = await database.select(database.roomStates).getSingle();
      expect(profile.profileCiphertext, opaqueCiphertext);
      expect(room.controlProjectionCiphertext, opaqueCiphertext);
      await database.close();

      final persistentBytes = await file.readAsBytes();
      final searchableImage = utf8.decode(
        persistentBytes,
        allowMalformed: true,
      );
      for (final fixture in forbiddenFixtures) {
        expect(searchableImage, isNot(contains(fixture)));
      }
      await directory.delete(recursive: true);
    },
  );

  test('schema has no durable plaintext columns for prohibited web data', () {
    final source = File(
      'lib/features/local_storage/infrastructure/database/local_database.dart',
    ).readAsStringSync();
    for (final prohibitedColumn in const [
      'messageBody',
      'searchIndex',
      'fileName',
      'profileName',
      'roomName',
      'groupName',
    ]) {
      expect(source, isNot(contains('get $prohibitedColumn')));
    }
    expect(source, contains('profileCiphertext'));
    expect(source, contains('controlProjectionCiphertext'));
    expect(source, contains('encryptedDescriptor'));
    expect(source, contains('projectionCiphertext'));
  });
}
