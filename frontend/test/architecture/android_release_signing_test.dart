import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The production application ID, permanent under ADR-076 D2.
const _productionApplicationId = 'com.orviniq.chat';

/// The four variables that name the production key together (ADR-076 D5).
const _signingEnvironmentNames = <String>[
  'CP_PRODUCTION_KEYSTORE_FILE',
  'CP_PRODUCTION_KEYSTORE_PASSWORD',
  'CP_PRODUCTION_KEY_ALIAS',
  'CP_PRODUCTION_KEY_PASSWORD',
];

/// The tasks that must not run before the fail-closed guard (ADR-076 D6).
const _guardedTasks = <String>[
  'validateSigningProductionRelease',
  'packageProductionRelease',
  'assembleProductionRelease',
  'bundleProductionRelease',
];

/// Returns the value of [key] in the Java properties [source], or ''.
String _property(String source, String key) {
  final match = RegExp(
    '^[ \\t]*${RegExp.escape(key)}[ \\t]*=[ \\t]*([^\\r\\n]*?)[ \\t\\r]*\$',
    multiLine: true,
  ).firstMatch(source);
  return match?.group(1) ?? '';
}

/// Returns the body of the brace-delimited block introduced by [header].
///
/// `create("production")` names both a signing config and a product flavor, so
/// these assertions have to address one exact block rather than the first text
/// that happens to look like it. The block opens at the first `{` from the
/// start of [header], which may end with that brace itself.
String _blockBody(String source, String header, {int from = 0}) {
  final start = source.indexOf(header, from);
  expect(start, isNot(-1), reason: 'Expected to find `$header`.');
  final open = source.indexOf('{', start);
  expect(open, isNot(-1), reason: 'Expected `{` after `$header`.');

  var depth = 0;
  for (var index = open; index < source.length; index++) {
    if (source[index] == '{') {
      depth++;
    } else if (source[index] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(open + 1, index);
      }
    }
  }
  fail('Unbalanced braces after `$header`.');
}

