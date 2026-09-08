import 'dart:convert';

import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:drift/drift.dart';

/// Persists the session token inside the Keystore-protected SQLCipher store.
///
/// There is one token now, so the store holds one token (ADR-0023). The pair it
/// used to hold was split — a refresh token durable, an access token in this
/// adapter's memory and nowhere else — and restoration wrote back an expired
/// placeholder so that the first authenticated request had to rotate before it
/// could be sent. Nothing rotates, and a session token outlives a cold start,
/// so the row carries the credential itself and restoration returns a token
/// that is ready to use.
///
/// A row written by a build that stored a pair has no readable shape here: the
/// guard in [_readDurableRow] finds no `token`, deletes the row, and the user
/// signs in once more.
final class SecureSessionTokenAdapter implements SessionTokenStore {
  SecureSessionTokenAdapter(this.runtime);

  static const _loginHintKey = 'authentication.login_hint.v1';
  static const _formatVersion = 1;

  final SecureLocalStorageRuntime runtime;
  SessionTokens? _memoryTokens;

  @override
  Future<SessionTokens?> read() async {
    final memory = _memoryTokens;
    if (memory != null) {
      return memory;
    }
    final restored = await _readDurableRow();
    if (restored != null) {
      _memoryTokens = restored;
    }
    return restored;
  }

  /// The durable row, never this adapter's memory.
  ///
  /// [read] answers from `_memoryTokens` so an ordinary request does not pay a
  /// SQLCipher round trip for a value this isolate already has. That cache is
  /// per-isolate and the row behind it is shared with every other delivery
  /// owner in this process, so a caller that must see what another owner wrote
  /// asks this instead (ADR-050). It deliberately does not disturb the cache:
  /// a token this owner holds keeps working whatever the row now says, because
  /// nothing retires it (ADR-0023).
  @override
  Future<SessionTokens?> readDurable() => _readDurableRow();

  Future<SessionTokens?> _readDurableRow() async {
    final database = await _database();
    if (database == null) {
      return null;
    }
    final row = await database
        .select(database.accountSessions)
        .getSingleOrNull();
    if (row == null || row.scope != SessionScope.full.index) {
      return null;
    }
    try {
      final metadata = _decodeObject(row.tokenMetadataCiphertext);
      final token = metadata['token'];
      final version = metadata['version'];
      final expiresAt = row.expiresAt;
      final userId = utf8.decode(row.userIdCiphertext);
      final deviceBytes = row.deviceIdCiphertext;
      final deviceId = deviceBytes == null ? null : utf8.decode(deviceBytes);
      final username = utf8.decode(row.serverProfileCiphertext);
      if (version != _formatVersion ||
          token is! String ||
          token.isEmpty ||
          expiresAt == null ||
          !_uuid.hasMatch(userId) ||
          deviceId == null ||
          !_uuid.hasMatch(deviceId) ||
          !AuthenticationInputPolicy.isUsernameValid(username)) {
        await _deleteSession(database);
        return null;
      }
      final restored = SessionTokens(
        accessToken: AccessToken(
          value: token,
          expiresAt: expiresAt.toUtc(),
          scope: SessionScope.full,
        ),
        userId: userId,
        deviceId: deviceId,
        username: username,
      );
      return restored;
    } on Object {
      await _deleteSession(database);
      return null;
    }
  }

  @override
  Future<void> replace(SessionTokens tokens) async {
    final database = await _database();
    if (database == null) {
      throw StateError('Protected session storage is unavailable.');
    }
    final merged = await _merge(tokens);
    if (merged.accessToken.scope == SessionScope.register) {
      _memoryTokens = merged;
      await _deleteSession(database);
      return;
    }
    await _writeFullSession(database, merged);
    _memoryTokens = merged;
  }

  Future<void> replaceWithAtomicMutation(
    SessionTokens tokens,
    Future<void> Function(LocalDatabase database) mutation,
  ) async {
    final database = await _database();
    if (database == null) {
      throw StateError('Protected session storage is unavailable.');
    }
    final merged = await _merge(tokens);
    if (merged.accessToken.scope != SessionScope.full) {
      throw StateError('Atomic enrollment commit requires full scope.');
    }
    await database.writeTransaction<void>(() async {
      await _writeFullSession(database, merged);
      await mutation(database);
    });
    _memoryTokens = merged;
  }

  Future<SessionTokens> _merge(SessionTokens tokens) async {
    final previous = _memoryTokens ?? await read();
    return SessionTokens(
      accessToken: tokens.accessToken,
      userId: tokens.userId ?? previous?.userId,
      deviceId: tokens.deviceId ?? previous?.deviceId,
      username: tokens.username ?? previous?.username,
    );
  }

