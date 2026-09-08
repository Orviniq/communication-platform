import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';

enum EnrollmentFlow { firstDevice, laterDevice }

enum EnrollmentPhase {
  absent,
  preparing,
  registrationReady,
  registrationInFlight,
  registrationOutcomeUnknown,
  registeredUnsigned,
  publishingIdentity,
  recoverySecret,
  awaitingRecoverySecret,
  restoringIdentity,
  finishingSecureSetup,
  uploadingBackup,
  appendingDeviceLog,
  securityNotice,
  complete,
  blocked,
}

enum EnrollmentMessage {
  offline,
  rateLimited,
  deviceLimit,
  identityRequired,
  staleVersion,
  invalidVector,
  wrongRecoverySecret,
  backupMissing,
  ambiguousRegistration,
  logConflict,
  malformedResponse,
  storageUnavailable,
  unsupportedProtocol,
  generic,
}

final class EnrollmentJournal {
  const EnrollmentJournal({
    required this.userId,
    required this.flow,
    required this.phase,
    required this.fingerprint,
    required this.devicePackage,
    this.deviceId,
    this.identityPackage,
    this.backup,
    this.backupVersion = 1,
    this.identityVersion = 1,
    this.expectedSequence,
    this.previousHash,
    this.pendingLogRecord,
    this.message,
    this.recoverySecretDisplayed = false,
    this.recoveryConfirmed = false,
  });

  final String userId;
  final EnrollmentFlow flow;
  final EnrollmentPhase phase;
  final Uint8List fingerprint;
  final DeviceKeyPackage devicePackage;
  final String? deviceId;
  final IdentityKeyPackage? identityPackage;
  final Uint8List? backup;
  final int backupVersion;
  final int identityVersion;
  final int? expectedSequence;
  final Uint8List? previousHash;
  final Uint8List? pendingLogRecord;
  final EnrollmentMessage? message;
  final bool recoverySecretDisplayed;
  final bool recoveryConfirmed;

  bool get isMessagingWithheld => phase != EnrollmentPhase.complete;
  bool get requiresUserRecoverySecret =>
      flow == EnrollmentFlow.firstDevice &&
          phase == EnrollmentPhase.recoverySecret ||
      flow == EnrollmentFlow.laterDevice &&
          phase == EnrollmentPhase.awaitingRecoverySecret;

  EnrollmentJournal copyWith({
    EnrollmentFlow? flow,
    EnrollmentPhase? phase,
    String? deviceId,
    bool clearDeviceId = false,
    IdentityKeyPackage? identityPackage,
    bool clearIdentityPackage = false,
    Uint8List? backup,
    bool clearBackup = false,
    int? backupVersion,
    int? identityVersion,
    int? expectedSequence,
    bool clearExpectedSequence = false,
    Uint8List? previousHash,
    bool clearPreviousHash = false,
    Uint8List? pendingLogRecord,
    bool clearPendingLogRecord = false,
    EnrollmentMessage? message,
    bool clearMessage = false,
    bool? recoverySecretDisplayed,
    bool? recoveryConfirmed,
  }) => EnrollmentJournal(
    userId: userId,
    flow: flow ?? this.flow,
    phase: phase ?? this.phase,
    fingerprint: Uint8List.fromList(fingerprint),
    devicePackage: devicePackage,
    deviceId: clearDeviceId ? null : deviceId ?? this.deviceId,
    identityPackage: clearIdentityPackage
        ? null
        : identityPackage ?? this.identityPackage,
    backup: clearBackup ? null : backup ?? this.backup,
    backupVersion: backupVersion ?? this.backupVersion,
    identityVersion: identityVersion ?? this.identityVersion,
    expectedSequence: clearExpectedSequence
        ? null
        : expectedSequence ?? this.expectedSequence,
    previousHash: clearPreviousHash
        ? null
        : previousHash == null
        ? this.previousHash == null
              ? null
              : Uint8List.fromList(this.previousHash!)
        : Uint8List.fromList(previousHash),
    pendingLogRecord: clearPendingLogRecord
        ? null
        : pendingLogRecord == null
        ? this.pendingLogRecord == null
              ? null
              : Uint8List.fromList(this.pendingLogRecord!)
        : Uint8List.fromList(pendingLogRecord),
    message: clearMessage ? null : message ?? this.message,
    recoverySecretDisplayed:
        recoverySecretDisplayed ?? this.recoverySecretDisplayed,
    recoveryConfirmed: recoveryConfirmed ?? this.recoveryConfirmed,
  );
}

final class DeviceRegistrationResponse {
  const DeviceRegistrationResponse({
    required this.deviceId,
    required this.userId,
    required this.accessToken,
    required this.accessExpiresAt,
  });

  final String deviceId;
  final String userId;
  final String accessToken;
  final DateTime accessExpiresAt;
}

final class PublishedIdentity {
  const PublishedIdentity({
    required this.masterPub,
    required this.selfSigningPub,
    required this.userSigningPub,
    required this.masterSig,
    required this.version,
  });

  final Uint8List masterPub;
  final Uint8List selfSigningPub;
  final Uint8List userSigningPub;
  final Uint8List masterSig;
  final int version;
}

final class PublicDevice {
  const PublicDevice({
    required this.deviceId,
    required this.ikPub,
    required this.registrationId,
    required this.crossSignature,
    required this.bundleVersion,
  });

  final String deviceId;
  final Uint8List ikPub;
  final int registrationId;
  final Uint8List? crossSignature;
  final int? bundleVersion;

  bool get isUnsigned => crossSignature == null || bundleVersion == null;
}

final class PublicDeviceList {
  const PublicDeviceList({
    required this.devices,
    required this.logHeadSequence,
    required this.etag,
  });

  final List<PublicDevice> devices;
  final int? logHeadSequence;
  final String? etag;
}

final class DeviceLogPage {
  const DeviceLogPage({
    required this.records,
    required this.hasMore,
    required this.headSequence,
  });

  final List<DeviceLogRecord> records;
  final bool hasMore;
  final int? headSequence;
}

final class DeviceLogRecord {
  const DeviceLogRecord({required this.sequence, required this.blob});

  final int sequence;
  final Uint8List blob;
}

final class KeyBackup {
  const KeyBackup({required this.blob, required this.version});

  final Uint8List blob;
  final int version;
}

final class DeviceLogAppendResult {
  const DeviceLogAppendResult({
    required this.firstSequence,
    required this.lastSequence,
  });

  final int firstSequence;
  final int lastSequence;
}
