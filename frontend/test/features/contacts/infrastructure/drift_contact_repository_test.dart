import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/drift_contact_repository.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDatabase database;
  late DriftContactRepository repository;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftContactRepository(database);
  });

  tearDown(() => database.close());

  test(
    'offline cache never presents a profile ahead of verified identity proof',
    () async {
      const user = DirectoryUser(userId: 'peer', username: 'backend_username');
      await repository.replaceDirectory([user]);
      await repository.writeProfile(
        user.userId,
        ProfileCiphertext(blob: Uint8List(1024), version: 1),
        const AuthenticatedProfile(
          displayName: 'Authenticated Name',
          avatarSeed: 7,
          version: 1,
          authorDeviceId: 'device',
        ),
      );

      var projection =
          (await repository.watchContacts(ownUserId: 'self').first).single;
      expect(projection.presentationName, user.username);
      expect(projection.authenticatedAvatarSeed, isNull);

      await repository.writeTrust(
        ContactTrustRecord(
          userId: user.userId,
          state: ContactTrustState.verified,
        ),
      );
      projection =
          (await repository.watchContacts(ownUserId: 'self').first).single;
      expect(projection.presentationName, user.username);
      expect(projection.trustState, ContactTrustState.identityUnavailable);

      final identity = PeerIdentityPublic(
        masterPublic: _bytes(32, 1),
        selfSigningPublic: _bytes(32, 2),
        userSigningPublic: _bytes(32, 3),
        masterSignature: _bytes(64, 4),
        version: 1,
      );
      await repository.writeTrust(
        ContactTrustRecord(
          userId: user.userId,
          state: ContactTrustState.verified,
          identity: identity,
          confirmedMasterPublic: identity.masterPublic,
          attestation: UserSigningAttestation(_bytes(64, 5)),
          etag: '"devices"',
          logHeadSequence: 0,
          logHeadHash: _bytes(32, 6),
        ),
      );
      projection =
          (await repository.watchContacts(ownUserId: 'self').first).single;
      expect(projection.presentationName, 'Authenticated Name');
      expect(projection.authenticatedAvatarSeed, 7);
      expect(projection.trustState, ContactTrustState.verified);
    },
  );

  test('directory refresh deactivates stale cached rows atomically', () async {
    await repository.replaceDirectory(const [
      DirectoryUser(userId: 'alice-id', username: 'alice'),
      DirectoryUser(userId: 'bob-id', username: 'bob'),
    ]);
    await repository.replaceDirectory(const [
      DirectoryUser(userId: 'bob-id', username: 'bob'),
    ]);

    final contacts = await repository.watchContacts(ownUserId: 'self').first;
    expect(contacts.map((contact) => contact.username), ['bob']);
  });

  test('a device change that has not landed yet is not a fork', () async {
    await _writePosture(database, GlobalSecurityState.pendingDeviceChange);

    final forked = await repository.hasAnyDeviceLogFork();

    // Every send resolves live devices, and that resolution refuses outright
    // on a fork. Reading the in-flight marker as a fork withheld messaging
    // with every peer - verified ones included - until the app was reinstalled.
    expect((forked as Success<bool>).value, isFalse);
  });

  test('a recorded fork still blocks globally', () async {
    await _writePosture(database, GlobalSecurityState.deviceLogFork);

    final forked = await repository.hasAnyDeviceLogFork();

    expect((forked as Success<bool>).value, isTrue);
  });

  test('a normal posture reports no fork', () async {
    await _writePosture(database, GlobalSecurityState.normal);

    final forked = await repository.hasAnyDeviceLogFork();

    expect((forked as Success<bool>).value, isFalse);
  });

  group('the two stored tags', () {
    ContactTrustRecord verified({String? etag, String? peerStateEtag}) {
      final identity = PeerIdentityPublic(
        masterPublic: _bytes(32, 1),
        selfSigningPublic: _bytes(32, 2),
        userSigningPublic: _bytes(32, 3),
        masterSignature: _bytes(64, 4),
        version: 1,
      );
      return ContactTrustRecord(
        userId: 'peer',
        state: ContactTrustState.verified,
        identity: identity,
        confirmedMasterPublic: identity.masterPublic,
        attestation: UserSigningAttestation(_bytes(64, 5)),
        etag: etag,
        peerStateEtag: peerStateEtag,
        logHeadSequence: 0,
        logHeadHash: _bytes(32, 6),
      );
    }

    test('are stored apart and read back apart', () async {
      await repository.writeTrust(
        verified(etag: '"devices"', peerStateEtag: '"peers"'),
      );

      final read = await _readTrust(repository);

      expect(read.etag, '"devices"');
      expect(read.peerStateEtag, '"peers"');
    });

    test('a verified record may hold only the batched read\'s tag', () async {
      // A batched read that moved the stored state drops the device list's
      // tag, and the record it writes is no less verified for that.
      await repository.writeTrust(verified(peerStateEtag: '"peers"'));

      final read = await _readTrust(repository);

      expect(read.state, ContactTrustState.verified);
      expect(read.etag, isNull);
      expect(read.peerStateEtag, '"peers"');
    });

    test('a verified record with no tag at all is still refused', () async {
      await repository.writeTrust(verified());

      final read = await repository.readTrust('peer');

      expect(read, isA<FailureResult<ContactTrustRecord?>>());
    });
  });
}

Future<void> _writePosture(LocalDatabase database, GlobalSecurityState state) =>
    database
        .into(database.securityPostures)
        .insertOnConflictUpdate(
          SecurityPosturesCompanion.insert(
            singletonId: const Value(1),
            state: state.index,
          ),
        );

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));

Future<ContactTrustRecord> _readTrust(
  DriftContactRepository repository,
) async =>
    (await repository.readTrust('peer') as Success<ContactTrustRecord?>).value!;
