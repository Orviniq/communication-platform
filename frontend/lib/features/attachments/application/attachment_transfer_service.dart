import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';

final class AttachmentTransferService {
  AttachmentTransferService({
    required this.crypto,
    required this.transport,
    required this.storage,
  });

  final AttachmentCryptoService crypto;
  final AttachmentTransportPort transport;
  final AttachmentStoragePort storage;

  Future<Result<AttachmentDescriptor>> createAndUpload({
    required AttachmentSource source,
    String? caption,
    CancellationSignal? cancellation,
    void Function(AttachmentProgress progress)? onProgress,
  }) async {
    final encrypted = await storage.createEncryptedTemp();
    try {
      final encryptedResult = await crypto.encryptToFile(
        source: source,
        destination: encrypted,
        caption: caption,
        cancellation: cancellation,
        onProgress: onProgress,
      );
      if (encryptedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      if (encryptedResult is! Success<AttachmentDescriptor>) {
        return Result.failure(
          (encryptedResult as FailureResult<AttachmentDescriptor>).failure,
        );
      }
      final descriptor = encryptedResult.value;
      onProgress?.call(
        AttachmentProgress(
          state: AttachmentTransferState.uploading,
          completedBytes: 0,
          totalBytes: descriptor.bucketSize,
        ),
      );
      final uploaded = await transport.upload(
        encryptedFile: encrypted,
        bucketSize: descriptor.bucketSize,
        cancellation: cancellation,
        // The request body is the bucket in a multipart wrapping, so its
        // share sent is the bucket's share sent.
        onProgress: onProgress == null
            ? null
            : (sent, total) => onProgress(
                AttachmentProgress(
                  state: AttachmentTransferState.uploading,
                  completedBytes: total <= 0
                      ? 0
                      : (descriptor.bucketSize * (sent / total)).floor(),
                  totalBytes: descriptor.bucketSize,
                ),
              ),
      );
      if (uploaded case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final response = (uploaded as Success<AttachmentUploadResponse>).value;
      onProgress?.call(
        AttachmentProgress(
          state: AttachmentTransferState.ready,
          completedBytes: descriptor.bucketSize,
          totalBytes: descriptor.bucketSize,
        ),
      );
      return Result.success(descriptor.withCapability(response.capabilityId));
    } finally {
      await storage.delete(encrypted);
    }
  }

  /// Downloads the ciphertext of [descriptor], then verifies and decrypts it
  /// to a temporary file, reporting `downloading` and then `verifying`.
  ///
  /// A failure says which step it came from, because the two mean different
  /// things: a download that failed fetched nothing anyone checked, and may
  /// work the next time, while bytes that arrived whole and did not verify
  /// are not the file the descriptor describes. The transport and the crypto
  /// service can both answer `malformedServerResponse`, so the failure alone
  /// cannot say which.
  ///
  /// The caller owns the verified file, and hands it to the attachment cache
  /// or deletes it. A failure leaves no decrypted file.
  Future<AttachmentDownloadResult> downloadAndDecrypt({
    required AttachmentDescriptor descriptor,
    CancellationSignal? cancellation,
    void Function(AttachmentProgress progress)? onProgress,
  }) async {
    final downloaded = await transport.download(
      capabilityId: descriptor.capabilityId,
      expectedBucketSize: descriptor.bucketSize,
      cancellation: cancellation,
      onProgress: (bytes) => onProgress?.call(
        AttachmentProgress(
          state: AttachmentTransferState.downloading,
          completedBytes: bytes,
          totalBytes: descriptor.bucketSize,
        ),
      ),
    );
    if (downloaded case FailureResult(failure: final failure)) {
      // Whatever the attempt fetched stays with the transport, which takes it
      // up again on the next call when it can (ADR-083).
      return AttachmentDownloadFailed(
        failure,
        stage: AttachmentDownloadStage.download,
      );
    }
    final encrypted = (downloaded as Success<File>).value;
    File? decrypted;
    try {
      decrypted = await storage.createDecryptedTemp();
      final decryptedResult = await crypto.decryptStreamToFile(
        descriptor: descriptor,
        ciphertext: encrypted.openRead(),
        destination: decrypted,
        cancellation: cancellation,
        onProgress: onProgress,
      );
      if (decryptedResult case FailureResult(failure: final failure)) {
        // The crypto service deleted what it wrote.
        return AttachmentDownloadFailed(
          failure,
          stage: AttachmentDownloadStage.verification,
        );
      }
      return AttachmentDownloaded(decrypted);
    } on FileSystemException {
      // The disk, not the bytes: no verdict on the file was reached.
      if (decrypted != null) {
        await storage.delete(decrypted);
      }
      return const AttachmentDownloadFailed(
        StorageFailure(StorageFailureKind.unavailable),
        stage: AttachmentDownloadStage.verification,
      );
    } finally {
      await storage.delete(encrypted);
    }
  }
}

/// The step of [AttachmentTransferService.downloadAndDecrypt] a failure came
/// from.
enum AttachmentDownloadStage {
  /// Fetching the ciphertext: the server refused it, the connection dropped,
  /// or the answer broke the length or the range rules. No byte was verified.
  download,

  /// Verifying and decrypting what arrived: the header, a chunk, the length
  /// or the padding is not what the descriptor describes, or the decrypted
  /// file could not be written.
  verification,
}

/// What [AttachmentTransferService.downloadAndDecrypt] gives.
sealed class AttachmentDownloadResult {
  const AttachmentDownloadResult();
}

/// A verified, decrypted temporary file, which the caller now owns.
final class AttachmentDownloaded extends AttachmentDownloadResult {
  const AttachmentDownloaded(this.file);

  final File file;

  @override
  String toString() => 'AttachmentDownloaded(<redacted>)';
}

/// A download that gave no file: [failure], in [stage].
final class AttachmentDownloadFailed extends AttachmentDownloadResult {
  const AttachmentDownloadFailed(this.failure, {required this.stage});

  final Failure failure;
  final AttachmentDownloadStage stage;

  @override
  String toString() => 'AttachmentDownloadFailed(${stage.name})';
}
