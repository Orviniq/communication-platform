import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/ports/prekey_maintenance_ports.dart';
import 'package:communication_platform/features/devices/application/prekey_maintenance_service.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replenishes both pools to their reviewed targets', () async {
    final harness = _Harness(
      counts: const [
        PrekeyCounts(classical: 49, postQuantum: 24),
        PrekeyCounts(classical: 150, postQuantum: 75),
      ],
      lastRotationDay: 104,
    );

    final result = await harness.service.maintain(deviceId: _deviceId);

    expect(result, isA<Success<PrekeyMaintenanceReport>>());
    expect(harness.crypto.prepareCalls, 1);
    expect(harness.crypto.targetClassical, 150);
    expect(harness.crypto.targetPq, 75);
    expect(
      harness.remote.uploads.single.classicalOneTimePrekeys,
      hasLength(101),
    );
    expect(harness.remote.uploads.single.pqOneTimePrekeys, hasLength(51));
    expect(harness.store.pending, isNull);
  });

  test(
    'ambiguous failure retries the exact persisted upload without regeneration',
    () async {
      final harness = _Harness(
        counts: const [
          PrekeyCounts(classical: 49, postQuantum: 75),
          PrekeyCounts(classical: 150, postQuantum: 75),
        ],
        lastRotationDay: 104,
      )..remote.failNextUpload = true;

      final first = await harness.service.maintain(deviceId: _deviceId);
      final persisted = harness.store.pending!;
      final second = await harness.service.maintain(deviceId: _deviceId);

      expect(first, isA<FailureResult<PrekeyMaintenanceReport>>());
      expect(second, isA<Success<PrekeyMaintenanceReport>>());
      expect(harness.crypto.prepareCalls, 1);
      expect(harness.remote.uploads, hasLength(2));
      expect(harness.remote.uploads[0], same(persisted.upload));
      expect(harness.remote.uploads[1], same(persisted.upload));
    },
  );

  test(
    'rotation persists exact log bytes before append and resumes them after failure',
    () async {
      final harness = _Harness(
        counts: const [
          PrekeyCounts(classical: 100, postQuantum: 50),
          PrekeyCounts(classical: 100, postQuantum: 50),
        ],
        lastRotationDay: 100,
      )..rotationLog.failNextAppend = true;

      final first = await harness.service.maintain(deviceId: _deviceId);
      final persistedLog = harness.store.pending!.rotationDeviceLog!;
      final second = await harness.service.maintain(deviceId: _deviceId);

      expect(first, isA<FailureResult<PrekeyMaintenanceReport>>());
      expect(second, isA<Success<PrekeyMaintenanceReport>>());
      expect(harness.remote.uploads, hasLength(1));
      expect(harness.rotationLog.prepareCalls, 1);
      expect(harness.rotationLog.appended, hasLength(2));
      expect(harness.rotationLog.appended[0], same(persistedLog));
      expect(harness.rotationLog.appended[1], same(persistedLog));
      expect(harness.crypto.lastRotationLogAppended, isTrue);
    },
  );

  test('reconciles native signed-key day before deciding rotation', () async {
    final harness = _Harness(
      counts: const [PrekeyCounts(classical: 100, postQuantum: 50)],
      lastRotationDay: 0,
      nativeSignedPrekeyCreatedDay: 104,
    );

    final result = await harness.service.maintain(deviceId: _deviceId);

    expect(result, isA<Success<PrekeyMaintenanceReport>>());
    expect(harness.store.lastRotationDay, 104);
    expect(harness.crypto.prepareCalls, 0);
    expect(harness.remote.uploads, isEmpty);
  });

  // ADR-093 D17. Today, T, is day 107 throughout; H is the earliest hold day
  // of a held envelope and L the day of the last rotation.
  group('an envelope held for a verification', () {
    const quiet = [
      PrekeyCounts(classical: 100, postQuantum: 50),
      PrekeyCounts(classical: 100, postQuantum: 50),
    ];

    test(
      'keeps every pair whose last day is on or after its hold day',
      () async {
        for (final (heldDay, pruneDay) in const [
          (null, 107),
          (104, 104),
          (107, 107),
          (110, 107),
        ]) {
          final harness = _Harness(
            counts: quiet,
            lastRotationDay: 104,
            heldDay: heldDay,
          );

          final result = await harness.service.maintain(deviceId: _deviceId);

          expect(result, isA<Success<PrekeyMaintenanceReport>>());
          expect(harness.crypto.pruneDays, [pruneDay], reason: 'H = $heldDay');
        }
      },
    );

    test('leaves the creation check against today', () async {
      // The current pair is from day 105 and the envelope was held on 103,
      // before that rotation: against H the pair would be from the future.
      final harness = _Harness(
        counts: quiet,
        lastRotationDay: 105,
        heldDay: 103,
      );

      final result = await harness.service.maintain(deviceId: _deviceId);

      expect(result, isA<Success<PrekeyMaintenanceReport>>());
      expect(harness.crypto.pruneDays, [103]);
    });

    test('postpones a due rotation that could erase a pair it needs', () async {
      for (final (lastRotationDay, heldDay) in const [
        // H <= L + 1: an older retired pair, kept through L + 1 at most.
        (100, 100),
        (100, 101),
        // T > L + 8 and H <= L + 8: the pair the last rotation retired.
        (98, 102),
        (98, 106),
      ]) {
        final harness = _Harness(
          counts: quiet,
          lastRotationDay: lastRotationDay,
          heldDay: heldDay,
        );

        final result = await harness.service.maintain(deviceId: _deviceId);

        expect(result, isA<Success<PrekeyMaintenanceReport>>());
        final report = (result as Success<PrekeyMaintenanceReport>).value;
        expect(
          report.rotated,
          isFalse,
          reason: 'L = $lastRotationDay, H = $heldDay',
        );
        expect(harness.crypto.prepareCalls, 0);
        expect(harness.remote.uploads, isEmpty);
      }
    });

    test('lets a due rotation run when no pair it erases is needed', () async {
      for (final (lastRotationDay, heldDay) in const [
        (100, null),
        (100, 102),
        (100, 107),
        (98, 107),
      ]) {
        final harness = _Harness(
          counts: quiet,
          lastRotationDay: lastRotationDay,
          heldDay: heldDay,
        );

        final result = await harness.service.maintain(deviceId: _deviceId);

        expect(result, isA<Success<PrekeyMaintenanceReport>>());
        expect(
          (result as Success<PrekeyMaintenanceReport>).value.rotated,
          isTrue,
          reason: 'L = $lastRotationDay, H = $heldDay',
        );
        expect(harness.crypto.rotations, [true]);
      }
    });

    test('replenishes while a rotation waits', () async {
      final harness = _Harness(
        counts: const [
          PrekeyCounts(classical: 49, postQuantum: 24),
          PrekeyCounts(classical: 150, postQuantum: 75),
        ],
        lastRotationDay: 100,
        heldDay: 101,
      );

      final result = await harness.service.maintain(deviceId: _deviceId);

      expect(result, isA<Success<PrekeyMaintenanceReport>>());
      expect(harness.crypto.rotations, [false]);
      expect(harness.crypto.targetClassical, 150);
      expect(harness.crypto.targetPq, 75);
      expect(harness.remote.uploads, hasLength(1));
    });

    test('a hold day that cannot be read stops the pass', () async {
      final harness = _Harness(
        counts: quiet,
        lastRotationDay: 100,
        heldDay: null,
        retentionFailure: const StorageFailure(StorageFailureKind.unavailable),
      );

      final result = await harness.service.maintain(deviceId: _deviceId);

      expect(result, isA<FailureResult<PrekeyMaintenanceReport>>());
      expect(harness.crypto.pruneDays, isEmpty);
    });
  });
}

