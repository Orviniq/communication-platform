import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('messaging synchronization has no foreign push', () {
    final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
    final adapters = File(
      'lib/features/synchronization/infrastructure/sync_platform_adapters.dart',
    ).readAsStringSync();

    expect(pubspec, isNot(contains('firebase')));
    expect(pubspec, isNot(contains('firebase_messaging')));
    expect(adapters, contains('AndroidPollingScheduler'));
    expect(adapters, contains('scheduleBestEffort'));
    expect(adapters, contains('headless callback'));
  });

  test('the declared foreground service type is the accurate one', () {
    // ADR-046 held that `remoteMessaging` would be a semantic overstatement -
    // it describes carrying text messages between a user's devices, not
    // holding a connection to this application's own server - and that
    // `dataSync` is both an overstatement and technically unusable, being
    // capped at six hours a day and forbidden from a boot receiver. ADR-051
    // built the service and re-derived that conclusion rather than inheriting
    // it. Both prohibitions therefore stand, and the one type that is declared
    // is the one whose documented definition actually fits.
    // Comments are stripped first. The manifest explains *why* the other types
    // were rejected, and an assertion that tripped over its own reasoning would
    // push that reasoning out of the file it belongs in.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    expect(manifest, isNot(contains('remoteMessaging')));
    expect(manifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));
    expect(manifest, isNot(contains('dataSync')));
    expect(manifest, isNot(contains('systemExempted')));
    expect(manifest, isNot(contains('shortService')));
    // Voice added the second, and its type is the accurate one too: a call's
    // service keeps the microphone and nothing else (§N rule 11), which is
    // what the platform defines `microphone` for.
    expect(
      'android:foregroundServiceType'.allMatches(manifest),
      hasLength(2),
      reason:
          'two services in this artifact run in the foreground: sustained '
          'delivery and a call',
    );
    expect(manifest, contains('android:foregroundServiceType="specialUse"'));
    expect(manifest, contains('android:foregroundServiceType="microphone"'));
    expect(
      manifest,
      contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'),
      reason:
          'the type Android defines for cases its other types do not cover '
          'requires the case to be stated, and this artifact states it',
    );
  });
}