  Future<void> _writeFullSession(
    LocalDatabase database,
    SessionTokens merged,
  ) async {
    final token = merged.accessToken.value;
    final userId = merged.userId;
    final deviceId = merged.deviceId;
    final username = merged.username;
    if (token.isEmpty ||
        userId == null ||
        !_uuid.hasMatch(userId) ||
        deviceId == null ||
        !_uuid.hasMatch(deviceId) ||
        username == null ||
        !AuthenticationInputPolicy.isUsernameValid(username)) {
      throw StateError('Incomplete full-scope session.');
    }

    await database
        .into(database.accountSessions)
        .insertOnConflictUpdate(
          AccountSessionsCompanion.insert(
            // Stated rather than left to the column default. `singleton_id` is
            // the sole INTEGER PRIMARY KEY of a rowid table, so SQLite treats
            // it as an alias for the rowid and assigns `max(rowid) + 1` when an
            // insert omits it — the `DEFAULT 1` is never reached. Omitting it
            // therefore works exactly once per database and fails the
            // `singleton_id = 1` check on every write after that.
            singletonId: const Value(1),
            userIdCiphertext: Uint8List.fromList(utf8.encode(userId)),
            deviceIdCiphertext: Value(
              Uint8List.fromList(utf8.encode(deviceId)),
            ),
            scope: SessionScope.full.index,
            tokenMetadataCiphertext: Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'version': _formatVersion,
                  'token': token,
                }),
              ),
            ),
            serverProfileCiphertext: Uint8List.fromList(utf8.encode(username)),
            expiresAt: Value(merged.accessToken.expiresAt),
          ),
        );
    await writeLoginHint(LoginHint(username: username, deviceId: deviceId));
  }

  @override
  Future<void> clear() async {
    _memoryTokens = null;
    final database = await _database();
    if (database != null) {
      await _deleteSession(database);
    }
  }

  Future<LoginHint> readLoginHint() async {
    final memory = _memoryTokens;
    if (memory?.username != null) {
      return LoginHint(username: memory!.username, deviceId: memory.deviceId);
    }
    final database = await _database();
    if (database == null) {
      return const LoginHint();
    }
    final row =
        await (database.select(database.localPreferences)
              ..where((entry) => entry.preferenceKey.equals(_loginHintKey)))
            .getSingleOrNull();
    if (row == null || row.valueVersion != _formatVersion) {
      return const LoginHint();
    }
    try {
      final json = _decodeObject(row.valueCiphertext);
      final username = json['username'];
      final deviceId = json['device_id'];
      if (username is! String ||
          !AuthenticationInputPolicy.isUsernameValid(username) ||
          (deviceId != null &&
              (deviceId is! String || !_uuid.hasMatch(deviceId)))) {
        return const LoginHint();
      }
      return LoginHint(username: username, deviceId: deviceId as String?);
    } on Object {
      return const LoginHint();
    }
  }

  Future<void> writeLoginHint(LoginHint hint) async {
    final username = hint.username;
    if (username == null ||
        !AuthenticationInputPolicy.isUsernameValid(username)) {
      return;
    }
    final database = await _database();
    if (database == null) {
      throw StateError('Protected session storage is unavailable.');
    }
    await database
        .into(database.localPreferences)
        .insertOnConflictUpdate(
          LocalPreferencesCompanion.insert(
            preferenceKey: _loginHintKey,
            valueCiphertext: Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'username': username,
                  if (hint.deviceId != null) 'device_id': hint.deviceId,
                }),
              ),
            ),
            valueVersion: _formatVersion,
          ),
        );
  }

  Future<bool> hasUsableIdentity() async {
    final database = await _database();
    if (database == null) {
      return false;
    }
    return await database
            .select(database.accountIdentities)
            .getSingleOrNull() !=
        null;
  }

  Future<bool> hasCompletedSecureSetup() async {
    final database = await _database();
    if (database == null) {
      return false;
    }
    final userId = (await read())?.userId;
    if (userId == null) {
      return false;
    }
    final identity = await database
        .select(database.accountIdentities)
        .getSingleOrNull();
    // Scoped to this session's user, like every other reader of this table.
    // `enrollment_intent` is keyed by user id and holds one row per account
    // that has enrolled on this install, so an unscoped `getSingleOrNull`
    // throws `Bad state: Too many elements` the moment a second account has
    // ever reached enrollment — and a leftover row belonging to a *different*
    // account is not evidence about this one either way.
    final enrollment = await (database.select(
      database.enrollmentIntents,
    )..where((entry) => entry.userId.equals(userId))).getSingleOrNull();
    return identity?.recoveryStatus == 4 && enrollment == null;
  }

  void clearMemory() => _memoryTokens = null;

  Future<LocalDatabase?> _database() async {
    final result = await runtime.open();
    return result.fold(
      onSuccess: (database) => database,
      onFailure: (_) => null,
    );
  }

  Future<void> _deleteSession(LocalDatabase database) =>
      database.delete(database.accountSessions).go();

  Map<String, Object?> _decodeObject(Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, Object?>) {
      throw const FormatException();
    }
    return value;
  }
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
