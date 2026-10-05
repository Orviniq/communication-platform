import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_session_repair_service.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/room_inbound_coordinator.dart';
import 'package:communication_platform/features/voice/application/room_outbound_dispatcher.dart';
import 'package:communication_platform/features/voice/application/room_session_starter.dart';
import 'package:communication_platform/features/voice/application/room_state_recovery_service.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/native_room_control_crypto.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_room_adapters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final roomRepositoryProvider = FutureProvider<RoomRepositoryPort>((ref) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftRoomRepository(database);
});

/// The room state the call and the screens read, and nothing that writes it.
final roomStateReadPortProvider = FutureProvider<RoomStateReadPort>(
  (ref) => ref.watch(roomRepositoryProvider.future),
);

/// Every room this device holds, projected from the database. A room waiting
/// on its state reads as [RoomLifecycle.stateRecoveryRequired].
final voiceRoomsProvider = StreamProvider.autoDispose<List<RoomState>>((
  ref,
) async* {
  final rooms = await ref.watch(roomStateReadPortProvider.future);
  yield* rooms.watchRooms();
});

final voiceRoomProvider = StreamProvider.autoDispose.family<RoomState?, String>(
  (ref, roomId) async* {
    final rooms = await ref.watch(roomStateReadPortProvider.future);
    yield* rooms.watchRoom(roomId);
  },
);

/// Signs and opens room control events with this device's signing key, which
/// stays inside the native device state.
final roomControlCryptoProvider =
    FutureProvider.family<RoomControlCryptoPort, MessagingScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      return NativeRoomControlCrypto(
        crypto: ref.watch(pairwiseCryptoProvider),
        store: DriftPairwiseTransportStore(
          database,
          config: ref.watch(serverConfigSnapshotProvider),
        ),
        localDeviceId: scope.deviceId,
        clock: ref.watch(timeSourceProvider),
      );
    });

/// The devices a room control event may come from, each with the signing key
/// the contacts feature authenticated through the device log.
final roomLiveDeviceResolverProvider =
    FutureProvider.family<RoomLiveDeviceResolverPort, MessagingScope>((
      ref,
      scope,
    ) async {
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      return PairwiseRoomLiveDeviceAdapter(
        ContactPairwiseLiveDeviceResolverAdapter(
          delegate: authentication,
          currentUserId: scope.userId,
        ),
      );
    });

final roomOutboundDispatcherProvider =
    FutureProvider.family<RoomOutboundDispatcher, MessagingScope>((
      ref,
      scope,
    ) async {
      return RoomOutboundDispatcher(
        repository: await ref.watch(roomRepositoryProvider.future),
        envelopes: PairwiseRoomOutboundEnvelopeAdapter(
          await ref.watch(pairwiseFanoutCoordinatorProvider(scope).future),
        ),
      );
    });

final roomInboundCoordinatorProvider =
    FutureProvider.family<RoomInboundCoordinator, MessagingScope>((
      ref,
      scope,
    ) async {
      return RoomInboundCoordinator(
        repository: await ref.watch(roomRepositoryProvider.future),
        crypto: await ref.watch(roomControlCryptoProvider(scope).future),
        liveDevices: await ref.watch(
          roomLiveDeviceResolverProvider(scope).future,
        ),
        clock: ref.watch(timeSourceProvider),
        localUserId: scope.userId,
      );
    });

final roomStateRecoveryServiceProvider =
    FutureProvider.family<RoomStateRecoveryService, MessagingScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final authentication = await ref.watch(
        peerAuthenticationServiceProvider.future,
      );
      return RoomStateRecoveryService(
        repository: await ref.watch(roomRepositoryProvider.future),
        repair: PairwiseRoomSessionRepairAdapter(
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

/// Starts the pairwise sessions a room's call will need, on the durable path
/// (ADR-077, decided B). The call runs [RoomSessionStarter.startSessionsForCall]
/// and then [roomOutboundDispatcherProvider]'s dispatch before its `join`.
final roomSessionStarterProvider =
    FutureProvider.family<RoomSessionStarter, MessagingScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      return RoomSessionStarter(
        repository: await ref.watch(roomRepositoryProvider.future),
        liveDevices: await ref.watch(
          roomLiveDeviceResolverProvider(scope).future,
        ),
        sessions: StoredRoomPairwiseSessions(
          DriftPairwiseTransportStore(
            database,
            config: ref.watch(serverConfigSnapshotProvider),
          ),
        ),
        clock: ref.watch(timeSourceProvider),
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
      );
    });

/// The room use cases for the signed-in account on this device.
final roomUseCasesProvider = FutureProvider<RoomUseCases>((ref) async {
  final userId = ref.watch(
    authenticationControllerProvider.select((state) => state.userId),
  );
  if (userId == null) {
    throw StateError('room use cases need a signed-in account');
  }
  final deviceId = await ref.watch(currentMessagingDeviceIdProvider.future);
  final scope = (userId: userId, deviceId: deviceId);
  final repository = await ref.watch(roomRepositoryProvider.future);
  final crypto = await ref.watch(roomControlCryptoProvider(scope).future);
  final clock = ref.watch(timeSourceProvider);
  final identity = NativeRoomIdentity(ref.watch(applicationProtocolProvider));
  return RoomUseCases(
    create: CreateRoom(
      repository: repository,
      crypto: crypto,
      identity: identity,
      clock: clock,
    ),
    mutate: MutateRoom(
      repository: repository,
      crypto: crypto,
      identity: identity,
      clock: clock,
    ),
  );
});
