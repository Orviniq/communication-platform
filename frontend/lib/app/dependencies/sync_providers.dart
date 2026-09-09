import 'package:communication_platform/app/config/group_production_gate.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/linked_device_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/devices/application/owed_device_log_gossip.dart';
import 'package:communication_platform/features/devices/infrastructure/device_log_gossip_coordinator.dart';
import 'package:communication_platform/features/groups/application/group_key_package_maintenance_service.dart';
import 'package:communication_platform/features/groups/application/group_mls_inbound_coordinator.dart';
import 'package:communication_platform/features/groups/application/group_outbound_dispatcher.dart';
import 'package:communication_platform/features/groups/application/group_pending_eviction_service.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_conversation_resolver.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_send_preparation_adapter.dart';
import 'package:communication_platform/features/messaging/infrastructure/pending_receipt_post_inbox_work.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/dio_sync_remote_port.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/history_transfer_coordinator.dart';
import 'package:communication_platform/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart';
import 'package:communication_platform/features/synchronization/infrastructure/stale_device_refresh_adapter.dart';
import 'package:communication_platform/features/synchronization/infrastructure/sync_platform_adapters.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/pairwise_session_crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final durableSyncStoreProvider = FutureProvider<DurableSyncStore>((ref) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftSyncStore(
    database,
    config: ref.watch(serverConfigSnapshotProvider),
  );
});

/// Presentation observes this immutable Drift projection only. Socket and REST
/// callbacks are not exposed to widgets.
final syncProjectionProvider = StreamProvider<SyncProjection>((ref) async* {
  final store = await ref.watch(durableSyncStoreProvider.future);
  yield* store.watchProjection();
});

typedef PairwiseSyncScope = ({String userId, String deviceId});

/// Whether the owner driving the engine has been asked to give delivery up.
///
/// The application root never is: it is the owner everything else gives way to.
/// The Android deferred catch-up overrides this with the handshake the platform
/// speaks to, so that a user opening the application displaces a catch-up
/// between units of work instead of racing it (ADR-050).
final deliveryStandDownProvider = Provider<DeliveryStandDownSignal>(
  (ref) => const NeverStandsDown(),
);

