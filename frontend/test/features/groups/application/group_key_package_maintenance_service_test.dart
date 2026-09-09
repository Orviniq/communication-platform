import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_key_package_maintenance_service.dart';
import 'package:communication_platform/features/groups/application/ports/group_key_package_ports.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replenishes consumables and separately uploads last resort', () async {
    final harness = _Harness(count: 15);

    final result = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );

    expect(result, isA<Success<GroupKeyPackageMaintenanceReport>>());
    final report = (result as Success<GroupKeyPackageMaintenanceReport>).value;
    expect(report.uploadedConsumables, 35);
    expect(report.uploadedLastResort, isTrue);
    expect(harness.crypto.requests, hasLength(2));
    expect(harness.crypto.requests[0].priorOpaqueKeyPackageState, isNull);
    expect(
      harness.crypto.requests[1].priorOpaqueKeyPackageState,
      orderedEquals(_bytes(64, 1)),
    );
    expect(harness.remote.uploads.map((upload) => upload.kind), [
      MlsKeyPackageKind.consumable,
      MlsKeyPackageKind.lastResort,
    ]);
    expect(harness.store.pending, isNull);
    expect(harness.store.lastResortUploaded, isTrue);
    expect(harness.store.stateRevision, 2);
  });

  test('ambiguous consumable upload is never replayed', () async {
    final harness = _Harness(count: 19)
      ..remote.failures.add(
        const TransportFailure(TransportFailureKind.timeout),
      );

    final first = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );
    final second = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );

    expect(first, isA<FailureResult<GroupKeyPackageMaintenanceReport>>());
    expect(second, isA<FailureResult<GroupKeyPackageMaintenanceReport>>());
    expect(
      (second as FailureResult<GroupKeyPackageMaintenanceReport>).failure,
      isA<SecurityFailure>().having(
        (failure) => failure.kind,
        'kind',
        SecurityFailureKind.policyBlocked,
      ),
    );
    expect(harness.crypto.requests, hasLength(1));
    expect(harness.remote.uploads, hasLength(1));
    expect(harness.store.pending!.stage, GroupKeyPackagePlanStage.ambiguous);
  });

  test('process death after attempt checkpoint becomes ambiguous', () async {
    final harness = _Harness(count: 100);
    harness.store.pending = GroupKeyPackagePreparedPlan(
      deviceId: _deviceId,
      expectedStateRevision: 0,
      nextSealedKeyPackageState: _bytes(64, 4),
      upload: GroupKeyPackageUpload(
        kind: MlsKeyPackageKind.consumable,
        wrappedKeyPackages: [_bytes(4096, 5)],
      ),
      stage: GroupKeyPackagePlanStage.attemptStarted,
    );

    final result = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );

    expect(result, isA<FailureResult<GroupKeyPackageMaintenanceReport>>());
    expect(harness.remote.uploads, isEmpty);
    expect(harness.crypto.requests, isEmpty);
    expect(harness.store.pending!.stage, GroupKeyPackagePlanStage.ambiguous);
  });

  test('last-resort timeout retries exact persisted bytes', () async {
    final harness = _Harness(count: 100)
      ..remote.failures.add(
        const TransportFailure(TransportFailureKind.timeout),
      );

    final first = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );
    final exact = harness.store.pending!.upload.wrappedKeyPackages.first;
    final second = await harness.service.maintain(
      userId: _userId,
      deviceId: _deviceId,
    );

    expect(first, isA<FailureResult<GroupKeyPackageMaintenanceReport>>());
    expect(second, isA<Success<GroupKeyPackageMaintenanceReport>>());
    expect(harness.crypto.requests, hasLength(1));
    expect(harness.remote.uploads, hasLength(2));
    expect(
      harness.remote.uploads[0].wrappedKeyPackages.single,
      orderedEquals(exact),
    );
    expect(
      harness.remote.uploads[1].wrappedKeyPackages.single,
      orderedEquals(exact),
    );
  });

  test(
    'definite rejection preserves an exact retryable consumable plan',
    () async {
      final harness = _Harness(count: 19)
        ..remote.failures.add(
          const BackendFailure(BackendFailureCode.throttled),
        );

      final first = await harness.service.maintain(
        userId: _userId,
        deviceId: _deviceId,
      );
      final exact = harness.store.pending!.upload.wrappedKeyPackages.first;
      final second = await harness.service.maintain(
        userId: _userId,
        deviceId: _deviceId,
      );

      expect(first, isA<FailureResult<GroupKeyPackageMaintenanceReport>>());
      expect(second, isA<Success<GroupKeyPackageMaintenanceReport>>());
      expect(harness.crypto.requests, hasLength(1));
      expect(harness.remote.uploads, hasLength(2));
      expect(
        harness.remote.uploads[0].wrappedKeyPackages.first,
        orderedEquals(exact),
      );
      expect(
        harness.remote.uploads[1].wrappedKeyPackages.first,
        orderedEquals(exact),
      );
    },
  );
}

