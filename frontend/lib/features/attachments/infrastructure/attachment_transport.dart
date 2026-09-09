import 'dart:async';
import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
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
  Future<Result<void>> download({
    required String capabilityId,
    required IOSink destination,
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
    final cancelToken = CancelToken();
    final subscription = cancellation?.whenCancelled.listen((_) {
      cancelToken.cancel('cancelled');
    });
    var count = 0;
    try {
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
          },
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        return Result.failure(_statusFailure(response.statusCode));
      }
      await for (final chunk in response.data!.stream) {
        if (cancellation?.isCancelled ?? false) {
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
        destination.add(chunk);
        onProgress?.call(count);
      }
      if (count != expectedBucketSize) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      return const Result.success(null);
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
