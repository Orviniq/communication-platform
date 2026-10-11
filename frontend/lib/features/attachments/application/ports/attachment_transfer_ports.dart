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

/// Where the temporary files of a transfer are made.
///
/// A temporary file's name says nothing about its attachment, so neither
/// method takes one: a decrypted file gets its display name only when the
/// attachment cache adopts it.
abstract interface class AttachmentStoragePort {
  Future<File> createEncryptedTemp();

  Future<File> createDecryptedTemp();

  Future<void> delete(File file);
}

abstract interface class AttachmentTransportPort {
  /// Uploads [encryptedFile], exactly [bucketSize] bytes.
  ///
  /// [onProgress] is told the bytes of the request body sent so far and the
  /// body's whole length, which is a little more than [bucketSize]: the body is
  /// multipart.
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
    void Function(int sent, int total)? onProgress,
  });

  /// Fetches the ciphertext of [capabilityId] and answers the file that holds
  /// it: exactly [expectedBucketSize] bytes, which the caller then owns and
  /// deletes.
  ///
  /// A download of one of the two largest buckets that stops part-way is kept,
  /// and the next call for the same capability takes it up from the byte it
  /// stopped at rather than from zero (ADR-083). The caller does nothing
  /// different to get that: it asks again.
  Future<Result<File>> download({
    required String capabilityId,
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
