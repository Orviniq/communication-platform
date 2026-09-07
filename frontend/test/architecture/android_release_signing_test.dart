import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The frozen Private Experimental Beta application ID.
///
/// This constant exists so that changing the application ID takes two edits in
/// two files and fails the suite in between. Android refuses an update whose
/// application ID or signing certificate differs from the installed app, and
/// this application cannot survive the resulting uninstall: it erases the
/// SQLCipher database and the envelope holding its key, the manifest disables
/// backup, and the database key has no exportable copy.
///
/// Re-frozen on 2026-09-07 for the move to chat.orviniq.com, which predates any
/// external Beta install: with nothing installed anywhere there was no update
/// path to break, so the value could move once. That exemption is spent.
const _frozenBetaApplicationId = 'com.orviniq.chat.beta';
const _productionApplicationId = 'com.orviniq.chat';

String _readIdentityProperty(String source, String key) {
  final match = RegExp(
    '^\\s*${RegExp.escape(key)}\\s*=\\s*(.*)\$',
    multiLine: true,
  ).firstMatch(source);
  return match?.group(1)?.trim() ?? '';
}

/// Returns the body of the brace-delimited block introduced by [header].
///
/// `create("beta")` appears both as a signing config and as a product flavor, so
/// these assertions have to address one exact block rather than the first text
/// that happens to look like it.
String _blockBody(String source, String header, {int from = 0}) {
  final start = source.indexOf(header, from);
  expect(start, isNot(-1), reason: 'Expected to find `$header`.');
  final open = source.indexOf('{', start + header.length);
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
  late String releaseIdentity;

  setUp(() {
    buildGradle = File('android/app/build.gradle.kts').readAsStringSync();
    releaseIdentity = File(
      'android/beta-release-identity.properties',
    ).readAsStringSync();
  });

  test('the Beta application ID is frozen and has one source of truth', () {
    expect(
      _readIdentityProperty(releaseIdentity, 'application.id'),
      _frozenBetaApplicationId,
      reason:
          'The Beta application ID is frozen at the first external install. '
          'Changing it forces every beta user through an uninstall that '
          'destroys their local state irrecoverably.',
    );
    // Gradle must read the frozen value rather than restate it, so the built
    // artifact and the verification tooling cannot drift apart.
    expect(buildGradle, contains('beta-release-identity.properties'));
    expect(buildGradle, contains('applicationId = betaApplicationId'));
    expect(
      buildGradle,
      isNot(contains('com.example.communication_platform.beta')),
    );
  });

  test('flavors keep distinct, coexisting application IDs', () {
    expect(
      buildGradle,
      contains('val productionApplicationId = "$_productionApplicationId"'),
    );
    expect(
      buildGradle,
      contains('applicationId = "\$productionApplicationId.development"'),
    );
    // Beta and Production must remain separate installs. They never upgrade
    // into one another, which is why they carry separate signing identities.
    expect(_frozenBetaApplicationId, isNot(_productionApplicationId));
    expect(_frozenBetaApplicationId, startsWith('$_productionApplicationId.'));
  });

  test('the release build type never inherits a signing identity', () {
    final body = _blockBody(
      buildGradle,
      'release',
      from: buildGradle.indexOf('buildTypes'),
    );

    // Production release must package unsigned so the OS cannot install it and
    // it cannot reach a user by accident.
    expect(body, contains('signingConfig = null'));
    expect(
      body,
      isNot(contains('signingConfigs.getByName("debug")')),
      reason:
          'A debug-signed release could never be updated by a real release.',
    );
    expect(body, isNot(contains('signingConfigs.debug')));
  });

  test('only the Beta flavor receives the persistent signing identity', () {
    final flavors = buildGradle.indexOf('productFlavors');
    expect(flavors, isNot(-1));

    final betaFlavor = _blockBody(buildGradle, 'create("beta")', from: flavors);
    expect(betaFlavor, contains('signingConfigs.getByName("beta")'));

    final productionFlavor = _blockBody(
      buildGradle,
      'create("production")',
      from: flavors,
    );
    expect(productionFlavor, isNot(contains('signingConfig')));

    final developmentFlavor = _blockBody(
      buildGradle,
      'create("development")',
      from: flavors,
    );
    expect(developmentFlavor, isNot(contains('signingConfig')));
  });

  test('Beta signing uses the schemes minSdk 24 actually needs', () {
    // v2 covers every device that can install this artifact; v3 records the
    // signer so a later rotation lineage remains possible on API 28 and above.
    expect(buildGradle, contains('enableV1Signing = false'));
    expect(buildGradle, contains('enableV2Signing = true'));
    expect(buildGradle, contains('enableV3Signing = true'));
    expect(buildGradle, contains('enableV4Signing = false'));
  });

  test('a missing signing identity fails the build instead of degrading', () {
    expect(buildGradle, contains('requireBetaReleaseSigning'));
    expect(buildGradle, contains('packageBetaRelease'));
    expect(buildGradle, contains('assembleBetaRelease'));
    expect(buildGradle, contains('bundleBetaRelease'));
  });

  test('a keystore path from a POSIX shell still resolves', () {
    // Git Bash reports /c/Users/... . Java does not treat that as absolute,
    // because a Windows absolute path needs a drive letter, so an unnormalized
    // value gets resolved against the properties file's own directory and
    // produces a doubled path that points nowhere.
    expect(buildGradle, contains('fun normalizeMaterialPath'));
    expect(buildGradle, contains(r'Regex("^/([A-Za-z])/(.*)$")'));
    expect(
      buildGradle,
      contains('normalizeMaterialPath(fromEnvironment.getValue("storeFile"))'),
      reason: 'The environment path needs the same treatment as the file one.',
    );

    // A keystore that cannot be found must say what was configured and what it
    // resolved to, rather than leaving AGP to report only the resolved path.
    expect(
      buildGradle,
      contains('The Beta keystore was configured but does not exist'),
    );
    expect(buildGradle, contains('validateSigningBetaRelease'));

    // The generator must write a path the JVM can use, with forward slashes:
    // a backslash is an escape character to Properties.load().
    final creator = File('tool/create_beta_keystore.sh').readAsStringSync();
    expect(
      creator,
      contains(r'storeFile=$(to_properties_path "$keystore_path")'),
    );
    final environment = File('tool/release_env.sh').readAsStringSync();
    expect(environment, contains('to_properties_path() { cygpath -m "\$1"; }'));
  });

  test('the Beta artifact cannot ship without native pinning', () {
    // Dart carries the origin and pins but cannot enforce them. Android does
    // that from a compiled resource, so a Beta build with no rendered trust
    // config trusts the system CA store and pins nothing while still looking
    // correctly provisioned.
    final builder = File('tool/build_beta_release.sh').readAsStringSync();
    expect(
      builder,
      contains('tool/render_beta_trust.sh'),
      reason:
          'Rendering on every release build is what stops the compiled trust '
          'from drifting from the values compiled into Dart.',
    );
    expect(builder, contains('BETA_PRIVATE_CA_PEM'));

    final renderer = File('tool/render_beta_trust.sh').readAsStringSync();
    // Pinning the wrong root either breaks every connection or trusts the
    // wrong issuer, so the CA file must match the provisioned fingerprint.
    expect(renderer, contains('does not match BETA_PRIVATE_CA_SHA256'));
    expect(renderer, contains('@@SERVER_HOST@@'));
    expect(renderer, contains('unsubstituted placeholder'));

    final verifier = File('tool/verify_release_apk.sh').readAsStringSync();
    expect(verifier, contains('xml/network_security_config'));
    expect(verifier, contains('domain-config'));
    expect(verifier, contains('raw/provisioned_private_ca'));

    // Rendered trust resources are deployment-specific provisioning artifacts,
    // and android/provisioning/README.md keeps them out of source control.
    final ignored = File('.gitignore').readAsStringSync();
    expect(
      ignored,
      contains('/android/app/src/beta/res/xml/network_security_config.xml'),
    );
    expect(
      ignored,
      contains('/android/app/src/beta/res/raw/provisioned_private_ca.'),
    );
  });

  test('no signing secret is present in source control', () {
    // Passwords reach Gradle only through the environment or an untracked
    // properties file; nothing secret may be literal in the build script.
    expect(buildGradle, contains('CP_BETA_KEYSTORE_PASSWORD'));
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

    final ignored = File('android/.gitignore').readAsStringSync();
    expect(ignored, contains('beta-signing.properties'));
    expect(ignored, contains('*.jks'));
    expect(ignored, contains('*.p12'));

    // The identity file is public on purpose and must stay that way.
    expect(releaseIdentity, isNot(contains('Password')));
    expect(releaseIdentity, isNot(contains('storePassword')));
  });

  test('the release identity records a certificate to verify against', () {
    final fingerprint = _readIdentityProperty(
      releaseIdentity,
      'signing.certificate.sha256',
    );
    if (fingerprint.isEmpty) {
      // Before the identity exists this is the expected state; the release
      // tooling refuses to publish an artifact while it is empty.
      return;
    }
    expect(
      fingerprint,
      matches(RegExp(r'^[0-9a-f]{64}$')),
      reason:
          'The fingerprint must be lower-case hex without separators, matching '
          'what apksigner reports, so comparisons cannot silently fail.',
    );
  });
}
