import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/infrastructure/relay_credential_api_dtos.dart';

/// `POST /api/v1/me/relay` through the one reviewed REST client.
///
/// The request has no body, no path parameter and no query parameter: the
/// caller is the device the session token names, and the answer names nothing
/// the caller asked for.
final class DioRelayCredentialRepository implements RelayCredentialPort {
  const DioRelayCredentialRepository(this.client, {required this.clock});

  final DioRestClient client;

  /// Anchors the expiry of each credential this mints.
  final TimeSource clock;

  @override
  Future<Result<RelayCredential>> mint() async {
    final requestedAt = clock.now();
    final result = await client.send(
      ApiRequest<RelayCredentialResponseDto>(
        method: RestMethod.post,
        path: '/api/v1/me/relay',
        decode: RelayCredentialResponseDto.fromJson,
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.full,
        limits: ApiContractLimits.smallJson,
        // Stated by the route: every call mints a fresh user name and a
        // credential already issued stays good, so a replay after a lost
        // answer leaves two working credentials rather than none. The one
        // refusal a replay cannot change, `503 voice_unconfigured`, is never
        // replayed by the client.
        replaySafety: ReplaySafety.contractIdempotent,
      ),
    );
    return result.fold(
      onSuccess: (response) =>
          Result.success(response.toDomain(requestedAt: requestedAt)),
      onFailure: Result.failure,
    );
  }
}