const _deviceId = '22222222-2222-4222-8222-222222222222';

final class _Harness {
  _Harness({
    required List<PrekeyCounts> counts,
    required int lastRotationDay,
    int? nativeSignedPrekeyCreatedDay,
    int? heldDay,
    Failure? retentionFailure,
  }) {
    remote = _Remote(counts);
    crypto = _Crypto(nativeSignedPrekeyCreatedDay ?? lastRotationDay);
    store = _Store(lastRotationDay);
    rotationLog = _RotationLog();
    service = PrekeyMaintenanceService(
      remote: remote,
      crypto: crypto,
      store: store,
      rotationLog: rotationLog,
      clock: const _Clock(),
      heldEnvelopes: _Retention(heldDay, retentionFailure),
    );
  }

  late final _Remote remote;
  late final _Crypto crypto;
  late final _Store store;
  late final _RotationLog rotationLog;
  late final PrekeyMaintenanceService service;
}

final class _Remote implements DevicePrekeyRemotePort {
  _Remote(List<PrekeyCounts> counts) : _counts = List.of(counts);

  final List<PrekeyCounts> _counts;
  final uploads = <PrekeyUploadProjection>[];
  var failNextUpload = false;

  @override
  Future<Result<PrekeyCounts>> fetchCounts({required String deviceId}) async =>
      Result.success(_counts.removeAt(0));

