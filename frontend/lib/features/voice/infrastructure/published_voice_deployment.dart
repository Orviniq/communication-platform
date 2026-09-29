import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';

/// `voice_configured` from the limits in force.
///
/// The snapshot answers before the deployment has, with the stored answer or
/// the fallback, and the fallback is `false`. So until `GET /api/v1/config` has
/// said this deployment serves voice, no call is offered and no credential is
/// asked for.
final class PublishedVoiceDeployment implements VoiceDeploymentPort {
  const PublishedVoiceDeployment(this.snapshot);

  final ServerConfigSnapshot snapshot;

  @override
  bool get voiceConfigured => snapshot.current.voiceConfigured;
}
