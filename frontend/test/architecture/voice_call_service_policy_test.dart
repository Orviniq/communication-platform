import 'dart:io';

import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of a call's microphone that only exist in the Android artifact
/// (`backend/CLIENT_CONTRACT.md` §N rule 11).
///
/// None of the Kotlin can run in a host test and no device is used here, so
/// what is asserted is what the source may and may not contain: the service's
/// type and export, the limits the platform puts on starting it and the order
/// they are checked in, what ends it, and what its entry shows. These are the
/// properties that would be silently wrong on a device rather than loudly
/// wrong in a test run.
void main() {
  const kotlinRoot =
      'android/app/src/main/kotlin/com/example/communication_platform';
  // Declarations only: the manifest says at length why the type is the one it
  // is, and an assertion that tripped over its own reasoning would push that
  // reasoning out of the file where it belongs.
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final voiceCallSource = File('$kotlinRoot/VoiceCall.kt').readAsStringSync();
  final voiceCall = _code(voiceCallSource);
  final activity = _code(
    File('$kotlinRoot/MainActivity.kt').readAsStringSync(),
  );

  group('what the artifact declares', () {
    test('the call service is `microphone` and unexported', () {
      final declaration = RegExp(
        r'<service\b[^>]*android:name="\.VoiceCallService"[^>]*>',
      ).firstMatch(manifest);
      expect(declaration, isNotNull, reason: 'the service is declared');
      final element = declaration!.group(0)!;
      expect(element, contains('android:foregroundServiceType="microphone"'));
      expect(
        element,
        contains('android:exported="false"'),
        reason: 'nothing outside this application may start it',
      );
      expect(
        element,
        endsWith('/>'),
        reason: 'no intent filter, so no other way in',
      );
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'),
        reason:
            'from Android 14 a `microphone` service cannot start without it',
      );
      expect(manifest, contains('android.permission.RECORD_AUDIO'));
    });

    test('the service promotes itself as `microphone`, and only that', () {
      expect(
        voiceCall,
        contains('ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE'),
      );
      for (final other in const [
        'FOREGROUND_SERVICE_TYPE_SPECIAL_USE',
        'FOREGROUND_SERVICE_TYPE_PHONE_CALL',
        'FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK',
        'FOREGROUND_SERVICE_TYPE_CAMERA',
        'FOREGROUND_SERVICE_TYPE_DATA_SYNC',
        'FOREGROUND_SERVICE_TYPE_MANIFEST',
      ]) {
        expect(voiceCall, isNot(contains(other)));
      }
      expect(
        'startForeground('.allMatches(voiceCall),
        hasLength(1),
        reason: 'one promotion, with the one type',
      );
    });

    test('the platform never restarts it', () {
      // A call lives in a Dart isolate. A process that died took the isolate
      // with it, and a restarted service would announce a call nobody holds.
      expect(voiceCall, contains('START_NOT_STICKY'));
      expect(voiceCall, isNot(contains('START_STICKY')));
      expect(voiceCall, isNot(contains('START_REDELIVER_INTENT')));
    });

    test('the release verifier records it, unexported', () {
      final verifier = File('tool/verify_release_apk.sh').readAsStringSync();
      expect(
        verifier,
        contains(
          '"service|com.example.communication_platform.VoiceCallService|false"',
        ),
      );
      expect(verifier, contains('declares exactly the 6 recorded components'));
    });
  });

  group('the platform limits, checked before the platform is asked', () {
    test('a start checks the permission and the foreground first', () {
      final start = _between(
        voiceCall,
        'private fun start(',
        'private fun stop(',
      );
      final granted = start.indexOf('isGranted(context)');
      final visible = start.indexOf('hostVisible');
      final asked = start.indexOf('ContextCompat.startForegroundService');
      expect(granted, greaterThan(-1));
      expect(visible, greaterThan(-1));
      expect(asked, greaterThan(granted));
      expect(asked, greaterThan(visible));
      expect(start, contains('MICROPHONE_NOT_GRANTED'));
      expect(start, contains('NOT_IN_FOREGROUND'));
      expect(
        'startForegroundService'.allMatches(voiceCall),
        hasLength(1),
        reason: 'the one start path',
      );
    });

    test('foreground means this activity is visible', () {
      expect(
        activity,
        contains('VoiceCall.onHostVisible(this, visible = true)'),
      );
      expect(
        activity,
        contains('VoiceCall.onHostVisible(this, visible = false)'),
      );
      expect(
        _between(activity, 'override fun onStart()', 'override fun onStop()'),
        contains('visible = true'),
      );
    });

    test('a start is answered when it lands, by name when it does not', () {
      final start = _between(
        voiceCall,
        'private fun start(',
        'private fun stop(',
      );
      expect(
        start,
        contains('startWaiters.add(result)'),
        reason:
            'onStartCommand runs later on the same looper, so an answer given '
            'when the start returns would report every start as a refusal',
      );
      expect(voiceCall, contains('TRANSITION_TIMEOUT_MS'));
      final service = voiceCall.substring(
        voiceCall.indexOf('class VoiceCallService'),
      );
      expect(service, contains('VoiceCall.onServiceStarted('));
      expect(service, contains('VoiceCall.onServiceRefused('));
      expect(
        voiceCall,
        contains('ForegroundServiceStartNotAllowedException'),
        reason: 'a background start is told apart from other refusals',
      );
    });

    test('a stop never lands before the start it follows', () {
      // The platform ends the process of an application that brings down a
      // service started for the foreground before it called startForeground
      // (`ActiveServices.bringDownServiceLocked`, AOSP frameworks/base).
      final stop = _between(
        voiceCall,
        'private fun stop(',
        'internal fun refusalFor(',
      );
      final starting = _between(stop, 'Phase.STARTING ->', 'Phase.RUNNING ->');
      expect(starting, contains('stopWhenStarted = true'));
      expect(starting, isNot(contains('stopService')));
    });
  });

  group('it ends with the call', () {
    test('the engine going away stops it', () {
      final cleanUp = _between(
        activity,
        'override fun cleanUpFlutterEngine(',
        'super.cleanUpFlutterEngine(',
      );
      expect(cleanUp, contains('VoiceCall::detach'));
      expect(
        _between(voiceCall, 'fun detach(', 'fun onHostVisible('),
        contains('stop('),
      );
    });

    test('removing the task stops it', () {
      expect(voiceCall, contains('override fun onTaskRemoved('));
      expect(
        _between(
          voiceCall,
          'internal fun onTaskRemoved(',
          'internal fun notification(',
        ),
        contains('stop(context, null)'),
      );
    });

    test('it is attached to the activity\'s engine and to no other', () {
      expect(
        activity,
        contains(
          'VoiceCall.attach(applicationContext, messenger, activity = this)',
        ),
      );
      for (final headless in const [
        'BackgroundDelivery.kt',
        'SustainedDelivery.kt',
      ]) {
        expect(
          File('$kotlinRoot/$headless').readAsStringSync(),
          isNot(contains('VoiceCall')),
          reason: 'a headless engine has no window and holds no call',
        );
      }
    });
  });

  group('what the entry shows', () {
    test('that a call is in progress, and nobody in it', () {
      expect(voiceCall, contains('setContentTitle(title)'));
      for (final forbidden in const [
        'setContentText',
        'setSubText',
        'setLargeIcon',
        'setNumber',
        'setUsesChronometer',
        'CallStyle',
        'MessagingStyle',
        'Person',
        'setShortcutId',
        'userId',
        'deviceId',
        'roomId',
      ]) {
        expect(voiceCall, isNot(contains(forbidden)));
      }
    });

    test('its text is reviewed and localized, never assembled natively', () {
      expect(voiceCall, contains('EXTRA_TITLE'));
      expect(voiceCall, contains('title.isEmpty() || channelName.isEmpty()'));
      expect(
        voiceCall,
        isNot(contains('R.string')),
        reason: 'Android string resources are a second, unreviewed catalogue',
      );
    });

    test('silent, low, shown at once, and the tap carries nothing', () {
      expect(voiceCall, contains('IMPORTANCE_LOW'));
      expect(
        voiceCall,
        isNot(contains('IMPORTANCE_MIN')),
        reason: 'MIN hides the status-bar icon that says a microphone is live',
      );
      expect(voiceCall, contains('setSilent(true)'));
      expect(voiceCall, contains('setVibrationEnabled(false)'));
      expect(voiceCall, contains('setShowWhen(false)'));
      expect(voiceCall, contains('setOngoing(true)'));
      expect(voiceCall, contains('FOREGROUND_SERVICE_IMMEDIATE'));
      expect(voiceCall, contains('VISIBILITY_PRIVATE'));
      expect(voiceCall, contains('setPublicVersion'));
      expect(voiceCall, contains('getLaunchIntentForPackage'));
      expect(voiceCall, contains('PendingIntent.FLAG_IMMUTABLE'));
      // The id keys the user's own settings for the entry. Changing it
      // discards them silently.
      expect(voiceCall, contains('NOTIFICATION_CHANNEL_ID = "voice-call"'));
      expect(
        File(
          'android/app/src/main/res/drawable/ic_call_in_progress.xml',
        ).existsSync(),
        isTrue,
      );
    });

    test('nothing is logged', () {
      expect(voiceCall, isNot(contains('Log.')));
      expect(voiceCall, isNot(contains('println')));
    });
  });

  group('the channel', () {
    test('both halves name the same channel, methods and answers', () {
      expect(voiceCallSource, contains('CHANNEL = "${VoiceCallChannel.name}"'));
      final dart = File(
        'lib/features/voice/infrastructure/platform_voice_call_channel.dart',
      ).readAsStringSync();
      for (final method in const [
        'requestMicrophone',
        'microphoneGranted',
        'openMicrophoneSettings',
        'start',
        'stop',
      ]) {
        expect(voiceCall, contains('"$method" ->'));
        expect(dart, contains("'$method'"));
      }
      for (final answer in const [
        'granted',
        'deniedPermanently',
        'started',
        'microphoneNotGranted',
        'notInForeground',
      ]) {
        expect(voiceCall, contains('"$answer"'));
        expect(dart, contains("'$answer'"));
      }
      // Read as a refusal on the Dart side by falling through, so it is
      // named only here.
      expect(voiceCall, contains('"denied"'));
      expect(voiceCall, contains('"refused"'));
    });
  });

  group('nothing asks before the join', () {
    test('the microphone is asked for in one place', () {
      final askers = [
        for (final entry in Directory(kotlinRoot).listSync())
          if (entry is File &&
              _code(
                entry.readAsStringSync(),
              ).contains('Manifest.permission.RECORD_AUDIO'))
            entry.uri.pathSegments.last,
      ];
      expect(askers, ['VoiceCall.kt']);
      expect(
        activity,
        contains(
          'VoiceCall.onRequestPermissionsResult(this, requestCode, grantResults)',
        ),
      );
    });

    test('the settings a refusal points to are this application\'s own page, '
        'and opening them asks nothing', () {
      final open = _between(
        voiceCall,
        'private fun openMicrophoneSettings(',
        'private fun start(',
      );
      expect(open, contains('Settings.ACTION_APPLICATION_DETAILS_SETTINGS'));
      expect(open, contains('context.packageName'));
      expect(open, isNot(contains('requestPermissions')));
      expect(open, isNot(contains('RECORD_AUDIO')));
    });

    test('no permission plugin', () {
      final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
      for (final plugin in const [
        'permission_handler',
        'flutter_permission',
        'simple_permissions',
      ]) {
        expect(pubspec, isNot(contains(plugin)));
      }
    });

    test('nothing in lib asks for the microphone but the join', () {
      // §N rule 11: at the join and at no other time. The join controller is
      // the port's one caller, composed beside the port; no screen reads the
      // provider, and nothing but the adapter sends the request.
      final readers = <String>[];
      final requesters = <String>[];
      final senders = <String>[];
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) {
          continue;
        }
        final path = entry.path.replaceAll(r'\', '/');
        final source = entry.readAsStringSync();
        if (source.contains('microphonePermissionProvider') &&
            path != 'lib/app/dependencies/voice_call_service_providers.dart') {
          readers.add(path);
        }
        if (source.contains('.request()')) {
          requesters.add(path);
        }
        if (source.contains("'requestMicrophone'")) {
          senders.add(path);
        }
      }
      expect(readers, isEmpty);
      expect(requesters, [
        'lib/features/voice/application/voice_call_controller.dart',
      ]);
      expect(senders, [
        'lib/features/voice/infrastructure/platform_voice_call_channel.dart',
      ]);
      // The composition hands the port to the join and to the service's own
      // check before a start, which never asks.
      final composition = File(
        'lib/app/dependencies/voice_call_service_providers.dart',
      ).readAsStringSync();
      expect(
        'ref.watch(microphonePermissionProvider)'.allMatches(composition),
        hasLength(2),
      );
      expect(composition, contains('VoiceCallController('));
    });
  });
}

/// Kotlin with its comments removed. The sources record at length why the
/// rejected choices were rejected, and an assertion that tripped over that
/// reasoning would push it out of the file where it belongs.
String _code(String kotlin) => kotlin
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

String _between(String source, String start, String end) {
  final from = source.indexOf(start);
  expect(from, greaterThan(-1), reason: 'missing $start');
  final to = source.indexOf(end, from + start.length);
  expect(to, greaterThan(from), reason: 'missing $end after $start');
  return source.substring(from, to);
}
