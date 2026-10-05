import 'dart:convert';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';

final class DriftContactRepository implements ContactLocalPort {
  const DriftContactRepository(this.database);

  static const _trustPrefix = 'contact.trust.v1.';
  static const _identitySecretId = 'account-cross-signing-state-v1';
  static const _formatVersion = 1;

  final LocalDatabase database;

  @override
  Stream<List<ContactProjection>> watchContacts({required String ownUserId}) =>
      _watchProjectionRows(
        ownUserId: ownUserId,
      ).map((rows) => rows.map(_projection).toList(growable: false));

  @override
  Stream<ContactProjection?> watchContact(String userId) =>
      _watchProjectionRows(
        userId: userId,
      ).map((rows) => rows.isEmpty ? null : _projection(rows.single));

  Stream<List<QueryRow>> _watchProjectionRows({
    String? ownUserId,
    String? userId,
  }) {
    final where = <String>['u.activated = 1'];
    final variables = <Variable<Object>>[];
    if (ownUserId != null) {
      where.add('u.user_id <> ?');
      variables.add(Variable<String>(ownUserId));
    }
    if (userId != null) {
      where.add('u.user_id = ?');
      variables.add(Variable<String>(userId));
    }
    return database
        .customSelect(
          '''
SELECT u.user_id, u.directory_entry_ciphertext,
       p.profile_ciphertext, p.version AS profile_version,
       p.verification_state, lp.value_ciphertext AS trust_ciphertext
FROM users u
LEFT JOIN profiles p ON p.user_id = u.user_id
LEFT JOIN local_preferences lp
  ON lp.preference_key = '$_trustPrefix' || u.user_id
WHERE ${where.join(' AND ')}
ORDER BY u.directory_entry_ciphertext ASC
''',
          variables: variables,
          readsFrom: {
            database.users,
            database.profiles,
            database.localPreferences,
          },
        )
        .watch();
  }

  ContactProjection _projection(QueryRow row) {
    final id = row.read<String>('user_id');
    final username = utf8.decode(
      row.read<Uint8List>('directory_entry_ciphertext'),
    );
    final trustBytes = row.readNullable<Uint8List>('trust_ciphertext');
    ContactTrustRecord? trust;
    try {
      trust = trustBytes == null ? null : _decodeTrust(id, trustBytes);
    } on Object {
      trust = ContactTrustRecord(
        userId: id,
        state: ContactTrustState.identityUnavailable,
      );
    }
    final profileBytes = row.readNullable<Uint8List>('profile_ciphertext');
    final profileState = row.readNullable<int>('verification_state');
    AuthenticatedProfile? profile;
    try {
      profile = profileBytes == null || profileState != 1
          ? null
          : _decodeProfile(profileBytes).$2;
    } on Object {
      profile = null;
    }
    return ContactProjection(
      userId: id,
      username: username,
      trustState: trust?.state ?? ContactTrustState.unverified,
      authenticatedProfile: profile,
    );
  }

