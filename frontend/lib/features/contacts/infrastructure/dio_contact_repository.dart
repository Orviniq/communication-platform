import 'dart:convert';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/contact_api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';

final class DioContactRepository
    implements DirectoryRemotePort, ProfileRemotePort, PeerIdentityRemotePort {
  const DioContactRepository(this.client, this.config);

  final DioRestClient client;

  /// The published ceilings this repository holds its own requests to.
  final ServerConfigSnapshot config;

  @override
  Future<Result<List<DirectoryUser>>> fetchActivatedUsers() => client
      .send(
        ApiRequest<DirectoryResponseDto>(
          method: RestMethod.get,
          path: '/api/v1/users',
          decode: DirectoryResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.smallJson,
          replaySafety: ReplaySafety.readOnly,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (value) => Result.success(value.users),
          onFailure: Result.failure,
        ),
      );

  @override
  Future<Result<ProfileCiphertext?>> fetchProfile({required String userId}) =>
      _profile('/api/v1/users/$userId/profile');

  @override
  Future<Result<ProfileCiphertext?>> fetchOwnProfile() =>
      _profile('/api/v1/me/profile');

  Future<Result<ProfileCiphertext?>> _profile(String path) async {
    final result = await client.send(
      ApiRequest<ProfileResponseDto>(
        method: RestMethod.get,
        path: path,
        decode: ProfileResponseDto.fromJson,
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        replaySafety: ReplaySafety.readOnly,
      ),
    );
    if (result case FailureResult(
      failure: BackendFailure(code: BackendFailureCode.notFound),
    )) {
      return const Result.success(null);
    }
    return result.fold(
      onSuccess: (value) => Result.success(value.profile),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<void>> publishOwnProfile(ProfileCiphertext profile) => client
      .send(
        ApiRequest<EmptyResponseDto>(
          method: RestMethod.put,
          path: '/api/v1/me/profile',
          body: {
            'blob': base64Encode(profile.blob),
            'version': profile.version,
          },
          decode: EmptyResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.smallJson,
          replaySafety: ReplaySafety.never,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (_) => const Result.success(null),
          onFailure: Result.failure,
        ),
      );

  @override
  Future<Result<PeerIdentityPublic>> fetchIdentity({required String userId}) =>
      client
          .send(
            ApiRequest<PeerIdentityResponseDto>(
              method: RestMethod.get,
              path: '/api/v1/users/$userId/identity',
              decode: PeerIdentityResponseDto.fromJson,
              acceptedStatusCodes: const {200},
              authentication: AuthenticationRequirement.full,
              limits: ApiContractLimits.smallJson,
              replaySafety: ReplaySafety.readOnly,
            ),
          )
          .then(
            (result) => result.fold(
              onSuccess: (value) => Result.success(value.identity),
              onFailure: Result.failure,
            ),
          );

  @override
  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  }) => client
      .send(
        ApiRequest<PeerDevicesResponseDto>(
          method: RestMethod.get,
          path: '/api/v1/users/$userId/devices',
          headers: {'If-None-Match': ?etag},
          decode: PeerDevicesResponseDto.fromJson,
          acceptedStatusCodes: const {200, 304},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.smallJson,
          replaySafety: ReplaySafety.readOnly,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (value) => Result.success(value.refresh),
          onFailure: Result.failure,
        ),
      );

  @override
  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  }) {
    // `claim_max` is what the route enforces, and a body past it is refused
    // whole — so a claim that would consume one one-time prekey per device
    // gets none of them. A peer's device set is bounded by
    // `max_devices_per_user` and cannot ordinarily reach this, which is why
    // the answer is a refusal rather than a split into several calls: a caller
    // that arrived here with more device ids than the deployment accepts has
    // gone wrong somewhere the transport cannot repair.
    if (deviceIds.length > config.current.claimMax) {
      return Future.value(
        const Result.failure(
          ValidationFailure(ValidationFailureKind.limitExceeded),
        ),
      );
    }
    return client
        .send(
          ApiRequest<ClaimedBundlesResponseDto>(
            method: RestMethod.post,
            path: '/api/v1/users/$userId/keys/claim',
            body: {'device_ids': deviceIds},
            decode: ClaimedBundlesResponseDto.fromJson,
            acceptedStatusCodes: const {200},
            authentication: AuthenticationRequirement.full,
            limits: ApiContractLimits.smallJson,
            replaySafety: ReplaySafety.never,
          ),
        )
        .then(
          (result) => result.fold(
            onSuccess: (value) => Result.success(value.bundles),
            onFailure: Result.failure,
          ),
        );
  }

  @override
  Future<Result<PeerDeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) => client
      .send(
        ApiRequest<PeerDeviceLogPageDto>(
          method: RestMethod.get,
          path: '/api/v1/users/$userId/devicelog',
          queryParameters: {'after': ?after, 'limit': 200},
          decode: PeerDeviceLogPageDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.smallJson,
          replaySafety: ReplaySafety.readOnly,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (value) => Result.success(value.page),
          onFailure: Result.failure,
        ),
      );
}