  @override
  Future<Result<int>> upload({
    required String deviceId,
    required PrekeyUploadProjection upload,
  }) async {
    uploads.add(upload);
    if (failNextUpload) {
      failNextUpload = false;
      return const Result.failure(
        TransportFailure(TransportFailureKind.timeout),
      );
    }
    return const Result.success(150);
  }
}

final class _Crypto implements PrekeyMaintenanceCryptoPort {
  _Crypto(this.currentSignedPrekeyCreatedDay);

  var prepareCalls = 0;
  final pruneDays = <int>[];
  final rotations = <bool>[];
  int? targetClassical;
  int? targetPq;
  bool? lastRotationLogAppended;
  int currentSignedPrekeyCreatedDay;
  var bundleVersion = 1;

  @override
  Future<Result<PrekeyMaintenancePlan>> prepare({
    required PrekeyMaintenanceContext context,
    required PrekeyCounts serverCounts,
    required int targetClassicalCount,
    required int targetPqCount,
    required bool rotateSignedPrekeys,
    required int unixDay,
  }) async {
    prepareCalls += 1;
    rotations.add(rotateSignedPrekeys);
    targetClassical = targetClassicalCount;
    targetPq = targetPqCount;
    if (rotateSignedPrekeys) {
      currentSignedPrekeyCreatedDay = unixDay;
      bundleVersion = context.bundleVersion + 1;
    }
    final rotation = rotateSignedPrekeys
        ? SignedPrekeyRotationUpload(
            classical: SignedPrekeyUpload.classical(
              keyId: 7,
              publicKey: _bytes(32, 1),
              signature: _bytes(64, 2),
            ),
            postQuantum: SignedPrekeyUpload.postQuantum(
              keyId: 8,
              publicKey: _bytes(1184, 3),
              signature: _bytes(64, 4),
            ),
            crossSignature: _bytes(64, 5),
            bundleVersion: context.bundleVersion + 1,
          )
        : null;
    final classical = [
      for (
        var index = 0;
        index < targetClassicalCount - serverCounts.classical;
        index += 1
      )
        PrekeyUploadEntry.classical(
          keyId: index + 1,
          publicKey: _bytes(32, index & 0xff),
        ),
    ];
    final pq = [
      for (
        var index = 0;
        index < targetPqCount - serverCounts.postQuantum;
        index += 1
      )
        PrekeyUploadEntry.postQuantum(
          keyId: index + 1,
          publicKey: _bytes(1184, index & 0xff),
        ),
    ];
    return Result.success(
      PrekeyMaintenancePlan(
        deviceId: context.deviceId,
        expectedStateRevision: context.stateRevision,
        preparedUnixDay: unixDay,
        bundleVersion: bundleVersion,
        currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedDay,
        batchId: _bytes(16, 9),
        nativeUploadProjection: _bytes(32, 10),
        pendingDeviceState: _bytes(64, 11),
        upload: PrekeyUploadProjection(
          classicalOneTimePrekeys: classical,
          pqOneTimePrekeys: pq,
          rotation: rotation,
        ),
      ),
    );
  }

