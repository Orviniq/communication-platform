import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android storage uses Keystore wrapping, SQLCipher, and no backup', () {
    // The boundary is Context-bound rather than Activity-bound since ADR-049,
    // because a deferred catch-up runs in a headless engine that has no
    // activity and a channel handler registered in `configureFlutterEngine`
    // exists only on the engine that registered it.
    final storage = File(
      'android/app/src/main/kotlin/com/example/communication_platform/'
      'ProtectedStorageChannel.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/example/communication_platform/MainActivity.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(storage, contains('AndroidKeyStore'));
    expect(storage, contains('AES/GCM/NoPadding'));
    expect(storage, contains('setIsStrongBoxBacked(true)'));
    expect(storage, contains('noBackupFilesDir'));
    expect(storage, isNot(contains('Log.')));
    expect(activity, isNot(contains('Log.')));
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="false"'));
    expect(pubspec, contains('source: sqlcipher'));
  });

  test('there is exactly one implementation of the storage key', () {
    // Two entry points reach this boundary now. Duplicating it for the second
    // one is how a database key ends up wrapped under one alias and unwrapped
    // under another, so `MainActivity` delegates and holds no copy.
    final activity = File(
      'android/app/src/main/kotlin/com/example/communication_platform/MainActivity.kt',
    ).readAsStringSync();
    for (final forbidden in const [
      'AndroidKeyStore',
      'AES/GCM/NoPadding',
      'KeyGenParameterSpec',
      'noBackupFilesDir',
    ]) {
      expect(
        activity,
        isNot(contains(forbidden)),
        reason: 'the protected-storage boundary lives in one file only',
      );
    }
    expect(activity, contains('ProtectedStorageChannel'));
  });

  test('platform APIs do not leak into domain or application layers', () {
    final violations = <String>[];
    for (final root in [
      Directory('lib/features/local_storage/domain'),
      Directory('lib/features/local_storage/application'),
    ]) {
      for (final entry in root.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final source = entry.readAsStringSync();
        for (final forbidden in const [
          'MethodChannel',
          'dart:js_interop',
          'package:drift/',
          'AndroidKeyStore',
          'indexedDB',
        ]) {
          if (source.contains(forbidden)) {
            violations.add('${entry.path}: $forbidden');
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
