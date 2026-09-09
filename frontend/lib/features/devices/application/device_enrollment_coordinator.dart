import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';

final class DeviceEnrollmentCoordinator {
  const DeviceEnrollmentCoordinator({
    required this.repository,
    required this.store,
    required this.crypto,
    required this.clock,
  });

  final DeviceEnrollmentRepository repository;
  final EnrollmentJournalStore store;
  final EnrollmentCryptoPort crypto;
  final TimeSource clock;

  Future<Result<EnrollmentJournal>> loadOrStart({
    required String userId,
  }) async {
    final stored = await store.read(userId: userId);
    switch (stored) {
      case FailureResult(failure: final failure):
        return Result.failure(failure);
      case Success(value: final journal?):
        if (journal.phase == EnrollmentPhase.restoringIdentity) {
          final resumed = journal.copyWith(
            phase: EnrollmentPhase.awaitingRecoverySecret,
            clearMessage: true,
          );
          final persisted = await store.update(resumed);
          return persisted.fold(
            onSuccess: (_) => Result.success(resumed),
            onFailure: Result.failure,
          );
        }
        if (journal.phase == EnrollmentPhase.registrationOutcomeUnknown ||
            journal.phase == EnrollmentPhase.recoverySecret ||
            journal.phase == EnrollmentPhase.awaitingRecoverySecret ||
            journal.phase == EnrollmentPhase.securityNotice ||
            journal.phase == EnrollmentPhase.blocked) {
          return Result.success(journal);
        }
        return _resume(journal.copyWith(clearMessage: true));
      case Success(value: null):
        break;
    }

    final newAccount = await store.isNewAccount(userId: userId);
    if (newAccount case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final userBytes = _uuidBytes(userId);
    if (userBytes == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final prepared = await crypto.prepareDevice(userId: userBytes);
    if (prepared case FailureResult(failure: final failure)) {
      userBytes.fillRange(0, userBytes.length, 0);
      return Result.failure(failure);
    }
    final device = (prepared as Success<DeviceKeyPackage>).value;
    final flow = (newAccount as Success<bool>).value
        ? EnrollmentFlow.firstDevice
        : EnrollmentFlow.laterDevice;
    final journal = EnrollmentJournal(
      userId: userId,
      flow: flow,
      phase: EnrollmentPhase.registrationReady,
      fingerprint: device.public.fingerprint,
      devicePackage: device,
    );
    userBytes.fillRange(0, userBytes.length, 0);
    final persisted = await store.persistPrepared(journal);
    if (persisted case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return _resume(journal);
  }

  Future<Result<EnrollmentJournal>> retry({required String userId}) async {
    final stored = await store.read(userId: userId);
    if (stored case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final journal = (stored as Success<EnrollmentJournal?>).value;
    if (journal == null) {
      return loadOrStart(userId: userId);
    }
    if (journal.phase == EnrollmentPhase.registrationOutcomeUnknown ||
        journal.phase == EnrollmentPhase.blocked) {
      return Result.success(journal);
    }
    return _resume(journal.copyWith(clearMessage: true));
  }

  Future<Result<EnrollmentJournal>> confirmRecoverySecret({
    required String userId,
  }) async {
    final current = await _requiredJournal(userId);
    if (current case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var journal = (current as Success<EnrollmentJournal>).value;
    final identity = journal.identityPackage;
    if (journal.flow != EnrollmentFlow.firstDevice ||
        journal.phase != EnrollmentPhase.recoverySecret ||
        identity == null ||
        !identity.hasDisplayMaterial) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final backup = Uint8List.fromList(identity.backup);
    final sanitized = await crypto.sanitizeIdentity(package: identity);
    if (sanitized case FailureResult(failure: final failure)) {
      backup.fillRange(0, backup.length, 0);
      return Result.failure(failure);
    }
    journal = journal.copyWith(
      phase: EnrollmentPhase.finishingSecureSetup,
      identityPackage: (sanitized as Success<IdentityKeyPackage>).value,
      backup: backup,
      recoverySecretDisplayed: true,
      recoveryConfirmed: true,
      clearMessage: true,
    );
    final persisted = await store.update(journal);
    if (persisted case FailureResult(failure: final failure)) {
      backup.fillRange(0, backup.length, 0);
      journal.identityPackage?.opaqueBytes.fillRange(
        0,
        journal.identityPackage!.opaqueBytes.length,
        0,
      );
      return Result.failure(failure);
    }
    identity.backup.fillRange(0, identity.backup.length, 0);
    identity.recoverySecretBytes.fillRange(
      0,
      identity.recoverySecretBytes.length,
      0,
    );
    identity.opaqueBytes.fillRange(0, identity.opaqueBytes.length, 0);
    return _resume(journal);
  }

  Future<Result<EnrollmentJournal>> markRecoverySecretDisplayed({
    required String userId,
  }) async {
    final current = await _requiredJournal(userId);
    if (current case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final journal = (current as Success<EnrollmentJournal>).value;
    if (journal.phase != EnrollmentPhase.recoverySecret) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final updated = journal.copyWith(recoverySecretDisplayed: true);
    final persisted = await store.update(updated);
    return persisted.fold(
      onSuccess: (_) => Result.success(updated),
      onFailure: Result.failure,
    );
  }

  Future<Result<EnrollmentJournal>> restoreWithRecoverySecret({
    required String userId,
    required Uint8List recoverySecret,
  }) async {
    final current = await _requiredJournal(userId);
    if (current case FailureResult(failure: final failure)) {
      recoverySecret.fillRange(0, recoverySecret.length, 0);
      return Result.failure(failure);
    }
    var journal = (current as Success<EnrollmentJournal>).value;
    final backup = journal.backup;
    if (journal.flow != EnrollmentFlow.laterDevice ||
        journal.phase != EnrollmentPhase.awaitingRecoverySecret ||
        backup == null) {
      recoverySecret.fillRange(0, recoverySecret.length, 0);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    journal = journal.copyWith(
      phase: EnrollmentPhase.restoringIdentity,
      clearMessage: true,
    );
    final persisted = await store.update(journal);
    if (persisted case FailureResult(failure: final failure)) {
      recoverySecret.fillRange(0, recoverySecret.length, 0);
      return Result.failure(failure);
    }
    final userBytes = _uuidBytes(userId);
    if (userBytes == null) {
      recoverySecret.fillRange(0, recoverySecret.length, 0);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final restored = await crypto.restoreIdentity(
      userId: userBytes,
      recoverySecret: recoverySecret,
      backup: Uint8List.fromList(backup),
    );
    recoverySecret.fillRange(0, recoverySecret.length, 0);
    userBytes.fillRange(0, userBytes.length, 0);
    if (restored case FailureResult(failure: final failure)) {
      final wrongSecret =
          failure is CryptoCoreFailure &&
          failure.code == CryptoCoreFailureCode.authenticationFailed;
      final paused = journal.copyWith(
        phase: wrongSecret
            ? EnrollmentPhase.awaitingRecoverySecret
            : EnrollmentPhase.blocked,
        message: wrongSecret
            ? EnrollmentMessage.wrongRecoverySecret
            : _messageFor(failure),
      );
      await store.update(paused);
      return Result.success(paused);
    }
    final identity = (restored as Success<IdentityKeyPackage>).value;
    final published = await repository.fetchIdentity(userId: userId);
    if (published case FailureResult(failure: final failure)) {
      _zeroIdentity(identity);
      final paused = journal.copyWith(
        phase: EnrollmentPhase.awaitingRecoverySecret,
        message: _messageFor(failure),
      );
      await store.update(paused);
      return Result.success(paused);
    }
    final serverIdentity = (published as Success<PublishedIdentity>).value;
    if (!_identityMatches(identity, serverIdentity)) {
      _zeroIdentity(identity);
      final blocked = journal.copyWith(
        phase: EnrollmentPhase.blocked,
        message: EnrollmentMessage.invalidVector,
      );
      await store.update(blocked);
      return Result.success(blocked);
    }
    journal = journal.copyWith(
      phase: EnrollmentPhase.finishingSecureSetup,
      identityPackage: identity,
      identityVersion: serverIdentity.version,
      clearBackup: true,
      clearMessage: true,
    );
    final identityPersisted = await store.update(journal);
    if (identityPersisted case FailureResult(failure: final failure)) {
      _zeroIdentity(identity);
      return Result.failure(failure);
    }
    return _resume(journal);
  }

  Future<Result<EnrollmentJournal>> reconcileAmbiguousRegistration({
    required String userId,
  }) async {
    final current = await _requiredJournal(userId);
    if (current case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var journal = (current as Success<EnrollmentJournal>).value;
    if (journal.phase != EnrollmentPhase.registrationOutcomeUnknown) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final devices = await repository.fetchPublicDevices(userId: userId);
    if (devices case FailureResult(failure: final failure)) {
      return _pause(
        journal,
        EnrollmentPhase.registrationOutcomeUnknown,
        failure,
      );
    }
    final listing = (devices as Success<PublicDeviceList>).value;
    final matches = listing.devices
        .where(
          (device) =>
              device.isUnsigned &&
              _same(device.ikPub, journal.devicePackage.public.ikPub),
        )
        .toList(growable: false);
    if (matches.length > 1) {
      final blocked = journal.copyWith(
        phase: EnrollmentPhase.blocked,
        message: EnrollmentMessage.invalidVector,
      );
      await store.update(blocked);
      return Result.success(blocked);
    }
    if (matches.isEmpty) {
      journal = journal.copyWith(
        phase: EnrollmentPhase.registrationReady,
        clearMessage: true,
      );
      await store.update(journal);
      return _resume(journal);
    }
    final sessionDevice = await store.currentFullSessionDeviceId();
    if (sessionDevice case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final match = matches.single;
    if ((sessionDevice as Success<String?>).value == match.deviceId) {
      journal = journal.copyWith(
        phase: EnrollmentPhase.registeredUnsigned,
        deviceId: match.deviceId,
        clearMessage: true,
      );
      await store.update(journal);
      return _resume(journal);
    }
    final revoked = await repository.revokeDevice(deviceId: match.deviceId);
    if (revoked case FailureResult(failure: final failure)) {
      return _pause(
        journal,
        EnrollmentPhase.registrationOutcomeUnknown,
        failure,
      );
    }
    await _recordOrphanRemovalWhenPossible(journal);
    journal = journal.copyWith(
      phase: EnrollmentPhase.registrationReady,
      clearDeviceId: true,
      clearMessage: true,
    );
    await store.update(journal);
    return _resume(journal);
  }

  Future<Result<EnrollmentJournal>> acceptSecurityNotice({
    required String userId,
  }) async {
    final current = await _requiredJournal(userId);
    if (current case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final journal = (current as Success<EnrollmentJournal>).value;
    if (journal.phase != EnrollmentPhase.securityNotice) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final complete = journal.copyWith(
      phase: EnrollmentPhase.complete,
      clearBackup: true,
      clearPendingLogRecord: true,
      clearPreviousHash: true,
      clearExpectedSequence: true,
      clearMessage: true,
    );
    final persisted = await store.update(complete);
    return persisted.fold(
      onSuccess: (_) => Result.success(complete),
      onFailure: Result.failure,
    );
  }

  Future<Result<EnrollmentJournal>> _resume(EnrollmentJournal initial) async {
    var journal = initial;
    for (var transition = 0; transition < 16; transition += 1) {
      switch (journal.phase) {
        case EnrollmentPhase.registrationReady:
          final inFlight = journal.copyWith(
            phase: EnrollmentPhase.registrationInFlight,
            clearMessage: true,
          );
          final saved = await store.update(inFlight);
          if (saved case FailureResult(failure: final failure)) {
            return Result.failure(failure);
          }
          final registered = await repository.registerDevice(
            userId: journal.userId,
            public: journal.devicePackage.public,
          );
          if (registered case FailureResult(failure: final failure)) {
            final phase = failure is TransportFailure
                ? EnrollmentPhase.registrationOutcomeUnknown
                : failure is BackendFailure &&
                      failure.code == BackendFailureCode.identityRequired
                ? EnrollmentPhase.blocked
                : EnrollmentPhase.registrationReady;
            return _pause(
              inFlight,
              phase,
              failure,
              overrideMessage:
                  phase == EnrollmentPhase.registrationOutcomeUnknown
                  ? EnrollmentMessage.ambiguousRegistration
                  : null,
            );
          }
          final response =
              (registered as Success<DeviceRegistrationResponse>).value;
          final committed = await store.persistRegistrationResult(
            journal: inFlight,
            response: response,
          );
          if (committed case FailureResult(failure: final failure)) {
            return Result.failure(failure);
          }
          journal = inFlight.copyWith(
            phase: EnrollmentPhase.registeredUnsigned,
            deviceId: response.deviceId,
          );
          continue;
        case EnrollmentPhase.registeredUnsigned:
          if (journal.flow == EnrollmentFlow.firstDevice) {
            final userBytes = _uuidBytes(journal.userId);
            if (userBytes == null) {
              return const Result.failure(
                SecurityFailure(SecurityFailureKind.malformedServerResponse),
              );
            }
            final prepared = await crypto.prepareFirstIdentity(
              userId: userBytes,
            );
            userBytes.fillRange(0, userBytes.length, 0);
            if (prepared case FailureResult(failure: final failure)) {
              return _pause(
                journal,
                EnrollmentPhase.registeredUnsigned,
                failure,
              );
            }
            journal = journal.copyWith(
              phase: EnrollmentPhase.publishingIdentity,
              identityPackage: (prepared as Success<IdentityKeyPackage>).value,
              identityVersion: 1,
              backupVersion: 1,
            );
            final saved = await store.update(journal);
            if (saved case FailureResult(failure: final failure)) {
              return Result.failure(failure);
            }
            continue;
          }
          final backup = await repository.fetchBackup();
          if (backup case FailureResult(failure: final failure)) {
            final phase =
                failure is BackendFailure &&
                    failure.code == BackendFailureCode.notFound
                ? EnrollmentPhase.blocked
                : EnrollmentPhase.registeredUnsigned;
            final message =
                failure is BackendFailure &&
                    failure.code == BackendFailureCode.notFound
                ? EnrollmentMessage.backupMissing
                : _messageFor(failure);
            final paused = journal.copyWith(phase: phase, message: message);
            await store.update(paused);
            return Result.success(paused);
          }
          final restoredBackup = (backup as Success<KeyBackup>).value;
          journal = journal.copyWith(
            phase: EnrollmentPhase.awaitingRecoverySecret,
            backup: restoredBackup.blob,
            backupVersion: restoredBackup.version,
            clearMessage: true,
          );
          final saved = await store.update(journal);
          return saved.fold(
            onSuccess: (_) => Result.success(journal),
            onFailure: Result.failure,
          );
        case EnrollmentPhase.publishingIdentity:
          final identity = journal.identityPackage;
          if (identity == null) {
            return _blockInvalid(journal);
          }
          final published = await repository.publishIdentity(
            identity: _publishedIdentity(identity, journal.identityVersion),
          );
          if (published case FailureResult(failure: final failure)) {
            if (failure is BackendFailure &&
                failure.code == BackendFailureCode.staleVersion) {
              final existing = await repository.fetchIdentity(
                userId: journal.userId,
              );
              if (existing case Success(value: final value)) {
                if (_identityMatches(identity, value) &&
                    value.version == journal.identityVersion) {
                  journal = journal.copyWith(
                    phase: EnrollmentPhase.recoverySecret,
                    clearMessage: true,
                  );
                  await store.update(journal);
                  return Result.success(journal);
                }
              }
              return _pause(journal, EnrollmentPhase.blocked, failure);
            }
            return _pause(journal, EnrollmentPhase.publishingIdentity, failure);
          }
          journal = journal.copyWith(
            phase: EnrollmentPhase.recoverySecret,
            clearMessage: true,
          );
          final saved = await store.update(journal);
          return saved.fold(
            onSuccess: (_) => Result.success(journal),
            onFailure: Result.failure,
          );
        case EnrollmentPhase.finishingSecureSetup:
          final identity = journal.identityPackage;
          final deviceId = journal.deviceId;
          final deviceIdBytes = deviceId == null ? null : _uuidBytes(deviceId);
          if (identity == null || deviceIdBytes == null) {
            return _blockInvalid(journal);
          }
          final signed = await crypto.crossSignDevice(
            device: journal.devicePackage,
            identity: identity,
            deviceId: deviceIdBytes,
            bundleVersion: 1,
          );
          deviceIdBytes.fillRange(0, deviceIdBytes.length, 0);
          if (signed case FailureResult(failure: final failure)) {
            return _pause(
              journal,
              EnrollmentPhase.finishingSecureSetup,
              failure,
            );
          }
          final followUp = await repository.finishPrekeys(
            deviceId: deviceId!,
            crossSignature: (signed as Success<Uint8List>).value,
            bundleVersion: 1,
          );
          if (followUp case FailureResult(failure: final failure)) {
            return _pause(
              journal,
              EnrollmentPhase.finishingSecureSetup,
              failure,
            );
          }
          journal = journal.copyWith(
            phase: journal.flow == EnrollmentFlow.firstDevice
                ? EnrollmentPhase.uploadingBackup
                : EnrollmentPhase.appendingDeviceLog,
            clearMessage: true,
          );
          final saved = await store.update(journal);
          if (saved case FailureResult(failure: final failure)) {
            return Result.failure(failure);
          }
          continue;
        case EnrollmentPhase.uploadingBackup:
          final backup = journal.backup;
          if (backup == null) {
            return _blockInvalid(journal);
          }
          final uploaded = await repository.uploadBackup(
            blob: backup,
            version: journal.backupVersion,
          );
          if (uploaded case FailureResult(failure: final failure)) {
            if (failure is BackendFailure &&
                failure.code == BackendFailureCode.staleVersion) {
              final existing = await repository.fetchBackup();
              if (existing case Success(value: final value)) {
                if (value.version == journal.backupVersion &&
                    _same(value.blob, backup)) {
                  journal = journal.copyWith(
                    phase: EnrollmentPhase.appendingDeviceLog,
                    clearBackup: true,
                    clearMessage: true,
                  );
                  await store.update(journal);
                  continue;
                }
              }
              return _pause(journal, EnrollmentPhase.blocked, failure);
            }
            return _pause(journal, EnrollmentPhase.uploadingBackup, failure);
          }
          journal = journal.copyWith(
            phase: EnrollmentPhase.appendingDeviceLog,
            clearBackup: true,
            clearMessage: true,
          );
          final saved = await store.update(journal);
          if (saved case FailureResult(failure: final failure)) {
            return Result.failure(failure);
          }
          continue;
        case EnrollmentPhase.appendingDeviceLog:
          return _finishDeviceLog(journal);
        case EnrollmentPhase.absent ||
            EnrollmentPhase.preparing ||
            EnrollmentPhase.registrationInFlight:
          return _blockInvalid(journal);
        case EnrollmentPhase.registrationOutcomeUnknown ||
            EnrollmentPhase.recoverySecret ||
            EnrollmentPhase.awaitingRecoverySecret ||
            EnrollmentPhase.restoringIdentity ||
            EnrollmentPhase.securityNotice ||
            EnrollmentPhase.complete ||
            EnrollmentPhase.blocked:
          return Result.success(journal);
      }
    }
    return _blockInvalid(journal);
  }

  Future<Result<EnrollmentJournal>> _finishDeviceLog(
    EnrollmentJournal initial,
  ) async {
    var journal = initial;
    if (journal.pendingLogRecord == null) {
      final prepared = await _prepareLogRecord(journal);
      if (prepared case FailureResult(failure: final failure)) {
        return _pause(
          journal,
          EnrollmentPhase.appendingDeviceLog,
          failure,
          overrideMessage: failure is ValidationFailure
              ? EnrollmentMessage.logConflict
              : null,
        );
      }
      journal = (prepared as Success<EnrollmentJournal>).value;
      final persisted = await store.update(journal);
      if (persisted case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }
    final record = journal.pendingLogRecord!;
    final expected = journal.expectedSequence!;
    final log = await _verifiedLog(journal);
    if (log case FailureResult(failure: final failure)) {
      return _pause(
        journal,
        EnrollmentPhase.appendingDeviceLog,
        failure,
        overrideMessage: EnrollmentMessage.logConflict,
      );
    }
    final verified = (log as Success<_VerifiedLog>).value;
    final existing = verified.records
        .where((entry) => entry.sequence == expected)
        .firstOrNull;
    if (existing != null) {
      if (!_same(existing.blob, record)) {
        return _pause(
          journal,
          EnrollmentPhase.blocked,
          const ValidationFailure(ValidationFailureKind.conflict),
          overrideMessage: EnrollmentMessage.logConflict,
        );
      }
      return _toSecurityNotice(journal);
    }
    if (verified.headSequence != expected - 1) {
      return _pause(
        journal,
        EnrollmentPhase.blocked,
        const ValidationFailure(ValidationFailureKind.conflict),
        overrideMessage: EnrollmentMessage.logConflict,
      );
    }
    final appended = await repository.appendDeviceLog(record: record);
    if (appended case FailureResult(failure: final failure)) {
      return _pause(journal, EnrollmentPhase.appendingDeviceLog, failure);
    }
    final result = (appended as Success<DeviceLogAppendResult>).value;
    if (result.firstSequence != expected || result.lastSequence != expected) {
      return _pause(
        journal,
        EnrollmentPhase.blocked,
        const ValidationFailure(ValidationFailureKind.conflict),
        overrideMessage: EnrollmentMessage.logConflict,
      );
    }
    return _toSecurityNotice(journal);
  }

  Future<Result<EnrollmentJournal>> _prepareLogRecord(
    EnrollmentJournal journal, {
    bool requirePendingDevice = true,
  }) async {
    final identity = journal.identityPackage;
    if (identity == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final verifiedResult = await _verifiedLog(journal);
    if (verifiedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final verified = (verifiedResult as Success<_VerifiedLog>).value;
    final devicesResult = await repository.fetchPublicDevices(
      userId: journal.userId,
    );
    if (devicesResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final devices = (devicesResult as Success<PublicDeviceList>).value;
    if (devices.logHeadSequence != verified.nullableHeadSequence) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    if (requirePendingDevice) {
      final current = devices.devices
          .where((device) => device.deviceId == journal.deviceId)
          .firstOrNull;
      if (current == null ||
          current.isUnsigned ||
          !_same(current.ikPub, journal.devicePackage.public.ikPub)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
    }
    final canonicalLiveSet = _canonicalLiveSet(devices.devices);
    if (canonicalLiveSet == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final userBytes = _uuidBytes(journal.userId);
    if (userBytes == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final created = await crypto.createDeviceLogRecord(
      identity: identity,
      userId: userBytes,
      sequence: verified.headSequence + 1,
      previousHash: verified.headHash,
      canonicalLiveSet: canonicalLiveSet,
      identityVersion: journal.identityVersion,
      coarseUnixDay: clock.now().toUtc().millisecondsSinceEpoch ~/ 86400000,
    );
    userBytes.fillRange(0, userBytes.length, 0);
    if (created case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      journal.copyWith(
        expectedSequence: verified.headSequence + 1,
        previousHash: verified.headHash,
        pendingLogRecord: (created as Success<Uint8List>).value,
        clearMessage: true,
      ),
    );
  }

  Future<Result<_VerifiedLog>> _verifiedLog(EnrollmentJournal journal) async {
    final identity = journal.identityPackage;
    final userBytes = _uuidBytes(journal.userId);
    if (identity == null || userBytes == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final all = <DeviceLogRecord>[];
    int? after;
    int? fixedHead;
    var expectedSequence = 0;
    var previousHash = Uint8List(32);
    for (var pageIndex = 0; pageIndex < 50; pageIndex += 1) {
      final pageResult = await repository.fetchDeviceLog(
        userId: journal.userId,
        after: after,
      );
      if (pageResult case FailureResult(failure: final failure)) {
        userBytes.fillRange(0, userBytes.length, 0);
        return Result.failure(failure);
      }
      final page = (pageResult as Success<DeviceLogPage>).value;
      fixedHead ??= page.headSequence;
      if (fixedHead != page.headSequence ||
          (page.hasMore && page.records.isEmpty)) {
        userBytes.fillRange(0, userBytes.length, 0);
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      for (final record in page.records) {
        if (record.sequence != expectedSequence || all.length >= 10000) {
          userBytes.fillRange(0, userBytes.length, 0);
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
          userBytes.fillRange(0, userBytes.length, 0);
          return Result.failure(failure);
        }
        final value = (inspected as Success<DeviceLogInspection>).value;
        if (value.sequence != record.sequence ||
            !_same(value.previousHash, previousHash)) {
          userBytes.fillRange(0, userBytes.length, 0);
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
        }
        previousHash = value.recordHash;
        all.add(record);
        expectedSequence += 1;
        after = record.sequence;
      }
      if (!page.hasMore) {
        final expectedHead = all.isEmpty ? null : all.last.sequence;
        userBytes.fillRange(0, userBytes.length, 0);
        if (page.headSequence != expectedHead) {
          return const Result.failure(
            ValidationFailure(ValidationFailureKind.conflict),
          );
        }
        return Result.success(
          _VerifiedLog(
            records: all,
            headSequence: expectedHead ?? -1,
            headHash: all.isEmpty ? Uint8List(0) : previousHash,
          ),
        );
      }
    }
    userBytes.fillRange(0, userBytes.length, 0);
    return const Result.failure(
      CryptoCoreFailure(CryptoCoreFailureCode.resourceExhausted),
    );
  }

  Future<Result<EnrollmentJournal>> _toSecurityNotice(
    EnrollmentJournal journal,
  ) async {
    final ready = journal.copyWith(
      phase: EnrollmentPhase.securityNotice,
      clearPendingLogRecord: true,
      clearExpectedSequence: true,
      clearPreviousHash: true,
      clearMessage: true,
    );
    final persisted = await store.update(ready);
    return persisted.fold(
      onSuccess: (_) => Result.success(ready),
      onFailure: Result.failure,
    );
  }

  Future<void> _recordOrphanRemovalWhenPossible(
    EnrollmentJournal journal,
  ) async {
    final completed = await store.readCompletedIdentity();
    if (completed is! Success<IdentityKeyPackage?>) {
      return;
    }
    final identity = completed.value;
    if (identity == null) {
      return;
    }
    final temporary = journal.copyWith(
      identityPackage: identity,
      identityVersion: 1,
    );
    final prepared = await _prepareLogRecord(
      temporary,
      requirePendingDevice: false,
    );
    if (prepared is! Success<EnrollmentJournal>) {
      return;
    }
    final record = prepared.value.pendingLogRecord;
    final expected = prepared.value.expectedSequence;
    if (record == null || expected == null) {
      return;
    }
    final appended = await repository.appendDeviceLog(record: record);
    if (appended case Success(value: final value)) {
      if (value.firstSequence != expected || value.lastSequence != expected) {
        return;
      }
    }
  }

  Future<Result<EnrollmentJournal>> _requiredJournal(String userId) async {
    final result = await store.read(userId: userId);
    return result.fold(
      onSuccess: (journal) => journal == null
          ? const Result.failure(
              SecurityFailure(SecurityFailureKind.policyBlocked),
            )
          : Result.success(journal),
      onFailure: Result.failure,
    );
  }

  Future<Result<EnrollmentJournal>> _pause(
    EnrollmentJournal journal,
    EnrollmentPhase phase,
    Failure failure, {
    EnrollmentMessage? overrideMessage,
  }) async {
    final paused = journal.copyWith(
      phase: phase,
      message: overrideMessage ?? _messageFor(failure),
    );
    final persisted = await store.update(paused);
    return persisted.fold(
      onSuccess: (_) => Result.success(paused),
      onFailure: Result.failure,
    );
  }

  Future<Result<EnrollmentJournal>> _blockInvalid(EnrollmentJournal journal) =>
      _pause(
        journal,
        EnrollmentPhase.blocked,
        const SecurityFailure(SecurityFailureKind.policyBlocked),
        overrideMessage: EnrollmentMessage.invalidVector,
      );

  EnrollmentMessage _messageFor(Failure failure) => switch (failure) {
    TransportFailure() => EnrollmentMessage.offline,
    BackendFailure(code: BackendFailureCode.throttled) =>
      EnrollmentMessage.rateLimited,
    BackendFailure(code: BackendFailureCode.deviceLimit) =>
      EnrollmentMessage.deviceLimit,
    BackendFailure(code: BackendFailureCode.identityRequired) =>
      EnrollmentMessage.identityRequired,
    BackendFailure(code: BackendFailureCode.staleVersion) =>
      EnrollmentMessage.staleVersion,
    SecurityFailure(kind: SecurityFailureKind.malformedServerResponse) =>
      EnrollmentMessage.malformedResponse,
    SecurityFailure() => EnrollmentMessage.invalidVector,
    StorageFailure() => EnrollmentMessage.storageUnavailable,
    UnsupportedProtocolFailure() => EnrollmentMessage.unsupportedProtocol,
    CryptoCoreFailure(code: CryptoCoreFailureCode.unsupportedVersion) =>
      EnrollmentMessage.unsupportedProtocol,
    CryptoCoreFailure() => EnrollmentMessage.invalidVector,
    _ => EnrollmentMessage.generic,
  };

  PublishedIdentity _publishedIdentity(
    IdentityKeyPackage identity,
    int version,
  ) => PublishedIdentity(
    masterPub: identity.masterPub,
    selfSigningPub: identity.selfSigningPub,
    userSigningPub: identity.userSigningPub,
    masterSig: identity.masterSig,
    version: version,
  );

  bool _identityMatches(IdentityKeyPackage local, PublishedIdentity server) =>
      _same(local.masterPub, server.masterPub) &&
      _same(local.selfSigningPub, server.selfSigningPub) &&
      _same(local.userSigningPub, server.userSigningPub) &&
      _same(local.masterSig, server.masterSig);

  Uint8List? _canonicalLiveSet(List<PublicDevice> devices) {
    final sorted = [...devices]
      ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode('chat:v1:device-set'))
      ..add(_u32(sorted.length));
    for (final device in sorted) {
      final id = _uuidBytes(device.deviceId);
      if (id == null ||
          device.ikPub.length != 64 ||
          (device.crossSignature != null &&
              device.crossSignature!.length != 64)) {
        return null;
      }
      builder
        ..add(id)
        ..add(_frame(device.ikPub))
        ..add(_u32(device.registrationId))
        ..add(_frame(device.crossSignature ?? Uint8List(0)))
        ..add(_u32(device.bundleVersion ?? 0));
    }
    return builder.takeBytes();
  }

  Uint8List _frame(Uint8List value) =>
      Uint8List.fromList([..._u32(value.length), ...value]);

  Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  Uint8List? _uuidBytes(String value) {
    final compact = value.replaceAll('-', '');
    if (compact.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
      return null;
    }
    final output = Uint8List(16);
    for (var index = 0; index < 16; index += 1) {
      output[index] = int.parse(
        compact.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return output;
  }

  bool _same(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index += 1) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  void _zeroIdentity(IdentityKeyPackage identity) {
    identity.opaqueBytes.fillRange(0, identity.opaqueBytes.length, 0);
    identity.recoverySecretBytes.fillRange(
      0,
      identity.recoverySecretBytes.length,
      0,
    );
    identity.backup.fillRange(0, identity.backup.length, 0);
  }
}

final class _VerifiedLog {
  const _VerifiedLog({
    required this.records,
    required this.headSequence,
    required this.headHash,
  });

  final List<DeviceLogRecord> records;
  final int headSequence;
  final Uint8List headHash;

  int? get nullableHeadSequence => headSequence < 0 ? null : headSequence;
}