void main() {
  late String buildGradle;
  late String identity;
  late String verifier;
  late String ciShell;
  late String ciPowerShell;

  setUp(() {
    buildGradle = File('android/app/build.gradle.kts').readAsStringSync();
    identity = File(
      'android/production-release-identity.properties',
    ).readAsStringSync();
    verifier = File('tool/verify_release_apk.sh').readAsStringSync();
    ciShell = File('tool/ci.sh').readAsStringSync();
    ciPowerShell = File('tool/ci.ps1').readAsStringSync();
  });

  String flavor(String name) => _blockBody(
    buildGradle,
    'create("$name")',
    from: buildGradle.indexOf('productFlavors {'),
  );

  test('the identity file is the one source of the application ID', () {
    expect(_property(identity, 'application.id'), _productionApplicationId);

    // Gradle reads the committed value rather than restating it, and fails
    // when the file or the value is missing, so the built artifact and the
    // verifier cannot disagree about which application this is.
    expect(
      buildGradle,
      contains('rootProject.file("production-release-identity.properties")'),
    );
    expect(buildGradle, contains('if (!productionReleaseIdentityFile.isFile)'));
    expect(buildGradle, contains('identity.getProperty("application.id")'));
    expect(buildGradle, contains('application.id is missing from'));
    expect(buildGradle, isNot(contains('"$_productionApplicationId"')));
    expect(buildGradle, isNot(contains('val productionApplicationId = "')));

    expect(
      flavor('production'),
      contains('applicationId = productionApplicationId'),
    );
    expect(
      flavor('development'),
      contains(r'applicationId = "$productionApplicationId.development"'),
    );

    // The verifier reads the same file, through release_env.sh.
    expect(
      verifier,
      contains(
        r'readonly expected_application_id="$production_application_id"',
      ),
    );
    expect(verifier, isNot(contains('productionApplicationId')));
  });

  test('development and production are the only flavors', () {
    // The beta flavor went with the closed-beta MLS core, and its frozen
    // application ID and persistent signing identity went with it. A flavor
    // that comes back brings an installable identity along, so it has to be a
    // decision that fails here first.
    final flavors = _blockBody(buildGradle, 'productFlavors {');
    expect(
      RegExp(
        r'create\("([^"]+)"\)',
      ).allMatches(flavors).map((match) => match.group(1)).toList(),
      <String>['development', 'production'],
    );
  });

  test('only the production flavor receives the signing identity', () {
    final signingConfigs = _blockBody(buildGradle, 'signingConfigs {');
    expect(
      RegExp(
        r'create\("([^"]+)"\)',
      ).allMatches(signingConfigs).map((match) => match.group(1)).toList(),
      <String>['production'],
    );
    // No material, no signing config at all.
    expect(signingConfigs, contains('if (productionSigningMaterial != null)'));

    expect(
      flavor('production'),
      contains('if (productionSigningMaterial != null)'),
    );
    expect(
      flavor('production'),
      contains('signingConfig = signingConfigs.getByName("production")'),
    );
    expect(flavor('development'), isNot(contains('signingConfig')));

    // Every signing config assignment in the file is one of exactly two: the
    // production flavor's key, and the release build type's null.
    expect(
      RegExp(
        r'signingConfig = (.+)',
      ).allMatches(buildGradle).map((match) => match.group(1)!.trim()).toList(),
      <String>['signingConfigs.getByName("production")', 'null'],
    );
  });

  test('the release build type never takes a signing identity', () {
    final release = _blockBody(
      buildGradle,
      'release {',
      from: buildGradle.indexOf('buildTypes {'),
    );

    // A build type's own signing config wins over the flavor's, so anything
    // here would reach every flavor's release build.
    expect(release, contains('signingConfig = null'));
    expect(
      release,
      isNot(contains('signingConfigs.getByName("debug")')),
      reason:
          'A debug-signed release could never be updated by a real release.',
    );
    expect(release, isNot(contains('signingConfigs.debug')));
  });

  test('the production key signs with the schemes minSdk 24 needs', () {
    // v2 covers every device that can install this artifact; v3 records the
    // signer so a later rotation lineage remains possible on API 28 and above.
    final production = _blockBody(
      buildGradle,
      'create("production")',
      from: buildGradle.indexOf('signingConfigs {'),
    );
    expect(production, contains('enableV1Signing = false'));
    expect(production, contains('enableV2Signing = true'));
    expect(production, contains('enableV3Signing = true'));
    expect(production, contains('enableV4Signing = false'));
    expect(production, contains('storeFile = productionSigningStoreFile'));
  });

  test('a production release without the key fails closed', () {
    expect(
      buildGradle,
      contains('tasks.register("requireProductionReleaseSigning")'),
    );
    final wiring = _blockBody(buildGradle, 'tasks.configureEach {');
    expect(wiring, contains('dependsOn(requireProductionReleaseSigning)'));
    for (final task in _guardedTasks) {
      expect(wiring, contains('"$task",'));
    }

    final guard = _blockBody(
      buildGradle,
      'tasks.register("requireProductionReleaseSigning")',
    );
    // No material and no unsigned request.
    expect(
      guard,
      contains('productionSigningMaterial == null && !unsignedBuildRequested'),
    );
    // Both at once.
    expect(
      guard,
      contains('productionSigningMaterial != null && unsignedBuildRequested'),
    );
    // A configured keystore that does not exist names what was configured and
    // what it resolved to, rather than leaving AGP to report only the latter.
    expect(guard, contains('productionSigningStoreFile?.isFile != true'));
    expect(
      guard,
      contains(
        r'configured: ${productionSigningMaterial.getValue("storeFile")}',
      ),
    );
    expect(
      guard,
      contains(r'resolved:   ${productionSigningStoreFile?.absolutePath}'),
    );
    expect(guard, contains('restore it from one of its encrypted'));

    // The first key to reach a device is the only key that can update it, so
    // no failure may point anyone at making another.
    expect(guard, isNot(contains('create_production_keystore')));
    expect(guard, isNot(contains('keytool')));
    expect(
      RegExp(
        r'new key|create a key|generate',
        caseSensitive: false,
      ).hasMatch(guard),
      isFalse,
    );
  });

  test('an unsigned package is an explicit request', () {
    expect(
      buildGradle,
      contains('System.getenv("CP_PRODUCTION_UNSIGNED_BUILD")'),
    );
    expect(buildGradle, contains('productionUnsignedBuildRequest == "1"'));
    expect(
      buildGradle,
      contains('CP_PRODUCTION_UNSIGNED_BUILD must be 1 or unset'),
    );
  });

  test('signing material comes only from the named variables', () {
    expect(
      buildGradle,
      contains('System.getenv("CP_PRODUCTION_SIGNING_PROPERTIES")'),
    );
    for (final name in _signingEnvironmentNames) {
      expect(buildGradle, contains('"$name"'));
    }
    expect(
      buildGradle,
      contains('Incomplete production signing environment. Missing:'),
    );
    expect(buildGradle, contains('Production signing material is named twice'));

    // Key material inside the working tree is one `git add -A` away from a
    // commit, so nothing falls back to a file in the repository.
    expect(buildGradle, isNot(contains('?: rootProject.file(')));
    expect(buildGradle, isNot(contains('signing.properties")')));
    expect(buildGradle, isNot(contains('CP_BETA_')));
  });

  test('a material path from a POSIX shell resolves, a relative one fails', () {
    // Git Bash reports /c/Users/... . Java does not treat that as absolute,
    // because a Windows absolute path needs a drive letter, so an unnormalized
    // value would resolve against some other directory and point nowhere.
    expect(buildGradle, contains('fun normalizeMaterialPath'));
    expect(buildGradle, contains(r'Regex("^/([A-Za-z])/(.*)$")'));
    expect(
      buildGradle,
      contains('normalizeMaterialPath(fromEnvironment.getValue("storeFile"))'),
    );
    expect(buildGradle, contains('File(normalizeMaterialPath(configured))'));
    expect(
      buildGradle,
      contains('CP_PRODUCTION_KEYSTORE_FILE must be an absolute path'),
    );
    expect(
      buildGradle,
      contains('CP_PRODUCTION_SIGNING_PROPERTIES must be an absolute path'),
    );
  });

  test('no signing secret is present in source control', () {
    // Passwords reach Gradle only through the environment or an untracked
    // properties file; nothing secret may be literal in the build script.
    expect(
      RegExp(r'storePassword\s*=\s*"').hasMatch(buildGradle),
      isFalse,
      reason: 'A literal store password would be a committed secret.',
    );
    expect(
      RegExp(r'keyPassword\s*=\s*"').hasMatch(buildGradle),
      isFalse,
      reason: 'A literal key password would be a committed secret.',
    );

    final ignored = File(
      'android/.gitignore',
    ).readAsStringSync().split('\n').map((line) => line.trim());
    expect(
      ignored,
      containsAll(<String>[
        'production-signing.properties',
        '*.p12',
        '**/*.jks',
        '**/*.keystore',
      ]),
    );
  });

  test('CI builds production unsigned, without the key, and says so', () {
    expect(
      ciShell,
      contains(
        'CP_PRODUCTION_UNSIGNED_BUILD=1 flutter build apk --release '
        '--flavor production',
      ),
    );
    expect(
      ciShell,
      contains(r'/^CP_PRODUCTION_(KEYSTORE_|KEY_)[A-Za-z0-9_]*=/'),
    );
    expect(ciShell, contains('/^CP_PRODUCTION_SIGNING_PROPERTIES=/'));
    expect(ciShell, contains(r'unset "$name"'));
    expect(ciShell, contains('verify_release_apk.sh --production-unsigned'));
    expect(ciShell, isNot(contains('verify_release_apk.sh --production ')));

    expect(ciPowerShell, contains(r"$env:CP_PRODUCTION_UNSIGNED_BUILD = '1'"));
    expect(ciPowerShell, contains("'^CP_PRODUCTION_(KEYSTORE_|KEY_)'"));
    expect(ciPowerShell, contains("'CP_PRODUCTION_SIGNING_PROPERTIES'"));
    expect(
      ciPowerShell,
      contains(r'Remove-Item -Path "Env:$($variable.Name)"'),
    );
    expect(ciPowerShell, contains("'--production-unsigned',"));
    expect(ciPowerShell, isNot(contains("'--production',")));
  });

  test('the verifier gates a distributable artifact on the recorded key', () {
    expect(verifier, contains('--production | --production-unsigned)'));

    // --production: apksigner verifies, one signer, v2 and v3 without v1, no
    // debug certificate, and the recorded fingerprint, which may not be empty.
    expect(verifier, contains(r'[[ "$signature_verified" -eq 1 ]]'));
    expect(verifier, contains("report_value 'Number of signers'"));
    expect(verifier, contains(r'[[ "$signer_count" == "1" ]]'));
    expect(verifier, contains(r'[[ "$v2_state" == "true" ]]'));
    expect(verifier, contains(r'[[ "$v3_state" == "true" ]]'));
    expect(verifier, contains(r'[[ "$v1_state" == "false" ]]'));
    expect(verifier, contains('*"Android Debug"*)'));
    expect(
      verifier,
      contains(r'if [[ -z "$production_certificate_sha256" ]]; then'),
    );
    expect(
      verifier,
      contains(
        r'[[ "$actual_fingerprint" == "$production_certificate_sha256" ]]',
      ),
    );

    // --production-unsigned: only apksigner's own verdict counts as unsigned.
    expect(verifier, contains(r'[[ "$signature_verified" -eq 0 ]]'));
    expect(verifier, contains("grep -q 'DOES NOT VERIFY'"));

    // Both modes keep what the artifact declares and the beta symbol refusal.
    expect(verifier, contains('expected_permissions='));
    expect(verifier, contains('expected_components='));
    expect(verifier, contains('exported_components='));
    expect(verifier, contains(r'grep -qx "$beta_symbol"'));
  });
}
