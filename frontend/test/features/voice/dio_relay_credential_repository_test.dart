import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/infrastructure/dio_relay_credential_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/relay_fakes.dart';

/// The one call this feature makes, through the reviewed REST client.
void main() {
  final requestedAt = DateTime.utc(2026, 9, 30, 12);

  DioRelayCredentialRepository repositoryOn(RelayAdapter adapter) =>
      DioRelayCredentialRepository(
        relayRestClient(adapter),
        clock: MutableClock(requestedAt),
      );

  BackendFailure backendFailureOf(Result<RelayCredential> result) =>
      (result as FailureResult<RelayCredential>).failure as BackendFailure;

  test('mints with one authenticated POST that carries nothing', () async {
    final adapter = RelayAdapter([relayJson(200, relayBody())]);

    final minted = await repositoryOn(adapter).mint();

    final credential = (minted as Success<RelayCredential>).value;
    expect(credential.urls, relayUrls);
    expect(credential.username, relayUsername);
    expect(credential.credential, relayPassword);
    expect(credential.expiresAt, requestedAt.add(const Duration(hours: 6)));

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/me/relay');
    expect(request.queryParameters, isEmpty);
    expect(request.data, isNull);
    expect(request.headers['Authorization'], 'Bearer access-token');
  });

  test('a 503 voice_unconfigured is answered once and never replayed', () async {
    // The route is safe to repeat, so a timeout or an outage is replayed. This
    // answer is neither: the relay list is empty, and asking again cannot
    // fill it. The second answer is there to be taken if anything replays.
    final adapter = RelayAdapter([
      relayJson(503, {
        'code': 'voice_unconfigured',
        'detail': 'This deployment serves no voice relay.',
      }),
      relayJson(200, relayBody()),
    ]);

    final minted = await repositoryOn(adapter).mint();

    expect(adapter.requests, hasLength(1));
    expect(backendFailureOf(minted).code, BackendFailureCode.voiceUnconfigured);
  });

  test('a 503 outage is replayed once, as the route allows', () async {
    final adapter = RelayAdapter([
      relayJson(503, {'code': 'unavailable', 'detail': 'Try later.'}),
      relayJson(200, relayBody()),
    ]);

    final minted = await repositoryOn(adapter).mint();

    expect(minted, isA<Success<RelayCredential>>());
    expect(adapter.requests, hasLength(2));
  });

  test('a timed-out mint is replayed once, as the route allows', () async {
    // Two live credentials after a timeout is normal, and both work.
    final adapter = RelayAdapter([relayTimeout(), relayJson(200, relayBody())]);

    final minted = await repositoryOn(adapter).mint();

    expect(minted, isA<Success<RelayCredential>>());
    expect(adapter.requests, hasLength(2));
  });

  test('a 429 carries its Retry-After and is not replayed', () async {
    final adapter = RelayAdapter([
      relayJson(
        429,
        {'code': 'throttled', 'detail': 'Request was throttled.'},
        headers: {
          'retry-after': ['17'],
        },
      ),
    ]);

    final minted = await repositoryOn(adapter).mint();

    final failure = backendFailureOf(minted);
    expect(failure.code, BackendFailureCode.throttled);
    expect(failure.retryAfter, const Duration(seconds: 17));
    expect(adapter.requests, hasLength(1));
  });

  test(
    'a 200 that is not a credential is a failure, not a credential',
    () async {
      final adapter = RelayAdapter([
        relayJson(200, relayBody()..['urls'] = ['stun:chat.orviniq.com:3478']),
      ]);

      final minted = await repositoryOn(adapter).mint();

      expect(
        (minted as FailureResult<RelayCredential>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.malformedServerResponse,
        ),
      );
    },
  );
}
