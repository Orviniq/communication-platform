import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/application_runtime.dart';
import 'package:communication_platform/features/bootstrap/application/bootstrap_flow.dart';
import 'package:communication_platform/features/bootstrap/application/ports/bootstrap_ports.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/bootstrap/infrastructure/dio_health_reachability_port.dart';
import 'package:communication_platform/features/bootstrap/infrastructure/provisioned_trust_port.dart';
import 'package:communication_platform/features/local_storage/infrastructure/protected_storage_bootstrap_adapter.dart';
import 'package:communication_platform/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart';
import 'package:flutter/widgets.dart';

Future<void> bootstrap(AppEnvironment environment) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the runtime exists, and therefore before protected storage is
  // opened or a token is read.
  //
  // Those are the operations a second delivery owner makes unsafe — not the
  // delivery session, which composes long afterwards and behind session
  // restoration. A deferred catch-up the platform started a moment ago is
  // exactly such an owner; asking here is both how this entry point waits for
  // it and how the platform learns a foreground engine now exists, which is
  // what makes that catch-up stand down instead of running to completion
  // (ADR-050). It returns immediately in the ordinary case, where nothing else
  // is running.
  await const DeliveryOwnershipGate().awaitExclusiveOwnership();
  final runtime = await ApplicationRuntime.create(
    environment,
    platform: BootstrapPlatform.android,
  );
  final flow = BootstrapFlow(
    configuration: _ResolvedBootstrapConfiguration(runtime.configuration),
    storage: ProtectedStorageBootstrapAdapter(runtime.localStorage),
    trust: const ProvisionedTrustPort(),
    health: DioHealthReachabilityPort(
      transportSecurity: runtime.transportSecurity,
      diagnostics: runtime.networkDiagnostics,
    ),
    platform: runtime.platform,
  );
  runApp(
    runtime.scope(
      child: CommunicationPlatformApp(
        environment: environment,
        bootstrapFlow: flow,
        bootstrapPlatform: runtime.platform,
        authenticationEnabled: runtime.isAuthenticated,
      ),
    ),
  );
}

final class _ResolvedBootstrapConfiguration
    implements BootstrapConfigurationPort {
  const _ResolvedBootstrapConfiguration(this.result);

  final ConfigurationLoadResult result;

  @override
  Future<ConfigurationLoadResult> load() async => result;
}
