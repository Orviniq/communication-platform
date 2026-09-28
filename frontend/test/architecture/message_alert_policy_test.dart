import 'dart:io';

import 'package:communication_platform/features/notifications/infrastructure/platform_message_alert_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of the alert that only exist in the Android artifact.
///
/// The Kotlin here cannot be exercised by a host test, and no device is
/// available, so what is asserted is what the source may and may not contain.
/// These are the properties that would be silently wrong on a device rather
/// than loudly wrong in a test run: what the notification reveals, what the
/// tap carries, and which permissions the artifact asks for.
void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  // The alert is Context-bound rather than Activity-bound since ADR-049: a
  // deferred catch-up runs in a headless engine with no activity, and an alert
  // that only existed while an activity did would announce nothing at exactly
  // the moment it matters.
  final activity = File(
    'android/app/src/main/kotlin/com/example/communication_platform/'
    'MessageAlertChannel.kt',
  ).readAsStringSync();

  test('the artifact asks for the notification permission and no more', () {
    expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
    // The channel enables vibration, which the system performs on the app's
    // behalf. Declaring it is the unambiguous reading and costs a normal
    // permission with no prompt and no exposure.
    expect(manifest, contains('android.permission.VIBRATE'));
    // An exact alarm and an SMS receiver are still ways to buy timeliness
    // with a permission the user can revoke, or by binding an account to a
    // carrier, and neither may ever appear behind an alert.
    expect(manifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
    expect(manifest, isNot(contains('USE_EXACT_ALARM')));
    expect(manifest, isNot(contains('RECEIVE_SMS')));
    // ADR-051 changed one line of this list deliberately, and it is recorded
    // here rather than deleted. The foreground-service permissions now exist,
    // because the opt-in sustained-delivery capability needs them - and they
    // are exactly three, none of which is granted by an alert or asked for by
    // one. `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE` are
    // normal protection level and grant nothing until a service actually
    // starts; `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only permits *showing*
    // the system's own dialog, whose answer is the user's. ADR-078 added one
    // more the same way: `FOREGROUND_SERVICE_MICROPHONE`, for the call's
    // microphone-type service, which is normal protection level too and is
    // neither granted by an alert nor asked for by one.
    expect(
      RegExp(
        'FOREGROUND_SERVICE[A-Z_]*',
      ).allMatches(manifest).map((match) => match.group(0)),
      {
        'FOREGROUND_SERVICE',
        'FOREGROUND_SERVICE_SPECIAL_USE',
        'FOREGROUND_SERVICE_MICROPHONE',
      },
      reason: 'no other foreground service type may be declared',
    );
    expect(
      manifest,
      contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'),
    );
    // And the alert's own Kotlin still knows nothing about any of it.
    for (final forbidden in const [
      'startForeground',
      'isIgnoringBatteryOptimizations',
      'SustainedDelivery',
    ]) {
      expect(
        activity,
        isNot(contains(forbidden)),
        reason: 'the alert is a projection of committed state, not a service',
      );
    }
    // The one permission ADR-049 adds, and the reason it is acceptable: normal
    // protection level, granted at install with no prompt, and required only
    // by `JobInfo.setPersisted(true)` so a restart does not silently end
    // background delivery.
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(
      _declaredReceivers(manifest),
      isEmpty,
      reason:
          'setPersisted is what survives a reboot; this application declares '
          'no boot receiver of its own',
    );
  });

  test('the alert is withheld from the lock screen by construction', () {
    // Not left to the system's own redaction: the visibility is declared, and
    // the public version is supplied, which is what Android 15 and above shows
    // during screen sharing instead of a contextless redaction.
    expect(activity, contains('VISIBILITY_PRIVATE'));
    expect(activity, contains('setPublicVersion'));
    // The arrival time is not shown; it is not needed to act on the alert and
    // it is one more thing a lock screen would tell someone holding the phone.
    expect(activity, contains('setShowWhen(false)'));
  });

  test('tapping the alert carries no destination and no identifier', () {
    // The launcher intent and nothing else. There is no extra to validate, no
    // deep link to forge, and no route that could bypass the guards the
    // application already has between an entry point and content.
    expect(activity, contains('getLaunchIntentForPackage'));
    expect(activity, contains('PendingIntent.FLAG_IMMUTABLE'));
    expect(
      activity,
      isNot(contains('putExtra(Intent.EXTRA_TEXT')),
      reason: 'nothing about a message may ride the tap intent',
    );
    expect(
      activity,
      isNot(contains('setShortcutId')),
      reason:
          'conversation shortcuts would publish a per-contact identifier into '
          'the launcher, which is the opposite of a sender-neutral alert',
    );
    expect(
      activity,
      isNot(contains('MessagingStyle')),
      reason: 'a messaging-style notification exists to show senders and text',
    );
  });

  test('the native side holds no policy about messages', () {
    // Everything the notification says is decided in Dart and arrives as a
    // reviewed, localized sentence, so the whole decision is covered by host
    // tests and one catalogue is translated.
    for (final forbidden in const [
      'unread',
      'conversation_id',
      'conversationId',
      'senderUserId',
      'messageId',
      'muted',
      'NotificationCompat.MessagingStyle',
    ]) {
      expect(
        activity,
        isNot(contains(forbidden)),
        reason: 'MainActivity must not learn anything about a message',
      );
    }
  });

  test('the channel is the only way in, and its identity is frozen', () {
    expect(
      activity,
      contains(PlatformMessageAlertPresenter.channelName),
      reason: 'the Dart and Kotlin halves must name the same channel',
    );
    // The channel id keys the user's own sound and importance settings.
    // Changing it discards them silently, so it is pinned here.
    expect(activity, contains('CHANNEL_ID = "messages"'));
    expect(
      File(
        'android/app/src/main/kotlin/com/example/communication_platform/'
        'MainActivity.kt',
      ).readAsStringSync(),
      isNot(contains('NotificationCompat.Builder')),
      reason: 'there is one implementation of the alert, not one per engine',
    );
  });

  test('no notification dependency was added to reach the platform', () {
    // ADR-046 step 8 preferred app-owned Kotlin behind a port for this surface,
    // and `androidx.core` - already a declared dependency for FileProvider -
    // supplies every API the alert uses.
    final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
    for (final package in const [
      'flutter_local_notifications',
      'awesome_notifications',
      'firebase',
      'workmanager',
      'flutter_foreground_task',
      'permission_handler',
    ]) {
      expect(pubspec, isNot(contains(package)));
    }
    expect(
      File('android/app/build.gradle.kts').readAsStringSync(),
      contains('androidx.core:core:'),
    );
  });

  test('the alert never reads a transport event', () {
    // The trigger is a committed durable row and nothing else. A dependency on
    // the socket, the gateway or the engine here would be the exact mistake
    // ADR-046 forbids: announcing something the server said rather than
    // something this device authenticated and committed.
    final reconciler = File(
      'lib/features/notifications/application/reconcile_message_alerts.dart',
    ).readAsStringSync();
    for (final forbidden in const [
      'Gateway',
      'WebSocket',
      'RealtimeSync',
      'DurableSyncEngine',
      'SyncRemotePort',
      'Envelope',
    ]) {
      expect(reconciler, isNot(contains(forbidden)));
    }
  });
}

/// Every `<receiver>` element in the manifest that actually declares a
/// component, as opposed to refusing one contributed from outside.
///
/// ADR-054 added the only `<receiver>` element this manifest has ever carried:
/// a `tools:node="remove"` directive that deletes the exported receiver
/// `androidx.profileinstaller` merges in. That is the opposite of declaring an
/// entry point, so the invariant is stated over declarations rather than over
/// the literal text.
Iterable<String> _declaredReceivers(String manifest) =>
    RegExp(r'<receiver[^>]*>', dotAll: true)
        .allMatches(manifest)
        .map((match) => match.group(0)!)
        .where((element) => !element.contains('tools:node="remove"'));
