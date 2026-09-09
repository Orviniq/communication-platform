import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_key_package_ports.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/infrastructure/group_key_package_api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';

final class DioGroupKeyPackageRepository implements GroupKeyPackageRemotePort {
  const DioGroupKeyPackageRepository(this.client, this.config);

  final DioRestClient client;
  final ServerConfigSnapshot config;

  @override
  Future<Result<int>> fetchConsumableCount({required String deviceId}) => client
      .send(
        ApiRequest<GroupKeyPackageCountResponseDto>(
          method: RestMethod.get,
          path: '/api/v1/me/devices/$deviceId/keypackages/count',
          decode: GroupKeyPackageCountResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.keyPackageJson,
          replaySafety: ReplaySafety.readOnly,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (response) => Result.success(response.count),
          onFailure: Result.failure,
        ),
      );

  @override
  Future<Result<int>> upload({
    required String deviceId,
    required GroupKeyPackageUpload upload,
  }) => client
      .send(
        ApiRequest<GroupKeyPackageCountResponseDto>(
          method: RestMethod.put,
          path: '/api/v1/me/devices/$deviceId/keypackages',
          body: groupKeyPackageUploadJson(upload),
          decode: GroupKeyPackageCountResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.keyPackageJson,
          replaySafety: upload.isContractIdempotent
              ? ReplaySafety.contractIdempotent
              : ReplaySafety.never,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (response) => Result.success(response.count),
          onFailure: Result.failure,
        ),
      );

  @override
  Future<Result<List<ClaimedGroupKeyPackage>>> claim({
    required String userId,
    List<String>? deviceIds,
  }) => client
      .send(
        ApiRequest<ClaimedGroupKeyPackagesResponseDto>(
          method: RestMethod.post,
          path: '/api/v1/users/$userId/keypackages/claim',
          body: groupKeyPackageClaimJson(
            deviceIds,
            claimMax: config.current.claimMax,
          ),
          decode: ClaimedGroupKeyPackagesResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.keyPackageJson,
          replaySafety: ReplaySafety.never,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (response) => Result.success(response.packages),
          onFailure: Result.failure,
        ),
      );
}
