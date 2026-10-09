import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/application/group_inbound_coordinator.dart';
import 'package:communication_platform/features/groups/application/group_outbound_dispatcher.dart';
import 'package:communication_platform/features/groups/application/group_state_recovery_service.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/groups/infrastructure/group_pairwise_adapters.dart';
import 'package:communication_platform/features/groups/infrastructure/native_group_control_crypto.dart';
import 'package:communication_platform/features/groups/infrastructure/pairwise_group_live_device_adapter.dart';
import 'package:communication_platform/features/groups/infrastructure/pairwise_group_outbound_envelope_adapter.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_session_repair_service.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final groupRepositoryProvider = FutureProvider<GroupRepositoryPort>((
  ref,
) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftGroupRepository(database);
});

typedef GroupScope = ({String userId, String deviceId});

/// Signs and opens group control events with this device's signing key,
/// which stays inside the native device state.
final groupControlCryptoProvider =
    FutureProvider.family<GroupControlCryptoPort, GroupScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      return NativeGroupControlCrypto(
        crypto: ref.watch(pairwiseCryptoProvider),
        store: DriftPairwiseTransportStore(
          database,
          config: ref.watch(serverConfigSnapshotProvider),
        ),
        localDeviceId: scope.deviceId,
        clock: ref.watch(timeSourceProvider),
      );
    });

/// The devices a group control event may come from, each with the signing
/// key the contacts feature authenticated through the device log.
final groupLiveDeviceResolverProvider =
    FutureProvider.family<GroupLiveDeviceResolverPort, GroupScope>((
      ref,
      scope,
    ) async {
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      return PairwiseGroupLiveDeviceAdapter(
        ContactPairwiseLiveDeviceResolverAdapter(
          delegate: authentication,
          currentUserId: scope.userId,
        ),
      );
    });

final groupOutboundDispatcherProvider =
    FutureProvider.family<GroupOutboundDispatcher, GroupScope>((
      ref,
      scope,
    ) async {
      final repository = await ref.watch(groupRepositoryProvider.future);
      final fanout = await ref.watch(
        pairwiseFanoutCoordinatorProvider((
          userId: scope.userId,
          deviceId: scope.deviceId,
        )).future,
      );
      return GroupOutboundDispatcher(
        repository: repository,
        envelopes: PairwiseGroupOutboundEnvelopeAdapter(fanout),
      );
    });

final groupInboundCoordinatorProvider =
    FutureProvider.family<GroupInboundCoordinator, GroupScope>((
      ref,
      scope,
    ) async {
      return GroupInboundCoordinator(
        repository: await ref.watch(groupRepositoryProvider.future),
        crypto: await ref.watch(groupControlCryptoProvider(scope).future),
        liveDevices: await ref.watch(
          groupLiveDeviceResolverProvider(scope).future,
        ),
        clock: ref.watch(timeSourceProvider),
        localUserId: scope.userId,
      );
    });

final groupStateRecoveryServiceProvider =
    FutureProvider.family<GroupStateRecoveryService, GroupScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      return GroupStateRecoveryService(
        repository: await ref.watch(groupRepositoryProvider.future),
        repair: PairwiseGroupSessionRepairAdapter(
          PairwiseSessionRepairService(
            store: DriftPairwiseTransportStore(
              database,
              config: ref.watch(serverConfigSnapshotProvider),
            ),
            liveDevices: ContactPairwiseLiveDeviceResolverAdapter(
              delegate: authentication,
              currentUserId: scope.userId,
            ),
            crypto: ref.watch(pairwiseSessionCryptoProvider),
            clock: ref.watch(timeSourceProvider),
          ),
        ),
        clock: ref.watch(timeSourceProvider),
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
      );
    });

/// The group use cases for the signed-in account on this device.
///
/// Signing a control event and sending a message both act as one device, so
/// the account and device are resolved here rather than by each screen.
final groupUseCasesProvider = FutureProvider<GroupUseCases>((ref) async {
  final userId = ref.watch(
    authenticationControllerProvider.select((state) => state.userId),
  );
  if (userId == null) {
    throw StateError('group use cases need a signed-in account');
  }
  final deviceId = await ref.watch(currentMessagingDeviceIdProvider.future);
  final scope = (userId: userId, deviceId: deviceId);
  final repository = await ref.watch(groupRepositoryProvider.future);
  final crypto = await ref.watch(groupControlCryptoProvider(scope).future);
  final clock = ref.watch(timeSourceProvider);
  final identity = NativeGroupIdentity(ref.watch(applicationProtocolProvider));
  final sender = ConversationGroupMessageSender(
    await ref.watch(sendConversationEventsProvider(scope).future),
  );
  return GroupUseCases(
    create: CreateGroup(
      repository: repository,
      crypto: crypto,
      identity: identity,
      clock: clock,
    ),
    mutate: MutateGroup(
      repository: repository,
      crypto: crypto,
      identity: identity,
      clock: clock,
    ),
    sendMessage: SendGroupMessage(repository: repository, sender: sender),
    retryMessage: RetryGroupMessage(repository: repository, sender: sender),
  );
});

final groupProvider = StreamProvider.autoDispose.family<GroupState?, String>((
  ref,
  groupId,
) async* {
  final repository = await ref.watch(groupRepositoryProvider.future);
  yield* repository.watchGroup(groupId);
});

final groupMessagesProvider = StreamProvider.autoDispose
    .family<List<GroupMessage>, String>((ref, groupId) async* {
      final repository = await ref.watch(groupRepositoryProvider.future);
      yield* repository.watchMessages(groupId);
    });
