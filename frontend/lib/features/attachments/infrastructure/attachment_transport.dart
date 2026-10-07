import 'dart:async';
import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/backend_error_mapper.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:dio/dio.dart';

export 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart'
    show AttachmentTransportPort, AttachmentUploadResponse;

/// Direct streaming adapter for the documented attachment endpoints.
final class DioAttachmentTransport implements AttachmentTransportPort {
  DioAttachmentTransport({
    required Uri serverOrigin,
    required this.tokens,
    required this.config,
    required this.allowance,
    required this.clock,
    required this.storage,
    Dio? dio,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: serverOrigin.toString(),
               followRedirects: false,
               maxRedirects: 0,
               validateStatus: (_) => true,
             ),
           );

  final Dio _dio;
  final AccessTokenCoordinator tokens;

  /// The bucket set and the day's allowance this deployment publishes.
  final ServerConfigSnapshot config;

  /// What this device has already uploaded today.
  final AttachmentAllowancePort allowance;

  final TimeSource clock;

  /// Where a download's ciphertext is written.
  final AttachmentStoragePort storage;

  /// The buckets a download resumes in: the two largest, 16 MiB and 64 MiB.
  ///
  /// Below them a download is fetched again from zero. The largest of the rest
  /// is 4 MiB, a quarter of the smallest bucket that resumes, and it costs less
  /// to fetch again than the bookkeeping costs to keep.
  static final Set<int> resumableBuckets =
      (AttachmentCryptoProtocolV1.buckets.toList()..sort()).reversed
          .take(2)
          .toSet();

  /// The download that stopped part-way and may be taken up again, or null.
  ///
  /// One at a time, and in memory. A second download that stops replaces it,
  /// which bounds what resuming keeps on disk to one bucket. The record names a
  /// capability, so it is never written anywhere but this object: a process
  /// that dies takes it along, and its file is left behind as any temporary
  /// file of a killed process is.
  _PartialDownload? _partial;

