import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The production application ID, permanent under ADR-076 D2.
///
/// Android updates an install only when the application ID and the signing
/// certificate both match, and this client cannot survive the uninstall that a
/// mismatch forces, so a change to either has to fail here first.
const _productionApplicationId = 'com.orviniq.chat';

/// Returns the value of [key] in the Java properties [source], or ''.
String _property(String source, String key) {
  final match = RegExp(
    '^[ \\t]*${RegExp.escape(key)}[ \\t]*=[ \\t]*([^\\r\\n]*?)[ \\t\\r]*\$',
    multiLine: true,
  ).firstMatch(source);
  return match?.group(1) ?? '';
}

/// Every key that the Java properties [source] defines.
Set<String> _propertyKeys(String source) => RegExp(
  r'^[ \t]*([^#!\s=:][^=:\s]*)[ \t]*[=:]',
  multiLine: true,
).allMatches(source).map((match) => match.group(1)!).toSet();

/// The trimmed lines of [source], whatever its line endings.
List<String> _lines(String source) =>
    source.split('\n').map((line) => line.trim()).toList();

/// Expects every one of [markers] in [source], each before [boundary].
void _expectAllBefore(String source, List<String> markers, String boundary) {
  final end = source.indexOf(boundary);
  expect(end, isNot(-1), reason: 'Expected to find `$boundary`.');
  for (final marker in markers) {
    final at = source.indexOf(marker);
    expect(at, isNot(-1), reason: 'Expected to find `$marker`.');
    expect(at, lessThan(end), reason: '`$marker` must run before `$boundary`.');
  }
}

