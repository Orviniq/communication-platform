/// What one request for the microphone came to.
///
/// A call asks at the join and at no other time (`backend/CLIENT_CONTRACT.md`
/// §N rule 11), so this is the answer to the one question a join puts.
enum MicrophonePermission {
  /// `RECORD_AUDIO` is granted, for good or only this time. A grant already
  /// held shows no dialog at all.
  granted,

  /// Refused, and Android will ask again at the next join: the user refused
  /// once, or the request was interrupted before anyone answered.
  denied,

  /// Refused, and Android shows no dialog for it any more: the user refused
  /// twice, or a device policy decides. Only the system settings can allow it
  /// now.
  ///
  /// A first dialog dismissed without an answer reads the same: Android
  /// reports both with no rationale, and documents no way to tell them apart.
  /// The settings allow the microphone in that case too, and the next join
  /// shows the dialog again.
  deniedPermanently,
}

/// Why the call service did not start.
enum VoiceCallServiceRefusal {
  /// `RECORD_AUDIO` is not granted: the join has not asked, or the user took
  /// it back. The platform creates no `microphone` service without it.
  microphoneNotGranted,

  /// The application has no visible activity. The platform starts a
  /// `microphone` service only while the application is in the foreground.
  notInForeground,

  /// The platform refused for a reason it did not name, or the service did
  /// not come up in time.
  platformRefused,

  /// No platform implementation is composed: a host test, or a target that is
  /// not Android.
  unavailable,
}

/// What asking for the call service came to.
sealed class VoiceCallServiceStart {
  const VoiceCallServiceStart();
}

/// The service runs, and the call keeps the microphone for as long as it
/// does.
final class VoiceCallServiceRunning extends VoiceCallServiceStart {
  const VoiceCallServiceRunning({required this.notificationVisible});

  /// Whether its entry shows in the notification shade, read as it started.
  ///
  /// With notifications off the service runs all the same, and Android shows
  /// its notice in the Task Manager instead, so the call is unaffected and the
  /// screen is the only place that can say a call is running.
  final bool notificationVisible;

  @override
  String toString() =>
      'VoiceCallServiceRunning(notificationVisible: $notificationVisible)';
}

/// The service does not run.
final class VoiceCallServiceRefused extends VoiceCallServiceStart {
  const VoiceCallServiceRefused(this.reason);

  final VoiceCallServiceRefusal reason;

  @override
  String toString() => 'VoiceCallServiceRefused(${reason.name})';
}
