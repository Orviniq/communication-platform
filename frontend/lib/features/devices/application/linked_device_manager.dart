import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/device_control_model.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/own_device_log_coordinator.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/application/ports/linked_device_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';

/// Application service for the own-account Linked Devices screen.
///
/// Device-list rows (labels, dates, `this_device`) are display data only. A
/// refresh is committed locally only after the public device set, identity and
/// complete signed log have been checked together.
final class LinkedDeviceManager {
  const LinkedDeviceManager({
    required this.remote,
    required this.local,
    required this.enrollment,
    required this.controlCrypto,
    required this.enrollmentCrypto,
    required this.identityCrypto,
    required this.cleanup,
    required this.userId,
  });

  final LinkedDeviceRemotePort remote;
  final LinkedDeviceLocalPort local;
  final DeviceEnrollmentRepository enrollment;
  final DeviceControlCryptoPort controlCrypto;
  final EnrollmentCryptoPort enrollmentCrypto;
  final IdentityCryptoPort identityCrypto;
  final SelfRevocationCleanupPort cleanup;
  final String userId;

  Future<Result<List<LinkedDevice>>> refresh() async {
    final resumed = await OwnDeviceLogCoordinator(
      repository: enrollment,
      local: local,
      crypto: enrollmentCrypto,
      identityCrypto: identityCrypto,
      userId: userId,
    ).resumePendingMutation();
    if (resumed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final finished = await _finishPendingRemovalIfNeeded();
    if (finished case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final etagResult = await local.readOwnDevicesEtag(userId);
    if (etagResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final refreshed = await remote.fetchOwnDevices(
      etag: (etagResult as Success<String?>).value,
    );
    if (refreshed case FailureResult(failure: final failure)) {
      final revoked = await _cleanupIfCurrentDeviceWasRemotelyRevoked();
      if (revoked case Success(value: true)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      return Result.failure(failure);
    }
    final value = (refreshed as Success<OwnDeviceRefresh>).value;
    if (value is OwnDevicesNotModified) {
      return local.readOwnDevices(userId);
    }
    final updated = value as OwnDevicesUpdated;
    final authenticated = await _authenticateOwnSet(updated.devices);
    if (authenticated case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localIdentity = (await local.readLocalIdentity()).fold(
      onSuccess: (value) => value,
      onFailure: (_) => null,
    );
    if (localIdentity == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    if (!updated.devices.any((device) => device.deviceId == localIdentity.$2)) {
      await cleanup.cleanupAfterSelfRevocation();
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final identity = localIdentity.$3;
    final opened = <LinkedDevice>[];
    for (final device in updated.devices) {
      final bytes = _uuidBytes(device.deviceId);
      if (bytes == null || device.encryptedLabel == null) {
        opened.add(device);
        continue;
      }
      final label = await controlCrypto.openDeviceLabel(
        identity: identity,
        userId: _uuidBytes(userId)!,
        deviceId: bytes,
        ciphertext: DeviceLabelCiphertext(device.encryptedLabel!),
      );
      if (label case Success(value: final text)) {
        opened.add(
          LinkedDevice(
            deviceId: device.deviceId,
            label: text,
            labelState: LinkedDeviceLabelState.available,
            createdDate: device.createdDate,
            thisDevice: device.thisDevice,
            encryptedLabel: device.encryptedLabel,
          ),
        );
      } else {
        opened.add(device);
      }
    }
    final saved = await local.replaceOwnDevices(
      userId: userId,
      etag: updated.etag,
      devices: opened,
    );
    if (saved case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final missingSources = await local.markMissingHistorySources(
      opened.map((device) => device.deviceId).toSet(),
    );
    if (missingSources case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(opened);
  }

  Future<Result<void>> relabel({
    required String deviceId,
    required String label,
  }) async {
    final state = await local.readGlobalSecurityState();
    if (state case Success(
      value: final posture,
    ) when posture != GlobalSecurityState.normal) {
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
    final user = _uuidBytes(userId);
    final device = _uuidBytes(deviceId);
    if (user == null || device == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final sealed = await controlCrypto.sealDeviceLabel(
      identity: identity,
      userId: user,
      deviceId: device,
      label: label,
    );
    if (sealed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final ciphertext = (sealed as Success<DeviceLabelCiphertext>).value.bytes;
    final updated = await remote.relabelDevice(
      deviceId: deviceId,
      encryptedLabel: ciphertext,
    );
    if (updated case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return local.updateEncryptedLabel(
      deviceId: deviceId,
      label: label,
      encryptedLabel: ciphertext,
    );
  }

  Future<Result<void>> revoke({required String deviceId}) async {
    final posture = await local.readGlobalSecurityState();
    if (posture case Success(
      value: final state,
    ) when state != GlobalSecurityState.normal) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final publicResult = await enrollment.fetchPublicDevices(userId: userId);
    if (publicResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final list = (publicResult as Success<PublicDeviceList>).value;
    final target = list.devices
        .where((d) => d.deviceId == deviceId)
        .toList(growable: false);
    if (target.length != 1 || target.single.isUnsigned) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final remaining = list.devices
        .where((d) => d.deviceId != deviceId)
        .toList(growable: false);
    final log = OwnDeviceLogCoordinator(
      repository: enrollment,
      local: local,
      crypto: enrollmentCrypto,
      identityCrypto: identityCrypto,
      userId: userId,
    );
    final appended = await log.appendLiveSetMutation(
      kind: DeviceLogMutationKind.remove,
      targetDeviceId: deviceId,
      liveDevices: remaining,
      identityVersion: 1,
    );
    if (appended case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final revoked = await remote.revokeDevice(deviceId: deviceId);
    if (revoked case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final pending = await local.readPendingMutation();
    if (pending case Success(value: final mutation?)) {
      await local.clearPendingMutation(mutation.operationId);
      await local.setGlobalSecurityState(GlobalSecurityState.normal);
    }
    if (deviceId ==
        (await local.readLocalIdentity()).fold(
          onSuccess: (value) => value.$2,
          onFailure: (_) => '',
        )) {
      await cleanup.cleanupAfterSelfRevocation();
    }
    return const Result.success(null);
  }

  Future<Result<void>> _finishPendingRemovalIfNeeded() async {
    final pendingResult = await local.readPendingMutation();
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final pending = (pendingResult as Success<PendingDeviceLogMutation?>).value;
    if (pending == null ||
        pending.kind != DeviceLogMutationKind.remove ||
        pending.state != DeviceLogMutationState.logConfirmed ||
        pending.targetDeviceId == null) {
      return const Result.success(null);
    }
    final target = pending.targetDeviceId!;
    final currentDeviceId = (await local.readLocalIdentity()).fold(
      onSuccess: (value) => value.$2,
      onFailure: (_) => '',
    );
    final revoked = await remote.revokeDevice(deviceId: target);
    if (revoked case FailureResult()) {
      final refreshed = await remote.fetchOwnDevices();
      if (refreshed is! Success<OwnDeviceRefresh> ||
          refreshed.value is! OwnDevicesUpdated) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      final devices = (refreshed.value as OwnDevicesUpdated).devices;
      if (devices.any((device) => device.deviceId == target)) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      final authenticated = await _authenticateOwnSet(devices);
      if (authenticated case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }
    await local.clearPendingMutation(pending.operationId);
    await local.setGlobalSecurityState(GlobalSecurityState.normal);
    if (target == currentDeviceId) {
      await cleanup.cleanupAfterSelfRevocation();
    }
    return const Result.success(null);
  }

  Future<Result<void>> _authenticateOwnSet(List<LinkedDevice> rows) async {
    final publicResult = await enrollment.fetchPublicDevices(userId: userId);
    if (publicResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final public = (publicResult as Success<PublicDeviceList>).value;
    final expected = public.devices.map((d) => d.deviceId).toSet();
    final actual = rows.map((d) => d.deviceId).toSet();
    if (expected.length != actual.length || !expected.containsAll(actual)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    final identity = await local.readLocalIdentity();
    if (identity case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final tuple =
        (identity as Success<(String, String, IdentityKeyPackage)>).value;
    if (tuple.$1 != userId) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return _verifyPublicList(public, tuple);
  }

  Future<Result<void>> _verifyPublicList(
    PublicDeviceList public,
    (String, String, IdentityKeyPackage) tuple,
  ) async {
    final chain = await OwnDeviceLogCoordinator(
      repository: enrollment,
      local: local,
      crypto: enrollmentCrypto,
      identityCrypto: identityCrypto,
      userId: userId,
    ).verifyCurrentChain();
    if (chain case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final chainHead = (chain as Success<AuthenticatedDeviceLogRecord?>).value;
    if (public.logHeadSequence != chainHead?.sequence) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    if (chainHead == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final verifiedLiveSet = await identityCrypto.inspectPeerDeviceLog(
      userId: _uuidBytes(userId)!,
      selfSigningPublic: tuple.$3.selfSigningPub,
      liveDevices: public.devices
          .map(
            (device) => PeerPublicDevice(
              deviceId: device.deviceId,
              identityPublic: device.ikPub,
              registrationId: device.registrationId,
              bundleVersion: device.bundleVersion,
              crossSignature: device.crossSignature,
            ),
          )
          .toList(growable: false),
      requireCurrentLiveSet: true,
      record: chainHead.record,
    );
    if (verifiedLiveSet case FailureResult(failure: final failure)) {
      await local.setGlobalSecurityState(
        GlobalSecurityState.deviceLogFork,
        evidence: DeviceLogEvidenceKind.liveSetMismatch,
      );
      return Result.failure(failure);
    }
    return const Result.success(null);
  }

  Future<Result<bool>> _cleanupIfCurrentDeviceWasRemotelyRevoked() async {
    final identity = await local.readLocalIdentity();
    if (identity case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final tuple =
        (identity as Success<(String, String, IdentityKeyPackage)>).value;
    final publicResult = await enrollment.fetchPublicDevices(userId: userId);
    if (publicResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final public = (publicResult as Success<PublicDeviceList>).value;
    if (public.devices.any((device) => device.deviceId == tuple.$2)) {
      return const Result.success(false);
    }
    final authenticated = await _verifyPublicList(public, tuple);
    if (authenticated case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    await cleanup.cleanupAfterSelfRevocation();
    return const Result.success(true);
  }

  Uint8List? _uuidBytes(String value) {
    final compact = value.replaceAll('-', '');
    if (compact.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
      return null;
    }
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
