import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/own_live_set_judge.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/application/ports/linked_device_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';

/// Serializes authenticated own-account device-log mutations.  A prepared
/// record is durable before the non-idempotent append request; a response is
/// accepted only after the exact record is observed in the verified chain.
final class OwnDeviceLogCoordinator {
  const OwnDeviceLogCoordinator({
    required this.repository,
    required this.local,
    required this.crypto,
    required this.identityCrypto,
    required this.userId,
  });

  final DeviceEnrollmentRepository repository;
  final LinkedDeviceLocalPort local;
  final EnrollmentCryptoPort crypto;
  final IdentityCryptoPort identityCrypto;
  final String userId;

  Future<Result<void>> resumePendingMutation() async {
    final pendingResult = await local.readPendingMutation();
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final pending = (pendingResult as Success<PendingDeviceLogMutation?>).value;
    if (pending == null) {
      return const Result.success(null);
    }
    if (pending.state == DeviceLogMutationState.logConfirmed) {
      return const Result.success(null);
    }
    final identityResult = await local.readLocalIdentity();
    if (identityResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final identity =
        (identityResult as Success<(String, String, IdentityKeyPackage)>)
            .value
            .$3;
    final userBytes = _uuidBytes(userId);
    if (userBytes == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final verifiedResult = await _verifiedLog(identity, userBytes);
    if (verifiedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final verified = (verifiedResult as Success<_VerifiedLog>).value;
    final committed = verified.records
        .where((record) => record.sequence == pending.expectedSequence)
        .firstOrNull;
    if (committed != null) {
      if (!_same(committed.record, pending.exactRecord)) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      if (pending.kind == DeviceLogMutationKind.remove) {
        await local.writePendingMutation(
          pending.copyWith(state: DeviceLogMutationState.logConfirmed),
        );
      } else {
        await local.clearPendingMutation(pending.operationId);
        await local.setGlobalSecurityState(GlobalSecurityState.normal);
      }
      return const Result.success(null);
    }
    if (verified.sequence != pending.expectedSequence - 1 ||
        !_same(verified.hash, pending.previousHeadHash)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final appended = await repository.appendDeviceLog(
      record: pending.exactRecord,
    );
    if (appended case FailureResult(failure: final failure)) {
      if (!await _containsExact(
        pending.expectedSequence,
        pending.exactRecord,
      )) {
        return Result.failure(failure);
      }
    }
    if (!await _containsExact(pending.expectedSequence, pending.exactRecord)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    await _finishConfirmedMutation(pending);
    return const Result.success(null);
  }

  /// Verifies the complete immutable chain and returns its authenticated head.
  /// A server-provided head number alone is never accepted.
  Future<Result<AuthenticatedDeviceLogRecord?>> verifyCurrentChain() async {
    final identityResult = await local.readLocalIdentity();
    if (identityResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final tuple =
        (identityResult as Success<(String, String, IdentityKeyPackage)>).value;
    final userBytes = _uuidBytes(userId);
    if (userBytes == null || !_same(tuple.$3.userId, userBytes)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final result = await _verifiedLog(tuple.$3, userBytes);
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final verified = (result as Success<_VerifiedLog>).value;
    final committed = await _commitVerifiedChain(verified);
    if (committed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      verified.records.isEmpty ? null : verified.records.last,
    );
  }

  Future<Result<void>> appendLiveSetMutation({
    required DeviceLogMutationKind kind,
    required String? targetDeviceId,
    required List<PublicDevice> liveDevices,
    required int identityVersion,
    int concurrentRetry = 0,
  }) async {
    final pendingResult = await local.readPendingMutation();
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if ((pendingResult as Success<PendingDeviceLogMutation?>).value != null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final posture = await local.readGlobalSecurityState();
    if (posture case Success(
      value: final state,
    ) when state != GlobalSecurityState.normal) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final identityResult = await local.readLocalIdentity();
    if (identityResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final identity =
        (identityResult as Success<(String, String, IdentityKeyPackage)>)
            .value
            .$3;
    final userBytes = _uuidBytes(userId);
    if (userBytes == null || !_same(identity.userId, userBytes)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final verified = await _verifiedLog(identity, userBytes);
    if (verified case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final chain = (verified as Success<_VerifiedLog>).value;
    final committed = await _commitVerifiedChain(chain);
    if (committed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final currentResult = await repository.fetchPublicDevices(userId: userId);
    if (currentResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final current = (currentResult as Success<PublicDeviceList>).value;
    final authenticatedCurrent = await _authenticateCurrentLiveSet(
      identity: identity,
      chain: chain,
      current: current,
    );
    if (authenticatedCurrent case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final desired = kind == DeviceLogMutationKind.remove
        ? current.devices
              .where((device) => device.deviceId != targetDeviceId)
              .toList(growable: false)
        : liveDevices;
    if (kind == DeviceLogMutationKind.remove &&
        (targetDeviceId == null ||
            desired.length + 1 != current.devices.length)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final canonical = _canonicalLiveSet(desired);
    if (canonical == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final expected = chain.sequence + 1;
    final created = await crypto.createDeviceLogRecord(
      identity: identity,
      userId: userBytes,
      sequence: expected,
      previousHash: chain.hash,
      canonicalLiveSet: canonical,
      identityVersion: identityVersion,
      coarseUnixDay:
          DateTime.now().toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay,
    );
    if (created case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final exact = (created as Success<Uint8List>).value;
    final operationId = _operationId(exact, expected, targetDeviceId);
    final prepared = PendingDeviceLogMutation(
      operationId: operationId,
      userId: userId,
      kind: kind,
      targetDeviceId: targetDeviceId,
      expectedSequence: expected,
      previousHeadHash: chain.hash,
      exactRecord: exact,
      state: DeviceLogMutationState.prepared,
    );
    final saved = await local.writePendingMutation(prepared);
    if (saved case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    await local.setGlobalSecurityState(GlobalSecurityState.pendingDeviceChange);
    final appended = await repository.appendDeviceLog(record: exact);
    if (appended case FailureResult(failure: final failure)) {
      final reconciled = await _containsExact(expected, exact);
      if (reconciled) {
        await _finishConfirmedMutation(prepared);
        return const Result.success(null);
      }
      if (concurrentRetry < 2 && targetDeviceId != null) {
        final latest = await repository.fetchPublicDevices(userId: userId);
        if (latest case Success(
          value: final public,
        ) when (public.logHeadSequence ?? -1) >= expected) {
          await local.clearPendingMutation(operationId);
          await local.setGlobalSecurityState(GlobalSecurityState.normal);
          final desired = kind == DeviceLogMutationKind.remove
              ? public.devices
                    .where((device) => device.deviceId != targetDeviceId)
                    .toList(growable: false)
              : public.devices;
          return appendLiveSetMutation(
            kind: kind,
            targetDeviceId: targetDeviceId,
            liveDevices: desired,
            identityVersion: identityVersion,
            concurrentRetry: concurrentRetry + 1,
          );
        }
      }
      return Result.failure(failure);
    }
    final range = (appended as Success<DeviceLogAppendResult>).value;
    if (range.firstSequence != expected || range.lastSequence != expected) {
      final reconciled = await _containsExact(expected, exact);
      if (!reconciled) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
    }
    final confirmed = await _containsExact(expected, exact);
    if (!confirmed) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    await _finishConfirmedMutation(prepared);
    return const Result.success(null);
  }

  Future<void> _finishConfirmedMutation(
    PendingDeviceLogMutation mutation,
  ) async {
    if (mutation.kind == DeviceLogMutationKind.remove) {
      await local.writePendingMutation(
        mutation.copyWith(state: DeviceLogMutationState.logConfirmed),
      );
      return;
    }
    await local.clearPendingMutation(mutation.operationId);
    await local.setGlobalSecurityState(GlobalSecurityState.normal);
  }

  Future<Result<_VerifiedLog>> _verifiedLog(
    IdentityKeyPackage identity,
    Uint8List userBytes,
  ) async {
    final records = <AuthenticatedDeviceLogRecord>[];
    var expected = 0;
    int? after;
    var previous = Uint8List(32);
    int? fixedHead;
    for (var pageIndex = 0; pageIndex < 50; pageIndex += 1) {
      final result = await repository.fetchDeviceLog(
        userId: userId,
        after: after,
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final page = (result as Success<DeviceLogPage>).value;
      fixedHead ??= page.headSequence;
      if (fixedHead != page.headSequence ||
          (page.hasMore && page.records.isEmpty)) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      for (final record in page.records) {
        if (record.sequence != expected || records.length >= 10000) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
        }
        final inspected = await crypto.inspectDeviceLogRecord(
          identity: identity,
          userId: userBytes,
          record: record.blob,
        );
        if (inspected case FailureResult(failure: final failure)) {
          await local.setGlobalSecurityState(
            GlobalSecurityState.deviceLogFork,
            evidence: DeviceLogEvidenceKind.invalidRecord,
          );
          return Result.failure(failure);
        }
        final value = (inspected as Success<DeviceLogInspection>).value;
        if (value.sequence != expected ||
            !_same(value.previousHash, previous)) {
          await local.setGlobalSecurityState(
            GlobalSecurityState.deviceLogFork,
            evidence: DeviceLogEvidenceKind.nonExtendingHead,
          );
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.policyBlocked),
          );
        }
        previous = value.recordHash;
        records.add(
          AuthenticatedDeviceLogRecord(
            sequence: record.sequence,
            record: record.blob,
            hash: value.recordHash,
          ),
        );
        expected += 1;
        after = record.sequence;
      }
      if (!page.hasMore) {
        if (page.headSequence !=
            (records.isEmpty ? null : records.last.sequence)) {
          return const Result.failure(
            ValidationFailure(ValidationFailureKind.conflict),
          );
        }
        return Result.success(
          _VerifiedLog(
            sequence: records.isEmpty ? -1 : records.last.sequence,
            hash: previous,
            records: records,
          ),
        );
      }
    }
    return const Result.failure(
      CryptoCoreFailure(CryptoCoreFailureCode.resourceExhausted),
    );
  }

  Future<Result<void>> _commitVerifiedChain(_VerifiedLog chain) async {
    final storedResult = await local.readAuthenticatedLogHead(userId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final stored =
        (storedResult as Success<AuthenticatedDeviceLogRecord?>).value;
    if (stored != null) {
      if (chain.sequence < stored.sequence) {
        await local.setGlobalSecurityState(
          GlobalSecurityState.deviceLogFork,
          evidence: DeviceLogEvidenceKind.rollback,
        );
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      final matching = chain.records
          .where((record) => record.sequence == stored.sequence)
          .firstOrNull;
      if (matching == null || !_same(matching.hash, stored.hash)) {
        await local.setGlobalSecurityState(
          GlobalSecurityState.deviceLogFork,
          evidence: DeviceLogEvidenceKind.sequenceEquivocation,
        );
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
    }
    final appended = await local.appendAuthenticatedLogRecords(
      userId: userId,
      records: chain.records,
    );
    if (appended case FailureResult()) {
      await local.setGlobalSecurityState(
        GlobalSecurityState.deviceLogFork,
        evidence: DeviceLogEvidenceKind.sequenceEquivocation,
      );
    }
    return appended;
  }

  Future<Result<void>> _authenticateCurrentLiveSet({
    required IdentityKeyPackage identity,
    required _VerifiedLog chain,
    required PublicDeviceList current,
  }) async {
    if (chain.records.isEmpty) {
      await local.setGlobalSecurityState(
        GlobalSecurityState.deviceLogFork,
        evidence: DeviceLogEvidenceKind.liveSetMismatch,
      );
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    if (current.logHeadSequence != chain.sequence) {
      // The list was read after the chain, so another device's append can
      // land between the two. A head number is the server's word, not a
      // signed record; the chain checks above catch a fork (ADR-084).
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final verdict = await OwnLiveSetJudge(identityCrypto).judge(
      userId: _uuidBytes(userId)!,
      selfSigningPublic: identity.selfSigningPub,
      listed: current.devices,
      headRecord: chain.records.last.record,
    );
    switch (verdict) {
      case OwnLiveSetVerdict.authenticated:
        return const Result.success(null);
      case OwnLiveSetVerdict.pending:
        // A device change has not reached the log yet. No record is built
        // over a set the head does not cover, and the posture is left as it
        // is: the mutation is refused and can be asked for again.
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      case OwnLiveSetVerdict.mismatch:
        await local.setGlobalSecurityState(
          GlobalSecurityState.deviceLogFork,
          evidence: DeviceLogEvidenceKind.liveSetMismatch,
        );
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
    }
  }

  Future<bool> _containsExact(int sequence, Uint8List exact) async {
    final result = await repository.fetchDeviceLog(
      userId: userId,
      after: sequence == 0 ? null : sequence - 1,
    );
    if (result is! Success<DeviceLogPage>) return false;
    final page = result.value;
    return page.records.any(
      (record) => record.sequence == sequence && _same(record.blob, exact),
    );
  }

  Uint8List? _canonicalLiveSet(List<PublicDevice> devices) {
    final sorted = [...devices]
      ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
    final out = BytesBuilder(copy: false)
      ..add(utf8.encode('chat:v1:device-set'))
      ..add(_u32(sorted.length));
    String? last;
    for (final device in sorted) {
      if (device.deviceId == last ||
          _uuidBytes(device.deviceId) == null ||
          device.ikPub.length != 64 ||
          (device.crossSignature != null &&
              device.crossSignature!.length != 64)) {
        return null;
      }
      last = device.deviceId;
      out
        ..add(_uuidBytes(device.deviceId)!)
        ..add(_frame(device.ikPub))
        ..add(_u32(device.registrationId))
        ..add(_frame(device.crossSignature ?? Uint8List(0)))
        ..add(_u32(device.bundleVersion ?? 0));
    }
    return out.takeBytes();
  }

  String _operationId(Uint8List record, int sequence, String? target) =>
      '${base64UrlEncode(record).replaceAll('=', '')}:$sequence:${target ?? ''}';

  Uint8List _frame(Uint8List bytes) =>
      Uint8List.fromList([..._u32(bytes.length), ...bytes]);
  Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);
  Uint8List? _uuidBytes(String value) {
    final compact = value.replaceAll('-', '');
    if (compact.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
      return null;
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

final class _VerifiedLog {
  const _VerifiedLog({
    required this.sequence,
    required this.hash,
    required this.records,
  });
  final int sequence;
  final Uint8List hash;
  final List<AuthenticatedDeviceLogRecord> records;
}
