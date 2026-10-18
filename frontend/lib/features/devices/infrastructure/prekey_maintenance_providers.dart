import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/devices/application/prekey_maintenance_service.dart';
import 'package:communication_platform/features/devices/application/scheduled_prekey_maintenance.dart';
import 'package:communication_platform/features/devices/infrastructure/dio_device_enrollment_repository.dart';
import 'package:communication_platform/features/devices/infrastructure/dio_device_prekey_repository.dart';
import 'package:communication_platform/features/devices/infrastructure/drift_enrollment_journal_store.dart';
import 'package:communication_platform/features/devices/infrastructure/drift_prekey_maintenance_store.dart';
import 'package:communication_platform/features/devices/infrastructure/native_prekey_maintenance_crypto.dart';
import 'package:communication_platform/features/devices/infrastructure/verified_rotation_device_log.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/held_envelope_adapters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef PrekeyMaintenanceScope = ({String userId, String deviceId});

/// Composes the durable native prekey state machine with the authenticated REST
/// repository. The exact scope is explicit so a service cannot rotate another
/// account's device by accident.
final prekeyMaintenanceServiceProvider =
    FutureProvider.family<PrekeyMaintenanceService, PrekeyMaintenanceScope>((
      ref,
      scope,
    ) async {
      final database = await ref.watch(localDatabaseProvider.future);
      final runtime = ref.watch(localStorageRuntimeProvider);
      final tokens = SecureSessionTokenAdapter(runtime);
      final journal = DriftEnrollmentJournalStore(
        runtime: runtime,
        tokens: tokens,
      );
      final repository = DioDeviceEnrollmentRepository(
        ref.watch(authenticatedRestClientProvider),
      );
      final deviceIdResult = await journal.currentFullSessionDeviceId();
      final currentDeviceId = deviceIdResult.fold(
        onSuccess: (value) => value,
        onFailure: (_) => null,
      );
      if (currentDeviceId == null ||
          currentDeviceId.toLowerCase() != scope.deviceId.toLowerCase()) {
        throw StateError(
          'Prekey maintenance requires the current full device.',
        );
      }
      return PrekeyMaintenanceService(
        remote: DioDevicePrekeyRepository(
          ref.watch(authenticatedRestClientProvider),
        ),
        crypto: NativePrekeyMaintenanceCrypto(
          ref.watch(pairwiseCryptoProvider),
        ),
        store: DriftPrekeyMaintenanceStore(database),
        rotationLog: VerifiedRotationDeviceLog(
          userId: scope.userId,
          repository: repository,
          journal: journal,
          crypto: ref.watch(enrollmentCryptoProvider),
          clock: ref.watch(timeSourceProvider),
        ),
        clock: ref.watch(timeSourceProvider),
        // Keeps every retired signed pair a held envelope may need
        // (ADR-093 D17).
        heldEnvelopes: SyncHeldEnvelopeRetention(DriftSyncStore(database)),
      );
    });

/// The schedule the delivery cycle runs maintenance on, one per device scope
/// (ADR-095). The engine of that scope holds it for as long as the engine
/// lives, so the schedule survives a session that stops and starts again in
/// the same process.
///
/// The service is read at the first run rather than here, so that a service
/// that cannot be composed costs one failed run instead of the engine. A
/// failed composition is forgotten, so the next run composes it afresh rather
/// than meeting the same cached error for the life of the process.
final scheduledPrekeyMaintenanceProvider =
    Provider.family<ScheduledPrekeyMaintenance, PrekeyMaintenanceScope>((
      ref,
      scope,
    ) {
      return ScheduledPrekeyMaintenance(
        clock: ref.watch(timeSourceProvider),
        maintain: () async {
          final PrekeyMaintenanceService service;
          try {
            service = await ref.read(
              prekeyMaintenanceServiceProvider(scope).future,
            );
          } on Object {
            ref.invalidate(prekeyMaintenanceServiceProvider(scope));
            rethrow;
          }
          return service.maintain(deviceId: scope.deviceId);
        },
      );
    });

/// What the delivery cycle sees of the schedule (ADR-095).
final class PrekeyMaintenanceCycleWork implements DeviceMaintenancePort {
  const PrekeyMaintenanceCycleWork(this.schedule);

  final ScheduledPrekeyMaintenance schedule;

  @override
  Future<void> runIfDue() => schedule.runIfDue();
}
