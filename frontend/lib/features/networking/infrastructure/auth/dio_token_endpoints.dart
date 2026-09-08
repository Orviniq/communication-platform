import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';

/// `POST /api/v1/auth/renew`, which replaced `POST /api/v1/auth/refresh`.
///
/// The route it replaced was anonymous and carried its secret in the body.
/// This one is an ordinary authenticated call: it takes no body at all, and
/// the session token travels in the `Authorization` header the reviewed client
/// attaches for [AuthenticationRequirement.full]. A register token is refused
/// there (`403 scope_forbidden`), so the requirement is the full one.
final class DioRenewTokenExchange implements RenewTokenExchange {
  const DioRenewTokenExchange(this.client);

  final DioRestClient client;

  @override
  Future<Result<SessionTokens>> renew() async {
    final result = await client.send<SessionTokenResponseDto>(
      ApiRequest<SessionTokenResponseDto>(
        method: RestMethod.post,
        path: '/api/v1/auth/renew',
        decode: SessionTokenResponseDto.fromJson,
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        operation: NetworkOperation.authRenew,
        // Stated by the route: nothing is written and no generation moves, so
        // a repeat issues another token and retires none. A renewal whose
        // answer was lost is therefore replayable, which is what makes a
        // dropped connection cost a retry rather than the session.
        replaySafety: ReplaySafety.contractIdempotent,
      ),
    );
    return result.fold(
      onSuccess: (dto) => Result.success(dto.toDomain()),
      onFailure: Result.failure,
    );
  }
}

/// `POST /api/v1/auth/logout`, which answers `204` and takes no body.
///
/// The device is named by the token, not by the request: `token_generation`
/// advances and every token of that device dies at once, so there is nothing
/// to send and nothing to leak.
final class DioLogoutTokenExchange implements LogoutTokenExchange {
  const DioLogoutTokenExchange(this.client);

  final DioRestClient client;

  @override
  Future<void> revoke({required String accessToken}) async {
    await client.send<EmptyResponseDto>(
      ApiRequest<EmptyResponseDto>(
        method: RestMethod.post,
        path: '/api/v1/auth/logout',
        decode: EmptyResponseDto.fromJson,
        acceptedStatusCodes: const {204},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        operation: NetworkOperation.authLogout,
      ),
    );
  }
}
