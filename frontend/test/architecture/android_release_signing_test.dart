import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _productionApplicationId = 'com.orviniq.chat';

/// Returns the body of the brace-delimited block introduced by [header].
///
/// A flavor or build-type name can also appear in a comment or a task name, so
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

  setUp(() {
    buildGradle = File('android/app/build.gradle.kts').readAsStringSync();
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
  });

  test('development and production are the only flavors', () {
    // The beta flavor went with the closed-beta MLS core, and its frozen
    // application ID and persistent signing identity went with it. A flavor
    // that comes back brings an installable identity along, so it has to be a
    // decision that fails here first.
    final flavors = _blockBody(buildGradle, 'productFlavors');
    expect(
      RegExp(
        r'create\("([^"]+)"\)',
      ).allMatches(flavors).map((match) => match.group(1)).toList(),
      <String>['development', 'production'],
    );
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

  test('no flavor receives a signing identity', () {
    // A persistent signing identity is created once and can never be replaced
    // without destroying every install it signed, so none may appear without
    // an explicit release decision.
    expect(buildGradle, isNot(contains('signingConfigs')));
    for (final flavor in const ['development', 'production']) {
      expect(
        _blockBody(buildGradle, 'create("$flavor")'),
        isNot(contains('signingConfig')),
        reason: 'the $flavor flavor must not be signed by the build',
      );
    }
  });

  test('no signing secret is present in source control', () {
    // Nothing secret may be literal in the build script.
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

    // Keystores and the properties file that carried the deleted beta
    // flavor's keystore passwords outlive the build that read them.
    final ignored = File('android/.gitignore').readAsStringSync();
    expect(ignored, contains('beta-signing.properties'));
    expect(ignored, contains('*.jks'));
    expect(ignored, contains('*.p12'));
  });
}
