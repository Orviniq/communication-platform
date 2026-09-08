import 'package:communication_platform/app/config/app_configuration.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/authentication_assembly.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/provisioned_transport.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/core/application/ports/crypto_core_port.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/devices/presentation/device_enrollment_controller.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/local_storage/infrastructure/platform/platform_local_storage_native.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/shared/infrastructure/crypto/platform_crypto_core_native.dart';
import 'package:communication_platform/shared/infrastructure/crypto/unsupported_enrollment_crypto.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Everything an entry point of this application has to build before any of it
/// can do anything, built once and in one place.
///
/// There are two entry points on Android — the activity the user opens, and the
/// headless catch-up the platform starts when nobody is looking — and they must
/// establish *identical* security posture. The dangerous failure is not that
/// the second one crashes; it is that it quietly composes a weaker one: the
/// public root store instead of the provisioned authority, a second token
/// coordinator beside the first, a crypto core built without the compiled
/// environment's permit. Nothing here is optional or per-entry-point, so there
/// is no configuration a background path can be missing, and a test can assert
/// that both entry points go through this constructor rather than assert the
/// absence of a mistake.
final class ApplicationRuntime {
  ApplicationRuntime._({
    required this.environment,
    required this.platform,
    required this.configuration,
    required this.transportSecurity,
    required this.localStorage,
    required this.cryptoCore,
    required this.enrollmentCrypto,
    required this.authentication,
    required this.networkDiagnostics,
  });

  static Future<ApplicationRuntime> create(
    AppEnvironment environment, {
    required BootstrapPlatform platform,
  }) async {
    final localStorage = createPlatformLocalStorageRuntime();
    final configuration = await CompileTimeBootstrapConfiguration(
      environment: environment,
      platform: platform,
    ).load();
    // Trust for the transport the app actually uses. Android's network security
    // configuration does not reach dart:io, so without this the client would
    // fall back to the public root store and never trust the provisioned
    // server.
    final transportSecurity = switch (configuration) {
      ConfigurationLoaded(:final configuration) => provisionedTransportSecurity(
        configuration.trustMaterial,
      ),
      ConfigurationNotProvisioned() =>
        const TransportSecurity.platformDefault(),
    };
    // One recorder per process, created here so the activity and the
    // headless catch-up count into the same one rather than each keeping a
    // private tally of half the traffic.
    final networkDiagnostics = RecordingNetworkDiagnostics();
    final cryptoCore = createPlatformCryptoCore(
      betaMlsEnabled: environment == AppEnvironment.beta,
    );
    final enrollmentCrypto = cryptoCore is EnrollmentCryptoPort
        ? cryptoCore as EnrollmentCryptoPort
        : const UnsupportedEnrollmentCrypto();
    return ApplicationRuntime._(
      environment: environment,
      platform: platform,
      configuration: configuration,
      transportSecurity: transportSecurity,
      localStorage: localStorage,
      cryptoCore: cryptoCore,
      enrollmentCrypto: enrollmentCrypto,
      networkDiagnostics: networkDiagnostics,
      authentication: switch (configuration) {
        ConfigurationLoaded(:final configuration) =>
          AuthenticationAssembly.create(
            serverOrigin: configuration.serverOrigin.uri,
            localStorage: localStorage,
            timeSource: const SystemTimeSource(),
            enrollmentCrypto: enrollmentCrypto,
            transportSecurity: transportSecurity,
            diagnostics: networkDiagnostics,
          ),
        ConfigurationNotProvisioned() => null,
      },
    );
  }

  final AppEnvironment environment;
  final BootstrapPlatform platform;
  final ConfigurationLoadResult configuration;
  final TransportSecurity transportSecurity;
  final SecureLocalStorageRuntime localStorage;
  final CryptoCorePort cryptoCore;
  final EnrollmentCryptoPort enrollmentCrypto;

  /// Counts request outcomes for the life of this process, and nothing
  /// else. Payload-free by the type it records, memory-only by decision, and
  /// read only by a diagnostics export the user asks for.
  final RecordingNetworkDiagnostics networkDiagnostics;

  /// Null when this build carries no provisioning, in which case nothing
  /// authenticated is composed at all rather than composed against a default.
  final AuthenticationAssembly? authentication;

  bool get isAuthenticated => authentication != null;

  /// The overrides every scope in this application installs.
  ///
  /// A scope built without them has no transport, no storage and no crypto
  /// core, which is why the two entry points below take a whole scope from here
  /// rather than assembling one from parts and hoping they match.
  late final _overrides = [
    if (authentication case final assembly?) ...[
      authenticationUseCasesProvider.overrideWithValue(assembly.useCases),
      deviceEnrollmentCoordinatorProvider.overrideWithValue(
        assembly.enrollment,
      ),
      authenticatedRestClientProvider.overrideWithValue(assembly.restClient),
      // The delivery path's socket is built from this, so it shares the one
      // token coordinator and the one provisioned trust context above rather
      // than opening a second authenticated transport beside them.
      networkingFoundationProvider.overrideWithValue(assembly.networking),
    ],
    appEnvironmentProvider.overrideWithValue(environment),
    networkDiagnosticsProvider.overrideWithValue(networkDiagnostics),
    cryptoCoreProvider.overrideWithValue(cryptoCore),
    enrollmentCryptoProvider.overrideWithValue(enrollmentCrypto),
    localStorageRuntimeProvider.overrideWith((ref) {
      ref.onDispose(localStorage.close);
      return localStorage;
    }),
  ];

  /// The scope the application root runs in.
  ProviderScope scope({required Widget child}) =>
      ProviderScope(overrides: _overrides, child: child);

  /// The container a headless entry point runs in, with the same overrides and
  /// therefore the same transport trust, the same token coordinator and the
  /// same crypto core as the scope above.
  ///
  /// [standDown] is the one thing only a headless run has and the activity
  /// cannot: a way to be told it no longer owns delivery. It is an addition to
  /// the overrides above and never a replacement for one, which is what keeps
  /// the two entry points from drifting into different security postures.
  ProviderContainer container({DeliveryStandDownSignal? standDown}) =>
      ProviderContainer(
        overrides: [
          ..._overrides,
          if (standDown != null)
            deliveryStandDownProvider.overrideWithValue(standDown),
        ],
      );

  /// Releases what a short-lived entry point owns.
  ///
  /// The application root does not call this: its container lives as long as
  /// the process and closes storage through the override above. A headless run
  /// does, because the alternative is a Keystore-unwrapped database left open
  /// in a process the platform is about to freeze.
  Future<void> close() async {
    await authentication?.close();
    await cryptoCore.close();
    // Awaited rather than left to the container's `onDispose`, which cannot
    // await a future: a Keystore-unwrapped database still closing when the
    // platform freezes the process is a handle left open on encrypted state.
    await localStorage.close();
  }
}
