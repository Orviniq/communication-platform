import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart exposes only the narrow version-1 foundation boundary', () {
    final port = File(
      'lib/core/application/ports/crypto_core_port.dart',
    ).readAsStringSync();
    final bindings = File(
      'lib/shared/infrastructure/crypto/native/crypto_core_ffi.dart',
    ).readAsStringSync();
    final enrollmentBindings = File(
      'lib/shared/infrastructure/crypto/native/enrollment_crypto_ffi.dart',
    ).readAsStringSync();
    final pairwiseBindings = File(
      'lib/shared/infrastructure/crypto/native/pairwise_crypto_ffi.dart',
    ).readAsStringSync();
    final androidBuild = File('tool/build_rust_android.sh').readAsStringSync();

    expect(port, contains('capabilities()'));
    expect(port, contains('selfTest()'));
    expect(port, contains('close()'));
    for (final forbidden in const [
      'Uint8List',
      'dart:ffi',
      'encrypt(',
      'decrypt(',
      'sign(',
      'deriveKey(',
      'randomBytes(',
    ]) {
      expect(port, isNot(contains(forbidden)));
    }

    for (final symbol in const [
      'cp_crypto_v1_abi_version',
      'cp_crypto_v1_capabilities',
      'cp_crypto_v1_self_test',
    ]) {
      expect(bindings, contains("'$symbol'"));
    }
    expect(pairwiseBindings, contains("'cp_crypto_v1_pairwise_operation'"));
    expect(androidBuild, contains('cp_crypto_v1_pairwise_operation'));
    for (final symbol in const [
      'cp_crypto_v1_prepare_device',
      'cp_crypto_v1_prepare_first_identity',
      'cp_crypto_v1_restore_identity',
      'cp_crypto_v1_sanitize_identity',
      'cp_crypto_v1_cross_sign_device',
      'cp_crypto_v1_create_device_log_record',
      'cp_crypto_v1_inspect_device_log_record',
    ]) {
      expect(enrollmentBindings, contains("'$symbol'"));
      expect(androidBuild, contains(symbol));
    }
    expect(bindings, isNot(contains('last_error')));
    expect(bindings, isNot(contains('error_message')));
  });

  test('a target without the native core is unsupported, not reimplemented', () {
    // The one adapter fails closed off Android rather than reaching for a Dart
    // primitive, and no Dart cryptographic package is available to reach for.
    final adapter = File(
      'lib/shared/infrastructure/crypto/platform_crypto_core_native.dart',
    ).readAsStringSync();
    expect(adapter, contains('UnsupportedCryptoCore'));

    final violations = <String>[];
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) {
        continue;
      }
      final source = entry.readAsStringSync();
      for (final forbidden in const [
        'package:cryptography/',
        'package:pinenacl/',
        'package:pointycastle/',
      ]) {
        if (source.contains(forbidden)) {
          violations.add('${entry.path}: $forbidden');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('native boundary never logs or stringifies caught exceptions', () {
    final nativeDirectory = Directory(
      'lib/shared/infrastructure/crypto/native',
    );
    final violations = <String>[];
    for (final entry in nativeDirectory.listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) {
        continue;
      }
      final source = entry.readAsStringSync();
      final forbiddenPatterns = <(String, RegExp)>[
        ('print(', RegExp(r'(^|[^A-Za-z])print\(')),
        ('developer.log', RegExp(r'\bdeveloper\.log\b')),
        ('exception.toString()', RegExp(r'\bexception\.toString\(\)')),
        ('error.toString()', RegExp(r'\berror\.toString\(\)')),
      ];
      for (final (label, pattern) in forbiddenPatterns) {
        if (pattern.hasMatch(source)) {
          violations.add('${entry.path}: $label');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
