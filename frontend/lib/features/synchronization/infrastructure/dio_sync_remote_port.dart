import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';

/// The three envelope routes, held to the ceilings this deployment publishes.
///
/// Every bound here is `GET /api/v1/config`'s rather than this build's:
/// `drain_page_max`, `ack_max` and `send_batch_max` are what the routes
/// themselves enforce, and an operator may move any of them between two
/// restarts. Reading them per call rather than at construction is what lets the
/// answer arrive mid-session without the delivery engine being rebuilt around
/// it.
final class DioSyncRemotePort implements SyncRemotePort {
  const DioSyncRemotePort(this.client, this.config);

  final DioRestClient client;
  final ServerConfigSnapshot config;

  /// [limit] is what the caller wants. What is asked for is that held against
  /// `drain_page_max`, which is both the route's ceiling and its default: a
  /// deployment that lowered it would refuse a larger request outright, and a
  /// refused page is envelopes left undrained for a number the caller has no
  /// business knowing. Asking for none of them is still a caller fault.
  @override
  Future<Result<DrainPage>> drain({required int limit}) async {
    final limits = config.current;
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit');
    }
    final page = limit < limits.drainPageMax ? limit : limits.drainPageMax;
    final result = await client.send(
      ApiRequest<DrainEnvelopesResponseDto>(
        method: RestMethod.get,
        path: '/api/v1/me/envelopes',
        queryParameters: {'limit': page},
        // The same configuration the request was measured against decodes the
        // response, so a page cannot be refused for a ceiling that moved
        // between asking and answering.
        decode: (json) => DrainEnvelopesResponseDto.fromJson(json, limits),
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.envelopeDrainJson,
        replaySafety: ReplaySafety.readOnly,
        operation: NetworkOperation.syncDrain,
      ),
    );
    return result.fold(
      onSuccess: (response) => Result.success(
        DrainPage(
          envelopes: response.envelopes
              .map(
                (envelope) => SyncEnvelope(
                  id: envelope.id.toLowerCase(),
                  sequence: envelope.sequence,
                  exactCiphertext: _decodeEnvelope(envelope.blob),
                ),
              )
              .toList(growable: false),
          hasMore: response.hasMore,
          prunedThrough: response.prunedThrough,
        ),
      ),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async {
    final limits = config.current;
    if (envelopeIds.isEmpty || envelopeIds.length > limits.ackMax) {
      throw ArgumentError.value(envelopeIds.length, 'envelopeIds.length');
    }
    final result = await client.send(
      ApiRequest<_AcknowledgementResponse>(
        method: RestMethod.post,
        path: '/api/v1/me/envelopes/ack',
        body: {'ids': envelopeIds},
        decode: (json) => _AcknowledgementResponse.fromJson(json, limits),
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        replaySafety: ReplaySafety.contractIdempotent,
        operation: NetworkOperation.syncAcknowledge,
      ),
    );
    return result.fold(
      onSuccess: (response) => Result.success(response.deleted),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    final limits = config.current;
    if (batch.targets.isEmpty || batch.targets.length > limits.sendBatchMax) {
      throw ArgumentError.value(batch.targets.length, 'batch.targets.length');
    }
    final result = await client.send(
      ApiRequest<_SendResponse>(
        method: RestMethod.post,
        path: '/api/v1/envelopes',
        body: {
          'messages': batch.targets
              .map(
                (target) => {
                  'device_id': target.recipientDeviceId,
                  'blob': base64Encode(target.exactCiphertext),
                },
              )
              .toList(growable: false),
        },
        decode: (json) => _SendResponse.fromJson(json, limits),
        acceptedStatusCodes: const {202},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.envelopeBatchJson,
        replaySafety: ReplaySafety.never,
        operation: NetworkOperation.syncSend,
      ),
    );
    return result.fold(
      onSuccess: (response) => Result.success(
        OutboxAcceptance(
          accepted: response.accepted,
          staleDeviceIds: response.staleDeviceIds,
        ),
      ),
      onFailure: Result.failure,
    );
  }

  Uint8List _decodeEnvelope(String value) => base64Decode(value);
}

final class _AcknowledgementResponse {
  const _AcknowledgementResponse(this.deleted);

  factory _AcknowledgementResponse.fromJson(
    Object? value,
    ServerConfig config,
  ) {
    final json = requireJsonObject(value);
    final deleted = json['deleted'];
    if (json.length != 1 ||
        deleted is! int ||
        deleted < 0 ||
        deleted > config.ackMax) {
      throw const MalformedApiBody();
    }
    return _AcknowledgementResponse(deleted);
  }

  final int deleted;
}

final class _SendResponse {
  const _SendResponse({required this.accepted, required this.staleDeviceIds});

  factory _SendResponse.fromJson(Object? value, ServerConfig config) {
    final json = requireJsonObject(value);
    final accepted = json['accepted'];
    final stale = json['stale_devices'];
    if (json.length != 2 ||
        accepted is! int ||
        accepted < 0 ||
        accepted > config.sendBatchMax ||
        stale is! List<Object?> ||
        stale.length > config.sendBatchMax) {
      throw const MalformedApiBody();
    }
    final ids = <String>{};
    for (final value in stale) {
      if (value is! String ||
          !_uuid.hasMatch(value) ||
          !ids.add(value.toLowerCase())) {
        throw const MalformedApiBody();
      }
    }
    return _SendResponse(accepted: accepted, staleDeviceIds: ids);
  }

  final int accepted;
  final Set<String> staleDeviceIds;
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
