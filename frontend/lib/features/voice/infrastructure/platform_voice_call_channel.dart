// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The method channel a call's microphone crosses: `VoiceCall.kt`, attached to
/// the activity's engine and to no other.
///
/// What crosses it is the permission request and its one-word answer, a
/// start carrying the entry's three reviewed strings, and a stop. Nothing
/// about the room, the participants or the audio does.
abstract final class VoiceCallChannel {
  static const name = 'communication_platform/voice_call';
}

/// The reviewed, localized text of the entry the call service shows.
///
/// It says that a call is in progress and nothing more: it names nobody in
/// the call and no room, because the shade, a locked screen and a screen being
/// shared all show it.
final class VoiceCallServiceStrings {
  const VoiceCallServiceStrings({
    required this.title,
    required this.channelName,
    required this.channelDescription,
  });

  final String title;
  final String channelName;
  final String channelDescription;
}

/// `RECORD_AUDIO`, asked through the activity.
///
/// The answer is Android's, read after the dialog closes: granted, refused,
/// or refused with no rationale, which Android shows when it will ask no more.
/// Anything else - no implementation, a platform failure, an answer this code
/// does not understand - is a refusal, never a grant.
final class PlatformMicrophonePermission implements MicrophonePermissionPort {
  const PlatformMicrophonePermission({
    MethodChannel channel = const MethodChannel(VoiceCallChannel.name),
  }) : _channel = channel;

  /// How long the system dialog may stay unanswered before this stops waiting
  /// for it.
  ///
  /// The platform answers when the dialog is answered or dismissed, so this
  /// is not the normal path. A reply that never came would leave a join
  /// waiting forever.
  static const promptDeadline = Duration(minutes: 5);

  final MethodChannel _channel;

  @override
  Future<MicrophonePermission> request() async {
    final answer = await _invoke(
      _channel,
      'requestMicrophone',
    ).timeout(promptDeadline, onTimeout: () => null);
    return switch (answer) {
      'granted' => MicrophonePermission.granted,
      'deniedPermanently' => MicrophonePermission.deniedPermanently,
      _ => MicrophonePermission.denied,
    };
  }

  @override
  Future<bool> isGranted() async =>
      await _invoke(_channel, 'microphoneGranted') == true;

  /// A page that cannot be opened leaves the user where they were: there is
  /// nothing to report, because nothing is read back from the settings.
  @override
  Future<void> openSettings() async {
    await _invoke(_channel, 'openMicrophoneSettings');
  }
}

/// The call's microphone-type foreground service.
///
/// **It starts only after a granted permission.** [start] asks the platform
/// whether the microphone is granted - a check, which shows nothing - and
/// starts nothing when it is not. The platform's own refusal would come
/// later, from inside a service already asked for, and a call must not count
/// on it.
///
/// The native side then refuses by name what the platform would refuse: no
/// permission, or no visible activity. Whatever the platform refuses anyway
/// comes back as a refusal, never as a start, and a start is answered only
/// once the service is in the foreground.
///
/// Starts and stops reach the platform one at a time and in order, so a stop
/// on the way to a quick second join has landed before that join's start
/// arrives.
final class PlatformVoiceCallService implements VoiceCallServicePort {
  PlatformVoiceCallService({
    required MicrophonePermissionPort microphone,
    required Future<VoiceCallServiceStrings> Function() strings,
    MethodChannel channel = const MethodChannel(VoiceCallChannel.name),
    this.transitionDeadline = defaultTransitionDeadline,
  }) : _microphone = microphone,
       _strings = strings,
       _channel = channel;

  /// How long a start or a stop may take before this stops waiting. Longer
  /// than the native side's own ten-second bound, so its answer is the normal
  /// end of a slow one, and a reply that never comes cannot hold up the stop
  /// queued behind it.
  static const defaultTransitionDeadline = Duration(seconds: 15);

  final Duration transitionDeadline;

  final MicrophonePermissionPort _microphone;

  /// Resolved per start rather than captured once, so a change of language
  /// reaches the entry of the next call.
  final Future<VoiceCallServiceStrings> Function() _strings;
  final MethodChannel _channel;
  Future<void> _turn = Future<void>.value();

  @override
  Future<VoiceCallServiceStart> start() => _serially(() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const VoiceCallServiceRefused(VoiceCallServiceRefusal.unavailable);
    }
    if (!await _microphone.isGranted()) {
      return const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.microphoneNotGranted,
      );
    }
    final strings = await _strings();
    final Object? reply;
    try {
      reply = await _channel
          .invokeMethod<Object?>('start', <String, Object?>{
            'title': strings.title,
            'channelName': strings.channelName,
            'channelDescription': strings.channelDescription,
          })
          .timeout(transitionDeadline);
    } on MissingPluginException {
      return const VoiceCallServiceRefused(VoiceCallServiceRefusal.unavailable);
    } on PlatformException {
      return const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.platformRefused,
      );
    } on TimeoutException {
      // The service may still come up. Asked to stop, it goes the moment it
      // does, rather than run for a call that was told it did not start.
      await _stop();
      return const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.platformRefused,
      );
    }
    final outcome = _decode(reply);
    if (outcome is VoiceCallServiceRefused &&
        reply is Map &&
        reply['outcome'] == 'started') {
      // A start this code could not read is no start, and must not stay one
      // on the platform either.
      await _stop();
    }
    return outcome;
  });

  @override
  Future<void> stop() => _serially(_stop);

  Future<void> _stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop').timeout(transitionDeadline);
    } on MissingPluginException {
      // Nothing to stop where there is no implementation.
    } on PlatformException {
      // A service that cannot be stopped from here stops with the engine.
    } on TimeoutException {
      // The platform is still stopping it, and nothing here can do more.
    }
  }

  /// Strictly: an answer this code does not understand is a refusal, never a
  /// running service.
  static VoiceCallServiceStart _decode(Object? reply) {
    if (reply is! Map) {
      return const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.platformRefused,
      );
    }
    return switch (reply['outcome']) {
      'started' => switch (reply['notificationVisible']) {
        final bool visible => VoiceCallServiceRunning(
          notificationVisible: visible,
        ),
        _ => const VoiceCallServiceRefused(
          VoiceCallServiceRefusal.platformRefused,
        ),
      },
      'microphoneNotGranted' => const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.microphoneNotGranted,
      ),
      'notInForeground' => const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.notInForeground,
      ),
      _ => const VoiceCallServiceRefused(
        VoiceCallServiceRefusal.platformRefused,
      ),
    };
  }

  Future<T> _serially<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// The reply, untyped, so that the caller decides what it understands: a reply
/// of the wrong type is no answer rather than a cast that throws.
Future<Object?> _invoke(MethodChannel channel, String method) async {
  // The check is on the target platform rather than on `dart:io`, so that a
  // test can drive the Android path without an Android device.
  if (defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  try {
    return await channel.invokeMethod<Object?>(method);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
