import 'package:communication_platform/app/bootstrap.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/deferred_delivery_catch_up.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery_run.dart';

Future<void> main() => bootstrap(AppEnvironment.production);

/// The headless entry point the platform runs for a deferred catch-up.
///
/// One per flavor, deliberately. The compiled environment is what decides the
/// provisioned server and the trust anchor, and
/// this repository holds that it must be fixed by the entry point rather than
/// selectable at runtime — so the platform picks a *name*, and which
/// `AppEnvironment` that name resolves to is decided by which file was
/// compiled. A build asked for an entry point it does not contain fails to
/// start one, which is the fail-closed direction.
@pragma('vm:entry-point')
Future<void> backgroundDelivery() =>
    runDeferredDeliveryEntryPoint(AppEnvironment.production);

/// The headless entry point the sustained delivery service runs.
///
/// One per flavor, for the same reason the deferred one is: the platform picks
/// a *name*, and which `AppEnvironment` that name resolves to is decided by
/// which file was compiled, so nothing about the provisioned server or the
/// trust anchor is selectable at runtime. A build
/// asked for an entry point it does not contain fails to start one, which is
/// the fail-closed direction.
@pragma('vm:entry-point')
Future<void> sustainedDelivery() =>
    runSustainedDeliveryEntryPoint(AppEnvironment.production);