const _userId = '10000000-0000-4000-8000-000000000001';
const _deviceId = '20000000-0000-4000-8000-000000000002';

final class _Harness {
  _Harness({required int count}) {
    remote = _Remote(count);
    crypto = _Crypto();
    store = _Store();
    service = GroupKeyPackageMaintenanceService(
      remote: remote,
      authentication: const _Authentication(),
      crypto: crypto,
      store: store,
      clock: const _Clock(),
    );
  }

  late final _Remote remote;
  late final _Crypto crypto;
  late final _Store store;
  late final GroupKeyPackageMaintenanceService service;
}

final class _Remote implements GroupKeyPackageRemotePort {
  _Remote(this.count);

  int count;
  final failures = <Failure>[];
  final uploads = <GroupKeyPackageUpload>[];

  @override
  Future<Result<int>> fetchConsumableCount({required String deviceId}) async =>
      Result.success(count);

  @override
  Future<Result<int>> upload({
    required String deviceId,
    required GroupKeyPackageUpload upload,
  }) async {
    uploads.add(upload);
    if (failures.isNotEmpty) return Result.failure(failures.removeAt(0));
    if (upload.kind == MlsKeyPackageKind.consumable) {
      count += upload.wrappedKeyPackages.length;
    }
    return Result.success(count);
  }

  @override
  Future<Result<List<ClaimedGroupKeyPackage>>> claim({
    required String userId,
    List<String>? deviceIds,
  }) async => throw UnimplementedError();
}

final class _Authentication implements GroupKeyPackageAuthenticationPort {
  const _Authentication();

  @override
  Future<Result<GroupKeyPackageAuthenticationEvidence>>
  authenticateCurrentDevice({
    required String userId,
    required String deviceId,
  }) async => Result.success(
    GroupKeyPackageAuthenticationEvidence(
      localVerifiedBundleRequest: _bytes(256, 7),
    ),
  );

  @override
  Future<Result<GroupPeerAuthenticationEvidence>> authenticatePeerDevices({
    required String userId,
    required List<String> deviceIds,
  }) async => throw UnimplementedError();
}

final class _Crypto implements GroupMlsCryptoPort {
  final requests = <MlsKeyPackageGenerationRequest>[];

  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) => _unused();

  @override
  Future<Result<GeneratedMlsKeyPackages>> generateKeyPackages(
    MlsKeyPackageGenerationRequest request,
  ) async {
    requests.add(request);
    return Result.success(
      GeneratedMlsKeyPackages(
        kind: request.kind,
        opaqueKeyPackageState: _bytes(64, requests.length),
        wrappedKeyPackages: [
          for (var index = 0; index < request.count; index += 1)
            _bytes(4096, index + requests.length),
        ],
      ),
    );
  }

  Future<Result<T>> _unused<T>() async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => _unused();

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => _unused();

  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => _unused();

  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) => _unused();

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) => _unused();

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) => _unused();

  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) => _unused();
}

final class _Store implements GroupKeyPackageMaintenanceStore {
  GroupKeyPackagePreparedPlan? pending;
  Uint8List? sealedState;
  var stateRevision = 0;
  var lastResortUploaded = false;

  @override
  Future<Result<void>> complete(GroupKeyPackagePreparedPlan plan) async {
    if (pending?.stage != plan.stage) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    if (plan.upload.kind == MlsKeyPackageKind.lastResort) {
      lastResortUploaded = true;
    }
    pending = null;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> moveStage({
    required GroupKeyPackagePreparedPlan plan,
    required GroupKeyPackagePlanStage nextStage,
  }) async {
    if (pending?.stage != plan.stage) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    pending = plan.withStage(nextStage);
    return const Result.success(null);
  }

  @override
  Future<Result<void>> persistPrepared(GroupKeyPackagePreparedPlan plan) async {
    if (pending != null || stateRevision != plan.expectedStateRevision) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    sealedState = Uint8List.fromList(plan.nextSealedKeyPackageState);
    stateRevision += 1;
    pending = plan;
    return const Result.success(null);
  }

  @override
  Future<Result<GroupKeyPackageGenerationContext>> readGenerationContext({
    required String deviceId,
  }) async => Result.success(
    GroupKeyPackageGenerationContext(
      deviceId: _deviceId,
      opaqueDeviceState: _bytes(128, 8),
      sealedKeyPackageState: sealedState,
      keyPackageStateRevision: stateRevision,
      lastResortUploaded: lastResortUploaded,
    ),
  );

  @override
  Future<Result<GroupKeyPackagePreparedPlan?>> readPending({
    required String deviceId,
  }) async => Result.success(pending);
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 9);
}

Uint8List _bytes(int length, int value) =>
    Uint8List(length)..fillRange(0, length, value & 0xff);
