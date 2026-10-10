@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/attachment_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/networking_foundation.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_descriptor_fixture.dart';

/// ADR-089 D12: the attachment transport runs on the provisioned trust and the
/// one token coordinator, and nothing builds it on any other.
///
/// The trust is proved against a real local TLS server, as
/// `transport_security_test.dart` proves it for the REST client: a mocked
/// adapter could not show that the chain is checked against the provisioned
/// authority and nothing else.
///
/// No test binding is initialised in this file: it would replace every
/// `HttpClient` in the isolate with one that answers 400, and the TLS server
/// would never be reached. `attachment_cache_root_test.dart` holds the test
/// that needs the binding's mocked channel.
void main() {
  const scope = (
    userId: '11111111-1111-4111-8111-111111111111',
    deviceId: '22222222-2222-4222-8222-222222222222',
  );
  final capability = testCapability(3);
  late HttpServer server;
  late Uri origin;
  late List<({String path, String? authorization})> requests;
  late bool redirect;
  late Directory temporary;
  late Directory root;

  Uint8List fixture(String name) =>
      File('test/fixtures/tls/$name').readAsBytesSync();

  setUp(() async {
    requests = [];
    redirect = false;
    temporary = await Directory.systemTemp.createTemp('cp_attachment_wiring_');
    root = await Directory(
      '${temporary.path}${Platform.pathSeparator}$privateAttachmentCacheName',
    ).create();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChainBytes(fixture('server_chain.pem'))
        ..usePrivateKeyBytes(fixture('server_key.pem')),
    );
    origin = Uri.parse('https://localhost:${server.port}');
    unawaited(
      server.forEach((request) {
        requests.add((
          path: request.uri.path,
          authorization: request.headers.value('authorization'),
        ));
        final response = request.response;
        if (redirect) {
          response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '$origin/elsewhere');
        } else {
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..add(Uint8List(65536));
        }
        unawaited(response.close());
      }),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  NetworkingFoundation foundation(TransportSecurity security) =>
      NetworkingFoundation.create(
        serverOrigin: origin,
        tokenStore: _FullSession(),
        terminationHandler: const _NoTermination(),
        timeSource: const SystemTimeSource(),
        transportSecurity: security,
      );

  AttachmentTransportPort transportOf(NetworkingFoundation networking) =>
      networking.attachmentTransport(
        config: const FixedServerConfig.fallback(),
        allowance: const _EmptyAllowance(),
        clock: const SystemTimeSource(),
        storage: PrivateAttachmentStorage(root: root),
      );

  Future<Result<File>> download(AttachmentTransportPort transport) =>
      transport.download(capabilityId: capability, expectedBucketSize: 65536);

  group('the foundation builds the transport', () {
    test('on the provisioned trust and the one token coordinator', () async {
      final networking = foundation(
        TransportSecurity.provisioned(fixture('provisioned_ca.pem')),
      );
      final transport = networking.attachmentTransport(
        config: const FixedServerConfig.fallback(),
        allowance: const _EmptyAllowance(),
        clock: const SystemTimeSource(),
        storage: PrivateAttachmentStorage(root: root),
      );

      expect(identical(transport.tokens, networking.tokenCoordinator), isTrue);
      final fetched = await download(transport);

      expect(await (fetched as Success<File>).value.length(), 65536);
      expect(requests, [
        (
          path: '/api/v1/attachments/$capability',
          authorization: 'Bearer ${_FullSession.token}',
        ),
      ]);
    });

    test('and its chain must end at the provisioned authority', () async {
      final transport = transportOf(
        foundation(TransportSecurity.provisioned(fixture('unrelated_ca.pem'))),
      );

      expect(
        (await download(transport) as FailureResult<File>).failure,
        isA<TransportFailure>(),
      );
      expect(requests, isEmpty);
    });

    test('and it follows no redirect', () async {
      redirect = true;
      final transport = transportOf(
        foundation(
          TransportSecurity.provisioned(fixture('provisioned_ca.pem')),
        ),
      );

      expect(await download(transport), isA<FailureResult<File>>());
      expect(requests.map((request) => request.path), [
        '/api/v1/attachments/$capability',
      ]);
    });

    test('never on the platform default trust', () {
      expect(
        () =>
            transportOf(foundation(const TransportSecurity.platformDefault())),
        throwsStateError,
      );
    });
  });

  test('DioAttachmentTransport cannot be built without a Dio, and only the '
      'foundation builds one', () {
    final transport = File(
      'lib/features/attachments/infrastructure/attachment_transport.dart',
    ).readAsStringSync();
    expect(transport, contains('required Dio dio,'));
    expect(transport, isNot(contains('Dio? dio')));
    expect(transport, isNot(contains('Dio(')));

    expect('DioAttachmentTransport('.allMatches(transport), hasLength(1));
    expect(transport, contains('  DioAttachmentTransport({'));
    final builders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      final path = entity.path.replaceAll(r'\', '/');
      if (entity is File &&
          path.endsWith('.dart') &&
          !path.endsWith('/attachment_transport.dart') &&
          entity.readAsStringSync().contains('DioAttachmentTransport(')) {
        builders.add(path);
      }
    }
    expect(builders, ['lib/app/dependencies/networking_foundation.dart']);
  });

  group('the providers', () {
    late LocalDatabase database;

    setUp(() => database = LocalDatabase(NativeDatabase.memory()));
    tearDown(() => database.close());

    List<Override> base() => [
      localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      serverConfigSnapshotProvider.overrideWithValue(
        const FixedServerConfig.fallback(),
      ),
      attachmentCacheRootProvider.overrideWith((ref) => Future.value(root)),
    ];

    test(
      'a runtime with no networking foundation composes no transport',
      () async {
        final container = ProviderContainer.test(overrides: base());

        await expectLater(
          container.read(attachmentTransportProvider(scope).future),
          _notAvailable,
        );
        await expectLater(
          container.read(attachmentTransferServiceProvider(scope).future),
          _notAvailable,
        );
        expect(
          () => container.read(networkingFoundationProvider),
          _notAvailable,
        );
      },
    );

    test('the end of the session ends the transport with it', () async {
      final container = ProviderContainer.test(
        overrides: [
          ...base(),
          networkingFoundationProvider.overrideWithValue(
            foundation(
              TransportSecurity.provisioned(fixture('provisioned_ca.pem')),
            ),
          ),
          attachmentSessionActiveProvider(
            scope,
          ).overrideWith((ref) => ref.watch(_sessionProvider)),
        ],
      );

      final transport = await container.read(
        attachmentTransportProvider(scope).future,
      );
      final service = await container.read(
        attachmentTransferServiceProvider(scope).future,
      );
      expect(identical(service.transport, transport), isTrue);
      expect(await download(transport), isA<Success<File>>());

      container.read(_sessionProvider.notifier).end();

      await expectLater(
        container.read(attachmentTransportProvider(scope).future),
        _notAvailable,
      );
      expect(
        (await download(transport) as FailureResult<File>).failure,
        isA<CancellationFailure>().having(
          (failure) => failure.kind,
          'kind',
          CancellationFailureKind.lifecycleInterrupted,
        ),
      );
      expect(requests, hasLength(1));
    });

    test('the sweep messaging asks for deletes a file no row names', () async {
      final unnamed = File(
        [
          root.path,
          'plain',
          'abababababababababababababababab',
          'gone.pdf',
        ].join(Platform.pathSeparator),
      );
      await unnamed.parent.create(recursive: true);
      await unnamed.writeAsString('plaintext');
      final container = ProviderContainer.test(overrides: base());

      await container.read(attachmentSweepProvider).sweepAfterDeletion();

      expect(await unnamed.parent.exists(), isFalse);
      final manage = await container.read(
        manageLocalConversationStateProvider.future,
      );
      expect(manage.attachments, same(container.read(attachmentSweepProvider)));
    });
  });
}

/// A provider that cannot be built: its own `StateError`, or a dependency's,
/// which Riverpod 3 hands on inside a [ProviderException].
final _notAvailable = throwsA(
  anyOf(
    isA<StateError>(),
    isA<ProviderException>().having(
      (error) => error.exception,
      'exception',
      isA<StateError>(),
    ),
  ),
);

final _sessionProvider = NotifierProvider<_Session, bool>(_Session.new);

final class _Session extends Notifier<bool> {
  @override
  bool build() => true;

  void end() => state = false;
}

final class _FullSession implements SessionTokenStore {
  static const token = 'attachment-session-token';

  @override
  Future<SessionTokens?> read() async => SessionTokens(
    accessToken: AccessToken(
      value: token,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      scope: SessionScope.full,
      // Just issued, so the coordinator has no reason to renew it first.
      lifetime: const Duration(days: 1),
    ),
  );

  @override
  Future<void> replace(SessionTokens tokens) async {}

  @override
  Future<void> clear() async {}
}

final class _NoTermination implements SessionTerminationHandler {
  const _NoTermination();

  @override
  Future<void> terminate(SessionTerminationReason reason) async {}
}

final class _EmptyAllowance implements AttachmentAllowancePort {
  const _EmptyAllowance();

  @override
  Future<AttachmentDailyAllowance> read(DateTime now) async =>
      AttachmentDailyAllowance.empty(now);

  @override
  Future<void> record({required int bytes, required DateTime now}) async {}
}
