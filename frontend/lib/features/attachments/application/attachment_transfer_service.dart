import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
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

  Future<Result<File>> downloadAndDecrypt({
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
      return Result.failure(failure);
    }
    final encrypted = (downloaded as Success<File>).value;
    try {
      final decrypted = await storage.createDecryptedTemp();
      final encryptedStream = encrypted.openRead();
      final decryptedResult = await crypto.decryptStreamToFile(
        descriptor: descriptor,
        ciphertext: encryptedStream,
        destination: decrypted,
        cancellation: cancellation,
        onProgress: onProgress,
      );
      if (decryptedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      return Result.success(decrypted);
    } finally {
      await storage.delete(encrypted);
      // The caller owns a verified file and must hand it to the attachment
      // cache or delete it. A failure path is cleaned by the crypto service.
    }
  }
}