  @override
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
  }) async {
    final limits = config.current;
    if (!await encryptedFile.exists() ||
        await encryptedFile.length() != bucketSize ||
        // An off-bucket upload is `400 bad_bucket`, and the set is the
        // deployment's rather than this build's: an operator who dropped the
        // largest bucket has a server that refuses what this client would
        // otherwise spend a whole upload discovering.
        !limits.attachmentBuckets.contains(bucketSize)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    // What is left of the day, before the bytes are sent rather than after the
    // refusal that would otherwise be the first anyone hears of it. The count
    // is this device's own — the server publishes the ceiling and never the
    // balance — so it can only be a lower bound on what has been spent, and an
    // upload it lets through may still be refused. That is the safe direction:
    // it never withholds room the server would have granted.
    final now = clock.now();
    final left = (await allowance.read(
      now,
    )).remaining(dailyBytes: limits.attachmentDailyBytes, now: now);
    if (bucketSize > left) {
      return const Result.failure(
        BackendFailure(BackendFailureCode.quotaExceeded),
      );
    }
    final token = await _fullToken();
    if (token case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final cancelToken = CancelToken();
    final subscription = cancellation?.whenCancelled.listen((_) {
      cancelToken.cancel('cancelled');
    });
    try {
      final response = await _dio.post<Object?>(
        '/api/v1/attachments',
        data: FormData.fromMap({
          'blob': await MultipartFile.fromFile(
            encryptedFile.path,
            filename: 'blob',
          ),
        }),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.json,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization':
                'Bearer ${(token as Success<AccessToken>).value.value}',
            'Accept': 'application/json',
          },
        ),
      );
      if (response.statusCode != 201 || response.data is! Map) {
        return Result.failure(
          _responseFailure(response.statusCode, response.data),
        );
      }
      final json = response.data! as Map;
      final id = json['attachment_id'];
      final size = json['size'];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id) ||
          size is! int ||
          size != bucketSize) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      // Recorded after the server took them, and never before: a failed
      // upload spends nothing, and the day's counter is what was sent rather
      // than what is still stored — deleting an attachment gives none of it
      // back.
      await allowance.record(bytes: size, now: clock.now());
      return Result.success(
        AttachmentUploadResponse(capabilityId: id, bucketSize: size),
      );
    } on DioException catch (error) {
      return error.type == DioExceptionType.cancel
          ? const Result.failure(
              CancellationFailure(CancellationFailureKind.requestedByUser),
            )
          : const Result.failure(
              TransportFailure(TransportFailureKind.offline),
            );
    } finally {
      await subscription?.cancel();
    }
  }

  @override
  Future<Result<File>> download({
    required String capabilityId,
    required int expectedBucketSize,
    CancellationSignal? cancellation,
    void Function(int bytes)? onProgress,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(capabilityId) ||
        expectedBucketSize <= 0) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final token = await _fullToken();
    if (token case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final previous = _takePartial(capabilityId, expectedBucketSize);
    final file = previous?.file ?? await storage.createEncryptedTemp();
    final cancelToken = CancelToken();
    final subscription = cancellation?.whenCancelled.listen((_) {
      cancelToken.cancel('cancelled');
    });
    RandomAccessFile? output;
    // The tag the bytes on disk were fetched under, which a later attempt
    // sends back in `If-Range`. Null whenever they cannot be resumed: nothing
    // has been fetched, the answer carried no strong tag, or the bucket is one
    // of the small ones.
    String? tag;
    // Whether this attempt ended in a way that leaves the object as it was
    // and the bytes on disk a true prefix of it: a dropped transfer, a
    // cancellation, or a refusal other than the two below that say they are
    // not. Nothing else keeps them.
    var resumeLater = false;
    File? fetched;
    try {
      output = await file.open(mode: FileMode.append);
      var offset = await output.length();
      tag = previous?.tag;
      if (tag == null || offset <= 0 || offset >= expectedBucketSize) {
        offset = await _restart(output);
        tag = null;
      }
      final response = await _dio.get<ResponseBody>(
        '/api/v1/attachments/$capabilityId',
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization':
                'Bearer ${(token as Success<AccessToken>).value.value}',
            'Accept': 'application/octet-stream',
            // The rest of the object, and only if it is still the object the
            // bytes came from: a server whose tag no longer matches ignores
            // the range and answers the whole body (RFC 9110 §13.1.5).
            if (tag != null) 'Range': 'bytes=$offset-',
            'If-Range': ?tag,
          },
        ),
      );
      final status = response.statusCode;
      if (status != 200 && status != 206) {
        // A refusal carries no byte of the object, so the bytes on disk are
        // as good as they were. Two refusals say otherwise: the `404` that
        // says the object is gone, and the `416` nginx answers a range that
        // does not fit it, which these bytes would then ask for every time.
        resumeLater =
            status != null && status >= 400 && status != 404 && status != 416;
        return Result.failure(_statusFailure(status));
      }
      final body = response.data;
      if (body == null || (status == 206 && tag == null)) {
        // Nothing to read, or a continuation of bytes this attempt never
        // asked to continue.
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      final answeredTag = _onlyValue(response.headers, 'etag');
      if (tag != null && answeredTag != null && answeredTag != tag) {
        // The object the bytes came from is not the one answering. An
        // attachment is immutable and its id is never reused, so its tag
        // moves only after the retention sweep deleted it: the attachment is
        // gone, exactly as a `404` says.
        return const Result.failure(
          BackendFailure(BackendFailureCode.notFound),
        );
      }
      if (status == 206) {
        // A continuation of these bytes and of nothing else: starting where
        // they stop and running to the bucket's last byte.
        if (_onlyValue(response.headers, 'content-range') !=
            'bytes $offset-${expectedBucketSize - 1}/$expectedBucketSize') {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
      } else {
        if (tag != null) {
          // Asked for a range and sent the whole object, under a tag that
          // still matches: the answer starts at the first byte, so the file
          // does too.
          offset = await _restart(output);
        }
        tag = resumableBuckets.contains(expectedBucketSize)
            ? _strongTag(answeredTag)
            : null;
      }
      // Counted from the resume offset rather than from zero.
      var count = offset;
      await for (final chunk in body.stream) {
        if (cancellation?.isCancelled ?? false) {
          resumeLater = true;
          return const Result.failure(
            CancellationFailure(CancellationFailureKind.requestedByUser),
          );
        }
        count += chunk.length;
        if (count > expectedBucketSize) {
          return const Result.failure(
            TransportFailure(TransportFailureKind.responseTooLarge),
          );
        }
        await output.writeFrom(chunk);
        onProgress?.call(count);
      }
      // What ends on disk is exactly one bucket, however many answers it took
      // to collect.
      if (count != expectedBucketSize ||
          await output.length() != expectedBucketSize) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      final written = output;
      output = null;
      await written.close();
      fetched = file;
      return Result.success(file);
    } on DioException catch (error) {
      resumeLater = true;
      return error.type == DioExceptionType.cancel
          ? const Result.failure(
              CancellationFailure(CancellationFailureKind.requestedByUser),
            )
          : const Result.failure(
              TransportFailure(TransportFailureKind.offline),
            );
    } on FileSystemException {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    } on IOException {
      // The connection dropped mid-transfer. dart:io reports that on the body
      // stream as an `HttpException`, and Dio passes it through as it is
      // rather than as a `DioException`. It is the failure resuming is for.
      resumeLater = true;
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    } finally {
      await subscription?.cancel();
      try {
        await output?.close();
      } on FileSystemException {
        resumeLater = false;
      }
      if (fetched == null) {
        final resumeTag = tag;
        if (resumeLater && resumeTag != null) {
          await _keepPartial(
            _PartialDownload(
              capabilityId: capabilityId,
              bucketSize: expectedBucketSize,
              file: file,
              tag: resumeTag,
            ),
          );
        } else {
          await storage.delete(file);
        }
      }
    }
  }

  /// The kept partial download of [capabilityId] in [bucketSize], taken out
  /// so that a second download of it running at the same time starts a file
  /// of its own rather than writing this one.
  _PartialDownload? _takePartial(String capabilityId, int bucketSize) {
    final partial = _partial;
    if (partial == null ||
        partial.capabilityId != capabilityId ||
        partial.bucketSize != bucketSize) {
      return null;
    }
    _partial = null;
    return partial;
  }

  /// Keeps [partial] for the next attempt, in place of whatever was kept.
  Future<void> _keepPartial(_PartialDownload partial) async {
    final replaced = _partial;
    _partial = partial;
    if (replaced != null && replaced.file.path != partial.file.path) {
      await storage.delete(replaced.file);
    }
  }

  Future<Result<AccessToken>> _fullToken() async {
    final result = await tokens.accessToken();
    if (result case Success(
      value: final token,
    ) when token.scope == SessionScope.full) {
      return result;
    }
    return const Result.failure(
      BackendFailure(BackendFailureCode.scopeForbidden),
    );
  }
}

