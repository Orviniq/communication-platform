import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';

final class AttachmentUploadResponse {
  const AttachmentUploadResponse({
    required this.capabilityId,
    required this.bucketSize,
  });

  final String capabilityId;
  final int bucketSize;

  @override
  String toString() => 'AttachmentUploadResponse(<redacted>)';
}

abstract interface class AttachmentStoragePort {
  Future<File> createEncryptedTemp();

  Future<File> createDecryptedTemp({required String safeName});

  Future<void> delete(File file);
}

abstract interface class AttachmentTransportPort {
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
  });

  Future<Result<void>> download({
    required String capabilityId,
    required IOSink destination,
    required int expectedBucketSize,
    CancellationSignal? cancellation,
    void Function(int bytes)? onProgress,
  });
}

/// Where the day's uploaded total is kept between starts.
///
/// It is durable because the server's counter is, and because a process that
/// restarted mid-day would otherwise believe the whole allowance was free
/// again. [read] never fails: an installation that has stored nothing, and one
/// whose row this build cannot parse, both read as a day that has spent
/// nothing — the failure direction that lets the server refuse an upload is
/// always safer than the one that refuses on this client's guess.
abstract interface class AttachmentAllowancePort implements RepositoryPort {
  Future<AttachmentDailyAllowance> read(DateTime now);

  /// Adds [bytes] to the day containing [now].
  ///
  /// Failure is not reported because there is nothing useful a caller could do
  /// with it. The bytes are spent either way: the server has them, and the
  /// worst a lost write causes is this client believing it has more room than
  /// it does, which the server corrects with the `413` it would have sent
  /// anyway.
  Future<void> record({required int bytes, required DateTime now});
}
