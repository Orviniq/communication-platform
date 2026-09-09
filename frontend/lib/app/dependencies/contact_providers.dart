import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/contacts/application/client_authentication_service.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/application/peer_resolution_cache.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/dio_contact_repository.dart';
import 'package:communication_platform/features/contacts/infrastructure/drift_contact_repository.dart';
import 'package:communication_platform/features/contacts/infrastructure/fake_profile_ports.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final authenticatedRestClientProvider = Provider<DioRestClient>(
  (ref) => throw StateError('Authenticated REST client is not installed.'),
);

final contactRemoteProvider = Provider<DioContactRepository>(
  (ref) => DioContactRepository(
    ref.watch(authenticatedRestClientProvider),
    ref.watch(serverConfigSnapshotProvider),
  ),
);

final contactLocalProvider = FutureProvider<ContactLocalPort>((ref) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftContactRepository(database);
});

final profileProtectionProvider = Provider<ProfileProtectionPort>((ref) {
  final environment = ref.watch(appEnvironmentProvider);
  return environment == AppEnvironment.development
      ? DevelopmentFakeProfileProtection()
      : const UnsupportedProfileProtection();
});

final profileKeyDistributionProvider = Provider<ProfileKeyDistributionPort>((
  ref,
) {
  final environment = ref.watch(appEnvironmentProvider);
  return environment == AppEnvironment.development
      ? DevelopmentFakeProfileKeyDistribution()
      : const UnsupportedProfileKeyDistribution();
});

/// What the composed profile ports can actually do in the running build.
enum ProfilePublishing {
  /// Real profile encryption and authenticated key delivery.
  available,

  /// The development stand-in. It round-trips locally and is not cryptography.
  developmentStandIn,

  /// No adapter. Publishing fails closed and nothing a user types is sent.
  notBuilt;

  bool get canPublish => this != ProfilePublishing.notBuilt;
}

/// Read from the adapters this build actually composed, never from the
/// environment.
///
/// A second environment comparison beside the one above is how a screen ends up
/// claiming a capability the composition root did not install - which is the
/// defect ADR-044 found in the group boundary and which ADR-045 keeps out of
/// this one. Today every flavor but development resolves the unsupported
/// adapters, so the Private Experimental build cannot publish a profile and
/// says so instead of failing with a generic error.
final profilePublishingProvider = Provider<ProfilePublishing>((ref) {
  final protection = ref.watch(profileProtectionProvider);
  final distribution = ref.watch(profileKeyDistributionProvider);
  if (protection is UnsupportedProfileProtection ||
      distribution is UnsupportedProfileKeyDistribution) {
    return ProfilePublishing.notBuilt;
  }
  return protection.isProductionReady && distribution.isProductionReady
      ? ProfilePublishing.available
      : ProfilePublishing.developmentStandIn;
});

final directoryServiceProvider = FutureProvider<DirectoryService>((ref) async {
  final local = await ref.watch(contactLocalProvider.future);
  return DirectoryService(
    remote: ref.watch(contactRemoteProvider),
    local: local,
  );
});

/// One short-lived, process-local memory of what the server said about a peer.
///
/// It is a `Provider` on the root container, so every resolver in the composed
/// application — the send fan-out, the prekey claim, device-log gossip — asks
/// through the same instance and a delivery cycle stops paying for the same
/// answer two to four times. It holds nothing durable, on purpose: a cache that
/// outlives the process is a cache that can outlive a revocation it never saw.
final peerResolutionCacheProvider = Provider<PeerIdentityRoundTripCache>(
  (ref) => PeerIdentityRoundTripCache(
    remote: ref.watch(contactRemoteProvider),
    clock: ref.watch(timeSourceProvider),
  ),
);

final peerAuthenticationServiceProvider =
    FutureProvider<ClientAuthenticationService>((ref) async {
      final local = await ref.watch(contactLocalProvider.future);
      final cache = ref.watch(peerResolutionCacheProvider);
      return ClientAuthenticationService(
        // The cache decorates the remote port rather than the service, so the
        // service's verification is in front of every answer it is handed and
        // a hit is a shorter path to the same verdict, never a way past one.
        remote: cache,
        local: local,
        crypto: ref.watch(identityCryptoProvider),
        resolutionCache: cache,
      );
    });

final profileServiceProvider = FutureProvider<ProfileService>((ref) async {
  final local = await ref.watch(contactLocalProvider.future);
  final authentication = await ref.watch(
    peerAuthenticationServiceProvider.future,
  );
  return ProfileService(
    remote: ref.watch(contactRemoteProvider),
    local: local,
    authentication: authentication,
    protection: ref.watch(profileProtectionProvider),
    keyDistribution: ref.watch(profileKeyDistributionProvider),
  );
});

final contactListProvider = StreamProvider.autoDispose
    .family<List<ContactProjection>, String>((ref, ownUserId) async* {
      final local = await ref.watch(contactLocalProvider.future);
      yield* local.watchContacts(ownUserId: ownUserId);
    });

final contactProvider = StreamProvider.autoDispose
    .family<ContactProjection?, String>((ref, userId) async* {
      final local = await ref.watch(contactLocalProvider.future);
      yield* local.watchContact(userId);
    });