  @override
  Future<Result<void>> replaceDirectory(List<DirectoryUser> users) async {
    try {
      await database.writeTransaction<void>(() async {
        await database
            .update(database.users)
            .write(const UsersCompanion(activated: Value(false)));
        for (final user in users) {
          await database
              .into(database.users)
              .insertOnConflictUpdate(
                UsersCompanion.insert(
                  userId: user.userId,
                  activated: true,
                  directoryEntryCiphertext: Uint8List.fromList(
                    utf8.encode(user.username),
                  ),
                  localState: 0,
                ),
              );
        }
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<ContactTrustRecord?>> readTrust(String userId) async {
    try {
      final row =
          await (database.select(database.localPreferences)..where(
                (entry) => entry.preferenceKey.equals('$_trustPrefix$userId'),
              ))
              .getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      return Result.success(_decodeTrust(userId, row.valueCiphertext));
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<bool>> hasAnyDeviceLogFork() async {
    try {
      final global = await database
          .select(database.securityPostures)
          .getSingleOrNull();
      // Only a fork blocks. `pendingDeviceChange` is the in-flight marker an
      // own device-log mutation sets before it appends and clears once the
      // append is confirmed, so a mutation that never confirmed - a dropped
      // connection mid-enrolment is enough - used to latch it forever. Reading
      // it as a fork here withheld every send to every peer, including fully
      // verified ones, through a posture no screen displays and no user action
      // clears. The equivocation alert is global by design; a device change
      // that has not landed yet is not equivocation.
      if (global != null &&
          global.state == GlobalSecurityState.deviceLogFork.index) {
        return const Result.success(true);
      }
      final rows = await (database.select(
        database.localPreferences,
      )..where((entry) => entry.preferenceKey.like('$_trustPrefix%'))).get();
      for (final row in rows) {
        final userId = row.preferenceKey.substring(_trustPrefix.length);
        if (_decodeTrust(userId, row.valueCiphertext).state ==
            ContactTrustState.deviceLogFork) {
          return const Result.success(true);
        }
      }
      return const Result.success(false);
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<void>> writeTrust(ContactTrustRecord trust) async {
    try {
      await database
          .into(database.localPreferences)
          .insertOnConflictUpdate(
            LocalPreferencesCompanion.insert(
              preferenceKey: '$_trustPrefix${trust.userId}',
              valueCiphertext: _encodeTrust(trust),
              valueVersion: _formatVersion,
            ),
          );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<List<PeerPublicDevice>>> readDevices(String userId) async {
    try {
      final rows =
          await (database.select(database.devices)
                ..where((entry) => entry.userId.equals(userId))
                ..orderBy([(entry) => OrderingTerm.asc(entry.deviceId)]))
              .get();
      return Result.success(
        rows
            .map((row) => _decodeDevice(row.publicBundle))
            .toList(growable: false),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<void>> replaceDevices(
    String userId,
    List<PeerPublicDevice> devices,
  ) async {
    try {
      await database.writeTransaction<void>(() async {
        await (database.delete(
          database.devices,
        )..where((entry) => entry.userId.equals(userId))).go();
        for (final device in devices) {
          await database
              .into(database.devices)
              .insert(
                DevicesCompanion.insert(
                  deviceId: device.deviceId,
                  userId: userId,
                  publicBundle: _encodeDevice(device),
                  revocationState: device.isUnsigned ? 1 : 0,
                  bundleVersion: Value(device.bundleVersion),
                ),
              );
        }
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> appendVerifiedLogRecords(
    String userId,
    List<VerifiedDeviceLogRecord> records,
  ) async {
    try {
      await database.writeTransaction<void>(() async {
        for (final record in records) {
          await database
              .into(database.deviceLogRecords)
              .insert(
                DeviceLogRecordsCompanion.insert(
                  userId: userId,
                  sequence: record.sequence,
                  signedOpaqueRecord: record.blob,
                  recordHash: record.hash,
                  forkState: 0,
                  gossipState: 0,
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> writeProfile(
    String userId,
    ProfileCiphertext ciphertext,
    AuthenticatedProfile? authenticated,
  ) async {
    try {
      final value = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': _formatVersion,
            'blob': base64Encode(ciphertext.blob),
            'version': ciphertext.version,
            if (authenticated != null) ...{
              'display_name': authenticated.displayName,
              'avatar_seed': authenticated.avatarSeed,
              'author_device_id': authenticated.authorDeviceId,
            },
          }),
        ),
      );
      await database
          .into(database.profiles)
          .insertOnConflictUpdate(
            ProfilesCompanion.insert(
              userId: userId,
              profileCiphertext: value,
              version: ciphertext.version,
              verificationState: authenticated == null ? 0 : 1,
            ),
          );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<LocalAccountIdentity>> readLocalIdentity() async {
    try {
      final session = await database
          .select(database.accountSessions)
          .getSingle();
      final secret =
          await (database.select(database.secureSecrets)
                ..where((entry) => entry.secretId.equals(_identitySecretId)))
              .getSingle();
      return Result.success(
        LocalAccountIdentity(
          userId: utf8.decode(session.userIdCiphertext),
          deviceId: utf8.decode(session.deviceIdCiphertext!),
          username: utf8.decode(session.serverProfileCiphertext),
          identityPackage: IdentityKeyPackage.fromNative(
            secret.wrappedCiphertextOrOpaqueHandle,
          ),
        ),
      );
    } on EnrollmentCryptoFormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Uint8List _encodeTrust(ContactTrustRecord trust) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': _formatVersion,
        'state': trust.state.index,
        if (trust.identity case final identity?) ...{
          'master': base64Encode(identity.masterPublic),
          'self': base64Encode(identity.selfSigningPublic),
          'user': base64Encode(identity.userSigningPublic),
          'master_sig': base64Encode(identity.masterSignature),
          'identity_version': identity.version,
        },
        if (trust.confirmedMasterPublic != null)
          'confirmed_master': base64Encode(trust.confirmedMasterPublic!),
        if (trust.attestation != null)
          'attestation': base64Encode(trust.attestation!.signature),
        if (trust.etag != null) 'etag': trust.etag,
        if (trust.peerStateEtag != null) 'peer_etag': trust.peerStateEtag,
        if (trust.identityEtag != null) 'identity_etag': trust.identityEtag,
        if (trust.logHeadSequence != null) 'head_seq': trust.logHeadSequence,
        if (trust.logHeadHash != null)
          'head_hash': base64Encode(trust.logHeadHash!),
      }),
    ),
  );

  ContactTrustRecord _decodeTrust(String userId, Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?> || json['format'] != _formatVersion) {
      throw const FormatException();
    }
    final stateIndex = json['state'];
    if (stateIndex is! int ||
        stateIndex < 0 ||
        stateIndex >= ContactTrustState.values.length) {
      throw const FormatException();
    }
    final master = _decodeFixed(json['master'], 32);
    final self = _decodeFixed(json['self'], 32);
    final user = _decodeFixed(json['user'], 32);
    final masterSig = _decodeFixed(json['master_sig'], 64);
    final identityVersion = json['identity_version'];
    final hasIdentity =
        master != null || self != null || user != null || masterSig != null;
    if (hasIdentity &&
        (master == null ||
            self == null ||
            user == null ||
            masterSig == null ||
            identityVersion is! int)) {
      throw const FormatException();
    }
    final attestation = _decodeFixed(json['attestation'], 64);
    final confirmedMaster = _decodeFixed(json['confirmed_master'], 32);
    final headHash = _decodeFixed(json['head_hash'], 32);
    final state = ContactTrustState.values[stateIndex];
    final identity = !hasIdentity
        ? null
        : PeerIdentityPublic(
            masterPublic: master!,
            selfSigningPublic: self!,
            userSigningPublic: user!,
            masterSignature: masterSig!,
            version: identityVersion! as int,
          );
    final etag = json['etag'];
    final peerStateEtag = json['peer_etag'];
    final identityEtag = json['identity_etag'];
    if ((etag != null && etag is! String) ||
        (peerStateEtag != null && peerStateEtag is! String) ||
        (identityEtag != null && identityEtag is! String)) {
      throw const FormatException();
    }
    // A verified record is the product of an answer this client accepted, so
    // it holds the tag of the route that gave it. Which route that was is not
    // part of the claim: a batched read keeps the device list's tag only when
    // nothing it vouched for moved.
    if (state == ContactTrustState.verified &&
        (identity == null ||
            confirmedMaster == null ||
            !_same(identity.masterPublic, confirmedMaster) ||
            attestation == null ||
            (etag == null && peerStateEtag == null) ||
            json['head_seq'] is! int ||
            headHash == null)) {
      throw const FormatException();
    }
    return ContactTrustRecord(
      userId: userId,
      state: state,
      identity: identity,
      confirmedMasterPublic: confirmedMaster,
      attestation: attestation == null
          ? null
          : UserSigningAttestation(attestation),
      etag: etag as String?,
      peerStateEtag: peerStateEtag as String?,
      identityEtag: identityEtag as String?,
      logHeadSequence: json['head_seq'] as int?,
      logHeadHash: headHash,
    );
  }

  Uint8List _encodeDevice(PeerPublicDevice device) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': _formatVersion,
        'device_id': device.deviceId,
        'ik': base64Encode(device.identityPublic),
        'registration': device.registrationId,
        if (device.crossSignature != null)
          'cross': base64Encode(device.crossSignature!),
        if (device.bundleVersion != null)
          'bundle_version': device.bundleVersion,
      }),
    ),
  );

  PeerPublicDevice _decodeDevice(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?> || json['format'] != _formatVersion) {
      throw const FormatException();
    }
    return PeerPublicDevice(
      deviceId: json['device_id']! as String,
      identityPublic: _decodeFixed(json['ik'], 64)!,
      registrationId: json['registration']! as int,
      crossSignature: _decodeFixed(json['cross'], 64),
      bundleVersion: json['bundle_version'] as int?,
    );
  }

  (ProfileCiphertext, AuthenticatedProfile?) _decodeProfile(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?> || json['format'] != _formatVersion) {
      throw const FormatException();
    }
    final blob = base64Decode(json['blob']! as String);
    final version = json['version']! as int;
    final displayName = json['display_name'];
    final avatarSeed = json['avatar_seed'];
    final authorDeviceId = json['author_device_id'];
    return (
      ProfileCiphertext(blob: blob, version: version),
      displayName is String && avatarSeed is int && authorDeviceId is String
          ? AuthenticatedProfile(
              displayName: displayName,
              avatarSeed: avatarSeed,
              version: version,
              authorDeviceId: authorDeviceId,
            )
          : null,
    );
  }

  Uint8List? _decodeFixed(Object? value, int length) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const FormatException();
    }
    final bytes = base64Decode(value);
    if (bytes.length != length || base64Encode(bytes) != value) {
      throw const FormatException();
    }
    return Uint8List.fromList(bytes);
  }

  bool _same(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index += 1) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
