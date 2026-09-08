import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/authentication_api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';

final class DioAccountAuthenticationRepository
    implements AccountAuthenticationRepository {
  const DioAccountAuthenticationRepository(this.client);

  final DioRestClient client;

  @override
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  }) async {
    final result = await client.send<RegisterAccountResponseDto>(
      ApiRequest<RegisterAccountResponseDto>(
        method: RestMethod.post,
        path: '/api/v1/auth/register',
        decode: RegisterAccountResponseDto.fromJson,
        acceptedStatusCodes: const {201},
        authentication: AuthenticationRequirement.none,
        limits: ApiContractLimits.smallJson,
        operation: NetworkOperation.authRegister,
        body: RegisterAccountRequestDto(
          username: username,
          password: password,
        ).toJson(),
      ),
    );
    return result.fold(
      onSuccess: (dto) => Result.success(dto.toDomain()),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async {
    final result = await client.send<LoginAccountResponseDto>(
      ApiRequest<LoginAccountResponseDto>(
        method: RestMethod.post,
        path: '/api/v1/auth/login',
        decode: LoginAccountResponseDto.fromJson,
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.none,
        limits: ApiContractLimits.smallJson,
        operation: NetworkOperation.authLogin,
        body: LoginAccountRequestDto(
          username: username,
          password: password,
          deviceId: deviceId,
        ).toJson(),
      ),
    );
    return result.fold(
      onSuccess: (dto) => Result.success(dto.toDomain()),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<void>> eraseAccount({required String password}) async {
    final result = await client.send<EmptyResponseDto>(
      ApiRequest<EmptyResponseDto>(
        method: RestMethod.delete,
        path: '/api/v1/me',
        decode: EmptyResponseDto.fromJson,
        acceptedStatusCodes: const {204},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        // Nothing about this call may be repeated by the transport. A retry of
        // it answers `401 token_revoked` rather than a second `204`, and the
        // use case, not the client, is what turns that into success.
        replaySafety: ReplaySafety.never,
        body: EraseAccountRequestDto(password: password).toJson(),
      ),
    );
    return result.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }
}
