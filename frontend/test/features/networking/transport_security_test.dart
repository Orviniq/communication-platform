@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/bootstrap/infrastructure/dio_health_reachability_port.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// These run against a real local TLS server. A mocked handshake could not show
/// that an untrusted chain is actually refused, which is the property that
/// matters: the app must reach the provisioned server and nothing else.
void main() {
  late HttpServer server;
  late Uri origin;

  Uint8List fixture(String name) =>
      File('test/fixtures/tls/$name').readAsBytesSync();

  setUp(() async {
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(fixture('server_chain.pem'))
      ..usePrivateKeyBytes(fixture('server_key.pem'));

    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    origin = Uri.parse('https://localhost:${server.port}');

    unawaited(
      server.forEach((request) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}));
        unawaited(request.response.close());
      }),
    );
  });

  tearDown(() => server.close(force: true));

  Future<Result<HealthResponseDto>> health(TransportSecurity security) {
    final client = DioRestClient(
      serverOrigin: origin,
      transportSecurity: security,
    );
    return client.send<HealthResponseDto>(
      ApiRequest<HealthResponseDto>(
        method: RestMethod.get,
        path: '/api/v1/health',
        decode: HealthResponseDto.fromJson,
        acceptedStatusCodes: const {200},
        authentication: AuthenticationRequirement.none,
        limits: ApiContractLimits.smallJson,
        operation: NetworkOperation.health,
        replaySafety: ReplaySafety.readOnly,
      ),
    );
  }

  test('a chain rooted in the provisioned authority is accepted', () async {
    final result = await health(
      TransportSecurity.provisioned(fixture('provisioned_ca.pem')),
    );

    expect(result, isA<Success<HealthResponseDto>>());
  });

  test('a chain from an unrelated authority is refused', () async {
    final result = await health(
      TransportSecurity.provisioned(fixture('unrelated_ca.pem')),
    );

    expect(
      result,
      isA<FailureResult<HealthResponseDto>>()
          .having(
            (failure) => failure.failure,
            'failure',
            isA<TransportFailure>().having(
              (transport) => transport.kind,
              'kind',
              TransportFailureKind.trustRejected,
            ),
          )
          .having(
            (failure) => failure.failure,
            'is not reported as being offline',
            isNot(
              isA<TransportFailure>().having(
                (transport) => transport.kind,
                'kind',
                TransportFailureKind.offline,
              ),
            ),
          ),
    );
  });

  test('the public root store alone does not trust the private CA', () async {
    // The provisioned authority is private, so a client on platform default
    // trust must fail. If this ever passes, trust is coming from somewhere it
    // should not.
    final result = await health(const TransportSecurity.platformDefault());

    expect(result, isA<FailureResult<HealthResponseDto>>());
  });

  test('provisioned trust replaces the built-in roots rather than adding to '
      'them', () {
    final provisioned = TransportSecurity.provisioned(
      fixture('provisioned_ca.pem'),
    );

    expect(provisioned.isProvisioned, isTrue);
    expect(provisioned.httpClientAdapter, isNotNull);
    expect(const TransportSecurity.platformDefault().isProvisioned, isFalse);
    expect(
      const TransportSecurity.platformDefault().httpClientAdapter,
      isNull,
      reason: 'Default trust must leave Dio on its own adapter.',
    );
  });

  test('a handshake rejection is classified as a trust failure', () {
    final security = TransportSecurity.provisioned(
      fixture('provisioned_ca.pem'),
    );

    expect(
      security.isTrustFailure(const HandshakeException('refused')),
      isTrue,
    );
    expect(
      security.isTrustFailure(const SocketException('no route')),
      isFalse,
      reason: 'An unreachable host is not a trust decision.',
    );
  });

  test('the health port reports a refused chain as a trust failure', () async {
    final port = DioHealthReachabilityPort(
      transportSecurity: TransportSecurity.provisioned(
        fixture('unrelated_ca.pem'),
      ),
    );

    final result = await port.check(
      ProvisionedBootstrapConfiguration(
        serverOrigin: ServerOrigin.parse(origin.toString())!,
        trustMaterial: AndroidTrustMaterial(
          privateCaSha256: 'a' * 64,
          primarySpkiSha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          backupSpkiSha256: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
          certificateAuthority: fixture('unrelated_ca.pem'),
        ),
      ),
    );

    expect(
      result,
      isA<HealthTrustFailure>().having(
        (failure) => failure.reason,
        'reason',
        TrustFailureKind.privateCaRejected,
      ),
      reason:
          'Collapsing this into HealthUnreachable sends an operator looking at '
          'the network for what is a certificate problem.',
    );
  });

  test('the health port reports a trusted server as reachable', () async {
    final port = DioHealthReachabilityPort(
      transportSecurity: TransportSecurity.provisioned(
        fixture('provisioned_ca.pem'),
      ),
    );

    final result = await port.check(
      ProvisionedBootstrapConfiguration(
        serverOrigin: ServerOrigin.parse(origin.toString())!,
        trustMaterial: AndroidTrustMaterial(
          privateCaSha256: 'a' * 64,
          primarySpkiSha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          backupSpkiSha256: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
          certificateAuthority: fixture('provisioned_ca.pem'),
        ),
      ),
    );

    expect(result, isA<HealthReachable>());
  });
}
