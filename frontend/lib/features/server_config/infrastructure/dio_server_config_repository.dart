import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/server_config_api_dtos.dart';

/// `GET /api/v1/config` through the one reviewed REST client.
///
/// Read-only replay is safe by the route's own statement: it writes nothing,
/// reads no row, and takes no database connection, so it answers while the rest
/// of the surface is refusing.
final class DioServerConfigRepository implements ServerConfigReadPort {
  const DioServerConfigRepository(this.client);

  final DioRestClient client;

  @override
  Future<Result<ServerConfig>> fetchPublishedConfig() => client
      .send(
        ApiRequest<ServerConfigResponseDto>(
          method: RestMethod.get,
          path: '/api/v1/config',
          decode: ServerConfigResponseDto.fromJson,
          acceptedStatusCodes: const {200},
          authentication: AuthenticationRequirement.full,
          limits: ApiContractLimits.smallJson,
          replaySafety: ReplaySafety.readOnly,
        ),
      )
      .then(
        (result) => result.fold(
          onSuccess: (response) => Result.success(response.config),
          onFailure: Result.failure,
        ),
      );
}
