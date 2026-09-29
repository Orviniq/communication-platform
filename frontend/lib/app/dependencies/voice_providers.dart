import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_opener.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/infrastructure/native_pairwise_outbound_preparation.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/application/voice_signal_transport.dart';
import 'package:communication_platform/features/voice/infrastructure/dio_relay_credential_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/gateway_voice_signal_socket.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_voice_signal_crypto.dart';
import 'package:communication_platform/features/voice/infrastructure/published_voice_deployment.dart';
import 'package:communication_platform/features/voice/infrastructure/timer_voice_signal_timer.dart';
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

/// The socket signalling travels on: the running delivery session's gateway,
/// which the session attaches when it starts and detaches when it stops.
final voiceSignalSocketProvider = Provider<GatewayVoiceSignalSocket>((ref) {
  final socket = GatewayVoiceSignalSocket();
  ref.onDispose(() => unawaited(socket.dispose()));
  return socket;
});

/// The call's signalling channel for one signed-in device.
///
/// It seals and opens with the durable path's own store, device lists and
/// native core, so a frame moves exactly the sessions a message would; it adds
/// only that nothing about a frame is queued or kept.
final voiceSignallingProvider =
    FutureProvider.family<VoiceSignallingPort, MessagingScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      final config = ref.watch(serverConfigSnapshotProvider);
      final store = DriftPairwiseTransportStore(database, config: config);
      final liveDevices = ContactPairwiseLiveDeviceResolverAdapter(
        delegate: authentication,
        currentUserId: scope.userId,
      );
      final crypto = ref.watch(pairwiseSessionCryptoProvider);
      final clock = ref.watch(timeSourceProvider);
      final transport = VoiceSignalTransport(
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
        socket: ref.watch(voiceSignalSocketProvider),
        sealer: PairwiseVoiceSignalSeal(
          sealer: PairwiseVolatileSealer(
            store: store,
            volatileStore: store,
            liveDevices: liveDevices,
            crypto: NativePairwiseOutboundPreparation(crypto),
            clock: clock,
          ),
          currentUserId: scope.userId,
          currentDeviceId: scope.deviceId,
        ),
        opener: PairwiseVoiceSignalOpen(
          PairwiseVolatileOpener(
            localDeviceId: scope.deviceId,
            store: store,
            volatileStore: store,
            liveDevices: liveDevices,
            crypto: crypto,
            clock: clock,
          ),
        ),
        buckets: PublishedVoiceDeployment(config),
        clock: clock,
        timer: const TimerVoiceSignalTimer(),
      )..start();
      ref.onDispose(() => unawaited(transport.dispose()));
      return transport;
    });