/// The upload's refusal, read from the envelope this route answers with.
///
/// The status alone is not enough on this one route. `413` is `quota_exceeded`
/// — the day's allowance, spent, so the attachment is held until 00:00 UTC —
/// and it is also `payload_too_large`, a body above the route's cap, which no
/// waiting fixes. `503` is `storage_full`, the operator's disk, and it is also
/// `unavailable`, an outage. Reading the status would pick one of each pair by
/// coin toss, so the `code` decides and the mapper is what knows the
/// vocabulary.
Failure _responseFailure(int? status, Object? body) {
  if (status == null) {
    return const SecurityFailure(SecurityFailureKind.malformedServerResponse);
  }
  final code = body is Map ? body['code'] : null;
  return mapBackendFailure(
    statusCode: status,
    wireCode: code is String ? code : null,
  );
}

/// The download's refusal.
///
/// The body is a byte stream here rather than JSON, so there is no envelope to
/// read and the status is all there is. It is enough: this route answers
/// neither of the two shared statuses, because nothing is uploaded to it — no
/// allowance is spent and no disk fills.
Failure _statusFailure(int? status) => switch (status) {
  401 => const BackendFailure(BackendFailureCode.invalidToken),
  403 => const BackendFailure(BackendFailureCode.scopeForbidden),
  404 => const BackendFailure(BackendFailureCode.notFound),
  429 => const BackendFailure(BackendFailureCode.throttled),
  _ => const SecurityFailure(SecurityFailureKind.malformedServerResponse),
};

/// Bytes a download has already written, and what it takes to go on from
/// them.
final class _PartialDownload {
  const _PartialDownload({
    required this.capabilityId,
    required this.bucketSize,
    required this.file,
    required this.tag,
  });

  final String capabilityId;
  final int bucketSize;
  final File file;

  /// The `ETag` of the answer the bytes in [file] came from.
  final String tag;
}

/// Empties [output] and puts its next write at byte zero.
Future<int> _restart(RandomAccessFile output) async {
  await output.truncate(0);
  await output.setPosition(0);
  return 0;
}

/// The value of the header [name], or null unless the answer carries it
/// exactly once.
String? _onlyValue(Headers headers, String name) {
  final values = headers[name];
  return values != null && values.length == 1 ? values.single : null;
}

/// [value] when it is a strong entity tag, the only kind a client may send in
/// `If-Range` (RFC 9110 §13.1.5), and null otherwise.
///
/// It is kept exactly as it arrived, because the server compares the two
/// character by character (§8.8.3.2).
String? _strongTag(String? value) =>
    value != null && _strongEntityTag.hasMatch(value) ? value : null;

final _strongEntityTag = RegExp(r'^"[\x21\x23-\x7e]{1,128}"$');