  @override
  Future<Result<PrekeyCommitResult>> commitPendingUpload({
    required Uint8List pendingDeviceState,
    required Uint8List batchId,
    required int unixDay,
    required bool rotationLogAppended,
  }) async {
    lastRotationLogAppended = rotationLogAppended;
    return Result.success(
      PrekeyCommitResult(
        nextDeviceState: _bytes(64, 12),
        bundleVersion: bundleVersion,
        currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedDay,
      ),
    );
  }

  @override
  Future<Result<PrekeyPruneResult>> pruneRetainedSignedPrekeys({
    required Uint8List deviceState,
    required int unixDay,
  }) async {
    pruneDays.add(unixDay);
    return Result.success(
      PrekeyPruneResult(
        nextDeviceState: deviceState,
        stateChanged: false,
        bundleVersion: bundleVersion,
        currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedDay,
        erasedSignedPrekeys: const [],
      ),
    );
  }
}

/// The earliest hold day of the inbox, or the failure to read it.
final class _Retention implements HeldEnvelopeRetentionPort {
  const _Retention(this.heldDay, this.failure);

  final int? heldDay;
  final Failure? failure;

  @override
  Future<Result<int?>> earliestHoldUnixDay() async =>
      failure == null ? Result.success(heldDay) : Result.failure(failure!);
}

final class _Store implements PrekeyMaintenanceStore {
  _Store(this.lastRotationDay);

  int lastRotationDay;
  PrekeyMaintenancePlan? pending;

  @override
  Future<Result<void>> complete({
    required PrekeyMaintenancePlan plan,
    required PrekeyCounts confirmedCounts,
    required PrekeyCommitResult committed,
  }) async {
    lastRotationDay = committed.currentSignedPrekeyCreatedUnixDay;
    pending = null;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> markUploadAccepted({
    required PrekeyMaintenancePlan plan,
  }) async {
    pending = plan;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> persistPrepared(PrekeyMaintenancePlan plan) async {
    pending = plan;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> persistRotationLogPrepared({
    required PrekeyMaintenancePlan plan,
  }) async {
    pending = plan;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> persistNativeSummary({
    required String deviceId,
    required int expectedStateRevision,
    required Uint8List nextDeviceState,
    required bool stateChanged,
    required int bundleVersion,
    required int currentSignedPrekeyCreatedUnixDay,
    required List<ErasedSignedPrekeyPair> erasedSignedPrekeys,
  }) async {
    lastRotationDay = currentSignedPrekeyCreatedUnixDay;
    return const Result.success(null);
  }

  @override
  Future<Result<PrekeyMaintenanceContext>> readContext({
    required String deviceId,
  }) async => Result.success(
    PrekeyMaintenanceContext(
      deviceId: deviceId,
      userId: _bytes(16, 1),
      rawDeviceId: _bytes(16, 2),
      opaqueDeviceState: _bytes(64, 3),
      opaqueIdentityState: _bytes(64, 4),
      stateRevision: 1,
      bundleVersion: 1,
      lastSignedPrekeyRotationUnixDay: lastRotationDay,
    ),
  );

  @override
  Future<Result<PrekeyMaintenancePlan?>> readPending({
    required String deviceId,
  }) async => Result.success(pending);
}

final class _RotationLog implements RotationDeviceLogPort {
  var failNextAppend = false;
  var prepareCalls = 0;
  final appended = <PreparedRotationDeviceLog>[];

  @override
  Future<Result<PreparedRotationDeviceLog>> prepareOwnRotation(
    PrekeyMaintenancePlan plan,
  ) async {
    prepareCalls += 1;
    return Result.success(
      PreparedRotationDeviceLog(
        expectedSequence: 4,
        previousHeadHash: _bytes(32, 8),
        exactRecord: _bytes(256, 9),
      ),
    );
  }

  @override
  Future<Result<void>> appendOrReconcile(
    PreparedRotationDeviceLog prepared,
  ) async {
    appended.add(prepared);
    if (failNextAppend) {
      failNextAppend = false;
      return const Result.failure(
        TransportFailure(TransportFailureKind.timeout),
      );
    }
    return const Result.success(null);
  }
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(
    107 * Duration.millisecondsPerDay,
    isUtc: true,
  );
}

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));
