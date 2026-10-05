import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// `voice_configured` and `signal_buckets` from the limits in force.
///
/// The snapshot answers before the deployment has, with the stored answer or
/// the fallback, and the fallback is `false`. So until `GET /api/v1/config` has
/// said this deployment serves voice, no call is offered and no credential is
/// asked for.
///
/// Both are read when asked, never kept: a socket and a call outlive the
/// configuration read that corrects them.
final class PublishedVoiceDeployment
    implements VoiceDeploymentPort, VoiceSignalBucketsPort {
  const PublishedVoiceDeployment(this.snapshot);

  final ServerConfigSnapshot snapshot;

  @override
  bool get voiceConfigured => snapshot.current.voiceConfigured;

  @override
  Set<int> get signalBuckets => snapshot.current.signalBuckets;
}
