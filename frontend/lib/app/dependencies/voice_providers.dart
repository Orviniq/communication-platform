import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/infrastructure/dio_relay_credential_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/published_voice_deployment.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final relayCredentialPortProvider = Provider<RelayCredentialPort>(
  (ref) => DioRelayCredentialRepository(
    ref.watch(authenticatedRestClientProvider),
    clock: ref.watch(timeSourceProvider),
  ),
);

/// The relay credential of the call in progress.
///
/// One for the process, because a call is one for the process, and the
/// credential it holds lives in memory and nowhere else: a rebuilt provider
/// starts empty, and the next join mints another. Nothing is fetched until a
/// call asks.
final relayCredentialServiceProvider = Provider<RelayCredentialService>(
  (ref) => RelayCredentialService(
    remote: ref.watch(relayCredentialPortProvider),
    deployment: PublishedVoiceDeployment(
      ref.watch(serverConfigSnapshotProvider),
    ),
    clock: ref.watch(timeSourceProvider),
  ),
);
