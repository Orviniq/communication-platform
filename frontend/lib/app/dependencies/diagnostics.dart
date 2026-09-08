import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/build_identity.dart';
import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/deployment_disclosure_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_alerts.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/settings.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/diagnostics/application/collect_diagnostics.dart';
import 'package:communication_platform/features/diagnostics/application/ports/diagnostics_ports.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/features/diagnostics/infrastructure/drift_local_state_diagnostics.dart';
import 'package:communication_platform/features/diagnostics/infrastructure/network_diagnostics_source.dart';
import 'package:communication_platform/features/notifications/domain/message_alert_model.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:communication_platform/shared/infrastructure/crypto/unsupported_enrollment_crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The report a user asked for, built once per visit to the screen.
///
/// `autoDispose` on purpose: nothing here is kept after the screen closes, so
/// no description of somebody's device sits in memory for the rest of the
/// session waiting to be found.
final diagnosticsReportProvider = FutureProvider.autoDispose<DiagnosticsReport>(
  (ref) async {
    final sources = <DiagnosticsSourcePort>[
      _RuntimeDiagnosticsSource(ref),
      NetworkDiagnosticsSource(ref.watch(networkDiagnosticsProvider)),
    ];
    try {
      sources.add(
        DriftLocalStateDiagnostics(
          await ref.watch(localDatabaseProvider.future),
        ),
      );
    } on Object {
      // No database in this composition, or it cannot be opened. The runtime
      // source still answers, and the report simply carries no storage section
      // rather than failing the screen that exists to describe the failure.
    }
    return CollectDiagnostics(
      sources: sources,
      time: ref.watch(timeSourceProvider),
    ).call();
  },
);

/// What the composition root already knows about the running artifact.
///
/// Every read is guarded. A diagnostics screen exists for the case where
/// something is wrong, so a provider that throws because its dependency is
/// missing has to become a stated `unknown` rather than an empty screen.
final class _RuntimeDiagnosticsSource implements DiagnosticsSourcePort {
  const _RuntimeDiagnosticsSource(this.ref);

  final Ref ref;

  @override
  Future<List<DiagnosticEntry>> collect() async {
    final environment = _or(
      () => ref.watch(appEnvironmentProvider),
      AppEnvironment.development,
    );
    final disclosure = environment.deploymentDisclosure;
    final acknowledged = await _orNullAsync(
      () => ref.watch(disclosureAcknowledgementStateProvider.future),
    );
    final appearance = _orNull(() => ref.watch(appearancePreferencesProvider));
    final abi = _orNull(() => ref.watch(runtimeAbiProvider));
    final cryptoComposed = _or(
      () => ref.watch(enrollmentCryptoProvider) is! UnsupportedEnrollmentCrypto,
      false,
    );
    final groups = _orNull(() => ref.watch(groupFeatureAvailabilityProvider));
    final session = _orNull(
      () => ref.watch(authenticationControllerProvider).access,
    );
    final delivery = _orNull(
      () => ref.watch(messageDeliveryControllerProvider),
    );
    final alerts = await _orNullAsync(
      () async =>
          (await ref.watch(messageAlertPresenterProvider).platformState())
              ?.authorization,
    );
    final sustained = _orNull(
      () => ref.watch(sustainedDeliveryControllerProvider),
    );

    return [
      DiagnosticEntry(
        DiagnosticField.applicationVersion,
        DiagnosticValue.constant(BuildIdentity.version),
      ),
      DiagnosticEntry(
        DiagnosticField.buildFlavor,
        DiagnosticValue.term(environment),
      ),
      DiagnosticEntry(
        DiagnosticField.disclosureRevision,
        DiagnosticValue.number(disclosure?.revision ?? 0),
      ),
      DiagnosticEntry(
        DiagnosticField.disclosureAccepted,
        acknowledged == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.number(acknowledged.acknowledgedRevision),
      ),
      DiagnosticEntry(
        DiagnosticField.languagePreference,
        appearance == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(appearance.language),
      ),
      DiagnosticEntry(
        DiagnosticField.themePreference,
        appearance == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(appearance.theme),
      ),
      DiagnosticEntry(
        DiagnosticField.platform,
        DiagnosticValue.constant('android'),
      ),
      DiagnosticEntry(
        DiagnosticField.nativeAbi,
        abi == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(abi),
      ),
      DiagnosticEntry(
        DiagnosticField.cryptoCore,
        DiagnosticValue.term(
          cryptoComposed
              ? DiagnosticWord.available
              : DiagnosticWord.unavailable,
        ),
      ),
      DiagnosticEntry(
        DiagnosticField.groupSurface,
        groups == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(groups),
      ),
      DiagnosticEntry(
        DiagnosticField.sessionState,
        session == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(session),
      ),
      DiagnosticEntry(
        DiagnosticField.notificationAuthorization,
        DiagnosticValue.term(alerts ?? MessageAlertAuthorization.unavailable),
      ),
      DiagnosticEntry(
        DiagnosticField.sustainedDelivery,
        DiagnosticValue.term(sustained ?? SustainedDeliveryStatus.unavailable),
      ),
      DiagnosticEntry(
        DiagnosticField.deliverySession,
        delivery == null
            ? const DiagnosticValue.term(DiagnosticWord.unknown)
            : DiagnosticValue.term(delivery),
      ),
    ];
  }

  T _or<T>(T Function() read, T fallback) {
    try {
      return read();
    } on Object {
      return fallback;
    }
  }

  T? _orNull<T>(T Function() read) {
    try {
      return read();
    } on Object {
      return null;
    }
  }

  Future<T?> _orNullAsync<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }
}
