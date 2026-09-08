import 'package:communication_platform/app/dependencies/networking_foundation.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/infrastructure/coordinated_authentication_session.dart';
import 'package:communication_platform/features/authentication/infrastructure/dio_account_authentication_repository.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/devices/application/device_enrollment_coordinator.dart';
import 'package:communication_platform/features/devices/infrastructure/dio_device_enrollment_repository.dart';
import 'package:communication_platform/features/devices/infrastructure/drift_enrollment_journal_store.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';

/// The application's authenticated composition root.
///
/// It owns exactly one [NetworkingFoundation], so the REST client, the token
/// coordinator, the provisioned trust and the socket origin are one set of
/// objects rather than one set per feature that happens to need them. Anything
/// that needs an authenticated transport — including the delivery path's
/// WebSocket — takes it from [networking] instead of building its own.
final class AuthenticationAssembly {
  AuthenticationAssembly._({
    required this.useCases,
    required this.lifecycle,
    required this.enrollment,
    required this.networking,
  });

  factory AuthenticationAssembly.create({
    required Uri serverOrigin,
    required SecureLocalStorageRuntime localStorage,
    required TimeSource timeSource,
    required EnrollmentCryptoPort enrollmentCrypto,
    TransportSecurity transportSecurity =
        const TransportSecurity.platformDefault(),
    NetworkDiagnostics diagnostics = const NoopNetworkDiagnostics(),
  }) {
    final lifecycle = AuthenticationLifecycleBus();
    final tokenStore = SecureSessionTokenAdapter(localStorage);
    final networking = NetworkingFoundation.create(
      serverOrigin: serverOrigin,
      tokenStore: tokenStore,
      terminationHandler: LocalAuthenticationTerminationHandler(
        runtime: localStorage,
        lifecycle: lifecycle,
      ),
      timeSource: timeSource,
      transportSecurity: transportSecurity,
      diagnostics: diagnostics,
    );
    final restClient = networking.restClient;
    final session = CoordinatedAuthenticationSession(
      tokens: tokenStore,
      coordinator: networking.tokenCoordinator,
      runtime: localStorage,
    );
    final enrollmentStore = DriftEnrollmentJournalStore(
      runtime: localStorage,
      tokens: tokenStore,
    );
    final repository = DioAccountAuthenticationRepository(restClient);
    final enrollment = DeviceEnrollmentCoordinator(
      repository: DioDeviceEnrollmentRepository(restClient),
      store: enrollmentStore,
      crypto: enrollmentCrypto,
      clock: timeSource,
    );
    return AuthenticationAssembly._(
      lifecycle: lifecycle,
      enrollment: enrollment,
      networking: networking,
      useCases: AuthenticationUseCases(
        register: RegisterAccount(
          repository,
          enrollmentMarker: enrollmentStore,
        ),
        login: LoginAccount(repository, session),
        restore: RestoreAccountSession(session),
        logout: LogoutAccount(session),
        lifecycle: lifecycle,
      ),
    );
  }

  final AuthenticationUseCases useCases;
  final AuthenticationLifecycleBus lifecycle;
  final DeviceEnrollmentCoordinator enrollment;
  final NetworkingFoundation networking;

  DioRestClient get restClient => networking.restClient;

  Future<void> close() => lifecycle.close();
}
