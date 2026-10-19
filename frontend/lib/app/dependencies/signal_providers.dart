import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/voice_providers.dart';
import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_opener.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/infrastructure/native_pairwise_outbound_preparation.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/infrastructure/cached_presence_peers.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_voice_signal_crypto.dart';
import 'package:communication_platform/features/voice/infrastructure/published_voice_deployment.dart';
import 'package:communication_platform/features/voice/infrastructure/timer_voice_signal_timer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the chat screens report for typing. One for the process, so that a
/// screen reports whether or not a presence channel is running yet.
final chatActivityProvider = Provider<ChatActivityHub>((ref) {
  final hub = ChatActivityHub();
  ref.onDispose(() => unawaited(hub.dispose()));
  return hub;
});

/// The one reader of inbound `signal` frames for a signed-in device
/// (ADR-098 D1). The delivery session starts it with the socket and stops it
/// with the socket; voice and presence both read from it.
///
/// It opens with the durable path's own store, device lists and native core,
/// so a frame moves exactly the sessions a message would.
final signalRouterProvider =
    FutureProvider.family<SignalRouter, MessagingScope>((ref, scope) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      final config = ref.watch(serverConfigSnapshotProvider);
      final store = DriftPairwiseTransportStore(database, config: config);
      final router = SignalRouter(
        socket: ref.watch(voiceSignalSocketProvider),
        opener: PairwiseVoiceSignalOpen(
          PairwiseVolatileOpener(
            localDeviceId: scope.deviceId,
            store: store,
            volatileStore: store,
            liveDevices: ContactPairwiseLiveDeviceResolverAdapter(
              delegate: authentication,
              currentUserId: scope.userId,
            ),
            crypto: ref.watch(pairwiseSessionCryptoProvider),
            clock: ref.watch(timeSourceProvider),
          ),
        ),
        buckets: PublishedVoiceDeployment(config),
      );
      ref.onDispose(() => unawaited(router.dispose()));
      return router;
    });

/// Typing over `CPPSV001` for a signed-in device (ADR-098). The delivery
/// session starts and stops it with the socket.
final presenceChannelProvider =
    FutureProvider.family<PresenceChannel, MessagingScope>((ref, scope) async {
      final router = await ref.watch(signalRouterProvider(scope).future);
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      final contacts = await ref.watch(contactLocalProvider.future);
      final groups = await ref.watch(groupRepositoryProvider.future);
      final config = ref.watch(serverConfigSnapshotProvider);
      final clock = ref.watch(timeSourceProvider);
      final store = DriftPairwiseTransportStore(database, config: config);
      final verifier = ContactPairwiseLiveDeviceResolverAdapter(
        delegate: authentication,
        currentUserId: scope.userId,
      );
      final peers = CachedPresencePeers(
        delegate: authentication,
        verifier: verifier,
        trust: contacts,
        clock: clock,
      );
      final channel = PresenceChannel(
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
        router: router,
        socket: ref.watch(voiceSignalSocketProvider),
        sealer: PairwisePresenceSeal(
          sealer: PairwiseVolatileSealer(
            store: store,
            volatileStore: store,
            liveDevices: peers,
            crypto: NativePairwiseOutboundPreparation(
              ref.watch(pairwiseSessionCryptoProvider),
            ),
            clock: clock,
          ),
          currentUserId: scope.userId,
          currentDeviceId: scope.deviceId,
        ),
        buckets: PublishedVoiceDeployment(config),
        conversations: DriftPresenceConversations(
          database: database,
          groups: groups,
        ),
        peers: peers,
        ledger: MemoryPresenceLedger(),
        typingSink: VolatileStateTypingSink(
          ref.watch(volatileConversationStateProvider),
        ),
        visibility: _RegistryVisibility(ref.watch(visibleConversationProvider)),
        activity: ref.watch(chatActivityProvider).events,
        clock: clock,
        timers: const TimerPresenceTimers(),
        pacerTimer: const TimerVoiceSignalTimer(),
      );
      ref.onDispose(() => unawaited(channel.stop()));
      return channel;
    });

/// The registry of what is on screen, as presence reads it.
final class _RegistryVisibility implements PresenceVisibilityPort {
  const _RegistryVisibility(this.registry);

  final VisibleConversationRegistry registry;

  @override
  String? get visibleConversationId => registry.conversationId;

  @override
  bool get isForeground => registry.isForeground;

  @override
  Stream<void> get changes => registry.changes;
}