void main() {
  late String identity;
  late String environment;
  late String creator;
  late String backup;

  setUp(() {
    identity = File(
      'android/production-release-identity.properties',
    ).readAsStringSync();
    environment = File('tool/release_env.sh').readAsStringSync();
    creator = File('tool/create_production_keystore.sh').readAsStringSync();
    backup = File('tool/backup_production_keystore.sh').readAsStringSync();
  });

  group('the production identity file', () {
    test('names the production application ID and nothing secret', () {
      expect(_property(identity, 'application.id'), _productionApplicationId);
      // Every value in this file is public, so it defines these two keys and
      // never a password, a keystore or an alias.
      expect(_propertyKeys(identity), <String>{
        'application.id',
        'signing.certificate.sha256',
      });
      expect(identity, isNot(contains('storePassword')));
      expect(identity, isNot(contains('keyPassword')));
    });

    test('records no fingerprint yet, or a lower-case SHA-256 digest', () {
      final fingerprint = _property(identity, 'signing.certificate.sha256');
      if (fingerprint.isEmpty) {
        // The expected state until the owner creates the production key.
        return;
      }
      expect(
        fingerprint,
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason:
            'apksigner reports lower-case hex without separators, so any other '
            'form would make every comparison fail.',
      );
    });
  });

  group('the release environment', () {
    test('reads the identity from the tracked file', () {
      expect(
        environment,
        contains(
          'readonly production_identity_file='
          r'"$android_root/production-release-identity.properties"',
        ),
      );
      expect(
        environment,
        contains(r'production_application_id="$(read_identity_property'),
      );
      expect(
        environment,
        contains(r'production_certificate_sha256="$(read_identity_property'),
      );
      expect(environment, contains('normalize_fingerprint() {'));
    });

    test('writes material paths in a form a JVM can open', () {
      // Java reads /c/... as a relative path, and Properties.load() reads a
      // backslash as an escape, so a Windows path goes out as C:/... .
      expect(
        environment,
        contains(r'to_properties_path() { cygpath -m "$1"; }'),
      );
    });

    test('resolves a JDK home that JAVA_HOME can carry on Windows', () {
      // apksigner's launcher rejects JAVA_HOME=/c/..., which failed the beta
      // release build at verification unless C:/... was exported by hand.
      expect(environment, contains(r'candidate="$(cygpath -m "$candidate")"'));
      expect(environment, contains(r'[[ -n "$major" && "$major" -ge 17 ]]'));
      expect(
        environment,
        contains(
          r'MSYS_NO_PATHCONV=1 "$jdk_home/bin/keytool$release_exe_suffix" "$@"',
        ),
      );
    });

    test('refuses a path inside the repository, in any letter case', () {
      expect(
        environment,
        contains(r'repository_root="$(cd "$frontend_root/.." && pwd -P)"'),
      );
      expect(
        environment,
        contains(r'[[ "$candidate" == "$root" || "$candidate" == "$root"/* ]]'),
      );
      expect(environment, contains("tr '[:upper:]' '[:lower:]'"));
    });
  });

  group('the keystore creator', () {
    test('creates exactly the identity ADR-076 decides', () {
      expect(
        creator,
        contains('readonly key_alias="communication-platform-production"'),
      );
      expect(creator, isNot(contains('--alias')));
      for (final parameter in const [
        '-keyalg RSA',
        '-keysize 4096',
        '-sigalg SHA384withRSA',
        '-validity 10000',
        '-storetype PKCS12',
        r'-dname "CN=$identity_application_id, OU=Production, '
            r'O=Communication Platform"',
      ]) {
        expect(creator, contains(parameter));
      }
    });

    test('keeps the key material outside the repository', () {
      expect(
        creator,
        contains(r'$HOME/.communication-platform/production-signing}'),
      );
      expect(
        creator,
        contains(
          r'$default_material_root/communication-platform-production.p12}',
        ),
      );
      expect(
        creator,
        contains(r'$default_material_root/production-signing.properties}'),
      );
      expect(
        creator,
        contains(
          r'refuse_repository_path "The keystore path" "$keystore_path"',
        ),
      );
      expect(
        creator,
        contains(
          r'refuse_repository_path "The properties path" "$properties_path"',
        ),
      );
    });

    test('refuses to overwrite or to record a second identity', () {
      // Each refusal runs before the passphrase is asked for, so a refused run
      // creates nothing.
      _expectAllBefore(creator, const [
        r'refuse_repository_path "The keystore path"',
        r'refuse_repository_path "The properties path"',
        r'if [[ -e "$keystore_path" ]]; then',
        r'if [[ -e "$properties_path" ]]; then',
        r'if [[ -n "$identity_certificate_sha256" ]]; then',
        'require_jdk',
      ], 'read -r -s');
    });

    test('can be proven against a scratch copy of the identity file', () {
      expect(creator, contains(r'identity_file="$production_identity_file"'));
      expect(
        creator,
        contains(r'--identity-file) identity_file="$2"; shift 2 ;;'),
      );
      expect(creator, contains(r'mv "$tmp_identity" "$identity_file"'));
    });

    test('hands the passphrase to keytool only through the environment', () {
      expect(RegExp('read -r -s ').allMatches(creator), hasLength(2));
      expect(creator, contains(r'[[ "${#passphrase}" -ge 16 ]]'));
      expect(creator, contains('set +x'));
      expect(creator, contains('-storepass:env CP_KEYSTORE_PASSPHRASE'));
      expect(creator, contains('-keypass:env CP_KEYSTORE_PASSPHRASE'));
      expect(
        RegExp(
          r'-(store|key)pass(?!:env CP_KEYSTORE_PASSPHRASE\b)',
        ).hasMatch(creator),
        isFalse,
        reason: 'Any other form puts the passphrase on a command line.',
      );

      // The passphrase is expanded only to compare, measure and check it, to
      // hand it to keytool, and to write the untracked properties file.
      final expansions = _lines(creator).where(
        (line) => RegExp(
          r'\$\{?#?(passphrase|passphrase_confirmation|CP_KEYSTORE_PASSPHRASE)\b',
        ).hasMatch(line),
      );
      expect(expansions, <String>[
        r'[[ "$passphrase" == "$passphrase_confirmation" ]] || '
            r'fail "Passphrases do not match."',
        r'[[ "${#passphrase}" -ge 16 ]] || '
            r'fail "Passphrase must be at least 16 characters."',
        r'passphrase_fits_properties "$passphrase" ||',
        r'export CP_KEYSTORE_PASSPHRASE="$passphrase"',
        r'storePassword=$CP_KEYSTORE_PASSPHRASE',
        r'keyPassword=$CP_KEYSTORE_PASSPHRASE',
      ]);
    });

    test('refuses a passphrase the properties file would alter', () {
      // Properties.load() decodes ISO 8859-1, drops a backslash as an escape
      // and skips the spaces that open a value, so a build would present a
      // different passphrase from the one the keystore was created with.
      expect(creator, contains('local LC_ALL=C'));
      expect(
        creator,
        contains(
          r'[[ "$1" != *[!\ -~]* && "$1" != *\\* && "$1" != " "* && '
          r'"$1" != *" " ]]',
        ),
      );
      expect(RegExp('IFS= read -r -s ').allMatches(creator), hasLength(2));
    });

    test('writes storeFile as an absolute path a JVM can open', () {
      expect(
        creator,
        contains(r'keystore_path="$(absolute_path "$keystore_path")"'),
      );
      expect(
        creator,
        contains(r'storeFile=$(to_properties_path "$keystore_path")'),
      );
    });
  });

  group('the keystore backup', () {
    test('encrypts with AES-256 behind a salted, iterated SHA-512 S2K', () {
      for (final option in const [
        'gpg --symmetric',
        '--cipher-algo AES256',
        '--s2k-digest-algo SHA512',
        '--s2k-mode 3',
        '--s2k-count 65011712',
      ]) {
        expect(backup, contains(option));
      }
      // --digest-algo names the signature hash and leaves the passphrase hash
      // at GnuPG's default, so it cannot stand in for --s2k-digest-algo.
      expect(
        _lines(backup).where(
          (line) => !line.startsWith('#') && line.contains('--digest-algo'),
        ),
        isEmpty,
      );
    });

    test('refuses before it copies or writes anything', () {
      _expectAllBefore(backup, const [
        r'refuse_repository_path "The backup directory" "$output_directory"',
        'command -v gpg >/dev/null 2>&1 || fail',
        r'[[ -f "$keystore_path" ]] || fail',
        r'[[ -n "$production_certificate_sha256" ]] ||',
        r'[[ ! -e "$existing" ]] || fail',
      ], r'mkdir -p "$output_directory"');
    });

    test('writes a restore card, a checksum and a public label', () {
      expect(backup, contains(r'cat > "$payload/RESTORE.txt" <<CARD'));
      expect(
        backup,
        contains(
          r'sha256sum "$backup_name.tar.gz.gpg" > '
          r'"$backup_name.tar.gz.gpg.sha256"',
        ),
      );
      expect(
        backup,
        contains(r'cat > "$output_directory/$backup_name.txt" <<LABEL'),
      );
      expect(
        backup,
        contains('readonly key_alias="communication-platform-production"'),
      );
    });
  });

  test('git ignores every kind of signing material', () {
    final ignored = _lines(File('android/.gitignore').readAsStringSync());
    expect(
      ignored,
      containsAll(<String>[
        'production-signing.properties',
        'beta-signing.properties',
        '*.p12',
        '**/*.jks',
        '**/*.keystore',
      ]),
    );
  });
}