/// Fully composed Android v1 durable sync engine. Envelope bytes reach the
/// native pairwise inspector before the Drift commit; unknown protocols fail
/// closed in the inspector.
final durableSyncEngineProvider =
    FutureProvider.family<DurableSyncEngine, PairwiseSyncScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      final store = DriftSyncStore(
        database,
        config: ref.watch(serverConfigSnapshotProvider),
      );
      final groupKeyPackageMaintenance =
          GroupProductionGate.privateExperimentalPermit(
                ref.watch(appEnvironmentProvider),
                ref.watch(runtimeAbiProvider),
              ) !=
              null
          ? await ref.watch(
              groupKeyPackageMaintenanceServiceProvider((
                userId: scope.userId,
                deviceId: scope.deviceId,
              )).future,
            )
          : null;
      final sender = await ref.watch(
        sendConversationEventsProvider((
          userId: scope.userId,
          deviceId: scope.deviceId,
        )).future,
      );
      final historyTransfer = HistoryTransferCoordinator(
        database: database,
        applicationProtocol: ref.watch(applicationProtocolProvider),
        controlCrypto: ref.watch(deviceControlCryptoProvider),
        fanout: await ref.watch(
          pairwiseFanoutCoordinatorProvider((
            userId: scope.userId,
            deviceId: scope.deviceId,
          )).future,
        ),
        local: await ref.watch(linkedDeviceLocalProvider.future),
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
      );
      final inspector = PairwiseOpaqueEnvelopeInspector(
        localDeviceId: scope.deviceId,
        store: DriftPairwiseTransportStore(
          database,
          config: ref.watch(serverConfigSnapshotProvider),
        ),
        liveDevices: ContactPairwiseLiveDeviceResolverAdapter(
          delegate: authentication,
          currentUserId: scope.userId,
        ),
        crypto: NativePairwiseSessionCrypto(ref.watch(pairwiseCryptoProvider)),
        applicationProtocol: ref.watch(applicationProtocolProvider),
        deviceControlCrypto: ref.watch(deviceControlCryptoProvider),
        conversationResolver: DriftApplicationConversationResolver(
          database: database,
          protocol: ref.watch(applicationProtocolProvider),
        ),
        currentUserId: scope.userId,
        clock: ref.watch(timeSourceProvider),
        groupInbound: GroupMlsInboundCoordinator(
          repository: DriftGroupRepository(database),
          crypto: await ref.watch(fullyComposedGroupMlsCryptoProvider.future),
          localUserId: scope.userId,
          localDeviceId: scope.deviceId,
        ),
      );
      final gossip = await ref.watch(
        deviceLogGossipCoordinatorProvider((
          userId: scope.userId,
          deviceId: scope.deviceId,
        )).future,
      );
      // What the cycle owes its peers, kept apart from what it owes this
      // device's own messages. A preparation records a debt here and returns;
      // the debt is paid below, after the outbox pass that carried the message.
      final owedGossip = OwedDeviceLogGossip(
        advertise: gossip.queueForUser,
        clock: ref.watch(timeSourceProvider),
      );
      return DurableSyncEngine(
        store: store,
        remote: DioSyncRemotePort(
          ref.watch(authenticatedRestClientProvider),
          ref.watch(serverConfigSnapshotProvider),
        ),
        inspector: inspector,
        staleDeviceRefresh: ContactStaleDeviceRefreshAdapter(authentication),
        clock: ref.watch(timeSourceProvider),
        jitter: FullJitterSource(),
        standDown: ref.watch(deliveryStandDownProvider),
        sendPreparation: PairwiseSendPreparationAdapter(
          await ref.watch(
            pairwiseFanoutCoordinatorProvider((
              userId: scope.userId,
              deviceId: scope.deviceId,
            )).future,
          ),
          onPreparedForPeer: owedGossip.owe,
        ),
        postInboxCommitWork: _CompositePostInboxWork([
          if (groupKeyPackageMaintenance != null)
            _GroupKeyPackagePostInboxWork(
              groupKeyPackageMaintenance,
              currentUserId: scope.userId,
              currentDeviceId: scope.deviceId,
            ),
          _GroupPendingEvictionPostInboxWork(
            GroupPendingEvictionService(
              repository: DriftGroupRepository(database),
              mutate: (await ref.watch(
                groupUseCasesProvider.future,
              )).mutate.call,
              currentUserId: scope.userId,
              currentDeviceId: scope.deviceId,
            ),
          ),
          _GroupOutboundPostInboxWork(
            await ref.watch(
              groupOutboundDispatcherProvider((
                userId: scope.userId,
                deviceId: scope.deviceId,
              )).future,
            ),
            currentUserId: scope.userId,
            currentDeviceId: scope.deviceId,
          ),
          PendingReceiptPostInboxWork(
            FlushPendingDeliveredReceipts(
              repository: await ref.watch(
                conversationRepositoryProvider.future,
              ),
              sender: sender,
              currentUserId: scope.userId,
            ),
          ),
          HistoryTransferPostInboxWork(historyTransfer),
          // Last, so that nothing this device owes somebody else can stand in
          // front of work it owes itself.
          DeviceLogGossipPostInboxWork(owedGossip),
        ]),
      );
    });

final class _GroupKeyPackagePostInboxWork implements PostInboxCommitWorkPort {
  const _GroupKeyPackagePostInboxWork(
    this.maintenance, {
    required this.currentUserId,
    required this.currentDeviceId,
  });

  final GroupKeyPackageMaintenanceService maintenance;
  final String currentUserId;
  final String currentDeviceId;

  @override
  Future<void> run() async {
    await maintenance.maintain(
      userId: currentUserId,
      deviceId: currentDeviceId,
    );
  }
}

final class _GroupPendingEvictionPostInboxWork
    implements PostInboxCommitWorkPort {
  const _GroupPendingEvictionPostInboxWork(this.eviction);

  final GroupPendingEvictionService eviction;

  @override
  Future<void> run() async {
    // Runs before outbound dispatch so a freshly prepared eviction Commit is
    // fanned out in the same drain that observed the leave.
    await eviction.evictDepartedMembers();
  }
}

final class _GroupOutboundPostInboxWork implements PostInboxCommitWorkPort {
  const _GroupOutboundPostInboxWork(
    this.dispatcher, {
    required this.currentUserId,
    required this.currentDeviceId,
  });

  final GroupOutboundDispatcher dispatcher;
  final String currentUserId;
  final String currentDeviceId;

  @override
  Future<void> run() async {
    // Work remains durable when authentication, crypto, or storage is
    // temporarily unavailable; the next sync run retries exact MLS bytes.
    await dispatcher.dispatchPending(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
    );
  }
}

final class _CompositePostInboxWork implements PostInboxCommitWorkPort {
  const _CompositePostInboxWork(this.work);

  final List<PostInboxCommitWorkPort> work;

  @override
  Future<void> run() async {
    for (final item in work) {
      await item.run();
    }
  }
}
