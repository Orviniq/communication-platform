import 'dart:typed_data';

enum LinkedDeviceLabelState { available, notSet, unreadable }

final class LinkedDevice {
  LinkedDevice({
    required this.deviceId,
    required this.label,
    required this.labelState,
    required this.createdDate,
    required this.thisDevice,
    Uint8List? encryptedLabel,
  }) : encryptedLabel = encryptedLabel == null
           ? null
           : Uint8List.fromList(encryptedLabel);

  final String deviceId;
  final String? label;
  final LinkedDeviceLabelState labelState;
  final DateTime createdDate;
  final bool thisDevice;
  final Uint8List? encryptedLabel;
}

sealed class OwnDeviceRefresh {
  const OwnDeviceRefresh();
}

final class OwnDevicesNotModified extends OwnDeviceRefresh {
  const OwnDevicesNotModified();
}

final class OwnDevicesUpdated extends OwnDeviceRefresh {
  const OwnDevicesUpdated({
    required this.devices,
    required this.etag,
    required this.logHeadSequence,
  });

  final List<LinkedDevice> devices;
  final String etag;
  final int? logHeadSequence;
}

enum DeviceLogMutationKind { add, remove, rotate, identity }

enum DeviceLogMutationState {
  prepared,
  logAppending,
  logConfirmed,
  serverMutationConfirmed,
}

final class PendingDeviceLogMutation {
  PendingDeviceLogMutation({
    required this.operationId,
    required this.userId,
    required this.kind,
    required this.targetDeviceId,
    required this.expectedSequence,
    required Uint8List previousHeadHash,
    required Uint8List exactRecord,
    required this.state,
  }) : previousHeadHash = Uint8List.fromList(previousHeadHash),
       exactRecord = Uint8List.fromList(exactRecord);

  final String operationId;
  final String userId;
  final DeviceLogMutationKind kind;
  final String? targetDeviceId;
  final int expectedSequence;
  final Uint8List previousHeadHash;
  final Uint8List exactRecord;
  final DeviceLogMutationState state;

  PendingDeviceLogMutation copyWith({DeviceLogMutationState? state}) =>
      PendingDeviceLogMutation(
        operationId: operationId,
        userId: userId,
        kind: kind,
        targetDeviceId: targetDeviceId,
        expectedSequence: expectedSequence,
        previousHeadHash: previousHeadHash,
        exactRecord: exactRecord,
        state: state ?? this.state,
      );
}

enum GlobalSecurityState { normal, deviceLogFork, pendingDeviceChange }

enum DeviceLogEvidenceKind {
  rollback,
  nonExtendingHead,
  gossipMismatch,
  invalidRecord,
  sequenceEquivocation,
  liveSetMismatch,
}

final class AuthenticatedDeviceLogRecord {
  AuthenticatedDeviceLogRecord({
    required this.sequence,
    required Uint8List record,
    required Uint8List hash,
  }) : record = Uint8List.fromList(record),
       hash = Uint8List.fromList(hash);

  final int sequence;
  final Uint8List record;
  final Uint8List hash;
}
