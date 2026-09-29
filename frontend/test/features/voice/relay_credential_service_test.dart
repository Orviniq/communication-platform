import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/infrastructure/dio_relay_credential_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/published_voice_deployment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/relay_fakes.dart';

/// The lifetime rule and the two answers that stop the client asking,
/// through the real repository and the reviewed REST client: what is counted
/// is requests that reached the wire.
void main() {
  final t0 = DateTime.utc(2026, 9, 30, 12);
  late MutableClock clock;

  setUp(() => clock = MutableClock(t0));

  RelayCredentialService serviceOn(
    RelayAdapter adapter, {
    VoiceDeploymentPort deployment = const FixedVoiceDeployment(
      voiceConfigured: true,
    ),
  }) => RelayCredentialService(
    remote: DioRelayCredentialRepository(
      relayRestClient(adapter),
      clock: clock,
    ),
    deployment: deployment,
    clock: clock,
  );

  RelayHandler throttled({String? retryAfter}) => relayJson(
    429,
    {'code': 'throttled', 'detail': 'Request was throttled.'},
    headers: {
      if (retryAfter != null) 'retry-after': [retryAfter],
    },
  );

  RelayHandler voiceUnconfigured() => relayJson(503, {
    'code': 'voice_unconfigured',
    'detail': 'This deployment serves no voice relay.',
  });

  group('the gate', () {
    test(
      'voiceConfigured false fetches nothing and reports voice unavailable',
      () async {
        final adapter = RelayAdapter([relayJson(200, relayBody())]);
        final service = serviceOn(
          adapter,
          deployment: const FixedVoiceDeployment(voiceConfigured: false),
        );

        expect(service.isVoiceAvailable, isFalse);
        expect(await service.fetchForJoin(), isA<VoiceUnavailable>());
        expect(await service.refreshIfDue(), isA<VoiceUnavailable>());
        expect(service.refreshDueAt, isNull);
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'until the deployment has said so, the fallback offers no voice',
      () async {
        // What the client runs on before `GET /api/v1/config` answers.
        final adapter = RelayAdapter([relayJson(200, relayBody())]);
        final gated = serviceOn(
          adapter,
          deployment: const PublishedVoiceDeployment(
            FixedServerConfig.fallback(),
          ),
        );

        expect(await gated.fetchForJoin(), isA<VoiceUnavailable>());
        expect(adapter.requests, isEmpty);

        final open = serviceOn(
          adapter,
          deployment: PublishedVoiceDeployment(
            FixedServerConfig(withVoice(ServerConfig.fallback)),
          ),
        );

        expect(open.isVoiceAvailable, isTrue);
        expect(await open.fetchForJoin(), isA<RelayCredentialMinted>());
        expect(adapter.requests, hasLength(1));
      },
    );

    test('a 503 voice_unconfigured is not retried, now or later', () async {
      final adapter = RelayAdapter([
        voiceUnconfigured(),
        relayJson(200, relayBody()),
        relayJson(200, relayBody()),
      ]);
      final service = serviceOn(adapter);

      expect(service.isVoiceAvailable, isTrue);
      expect(await service.fetchForJoin(), isA<VoiceUnavailable>());
      expect(adapter.requests, hasLength(1));

      // It is the same state as `voice_configured: false`, and it holds: the
      // relay list is empty, and no amount of asking fills it.
      expect(service.isVoiceAvailable, isFalse);
      clock.advance(const Duration(days: 1));
      expect(await service.fetchForJoin(), isA<VoiceUnavailable>());
      expect(await service.refreshIfDue(), isA<VoiceUnavailable>());
      expect(adapter.requests, hasLength(1));
    });
  });

  group('the lifetime rule', () {
    test('a join mints once, and holds what it minted', () async {
      final adapter = RelayAdapter([relayJson(200, relayBody())]);
      final service = serviceOn(adapter);

      final joined = await service.fetchForJoin();

      final credential = (joined as RelayCredentialMinted).credential;
      expect(credential.expiresAt, t0.add(const Duration(hours: 6)));
      expect(service.refreshDueAt, t0.add(const Duration(hours: 5)));
      expect(adapter.requests, hasLength(1));
    });

    test('every join mints, even over a credential still held', () async {
      final adapter = RelayAdapter([
        relayJson(200, relayBody()),
        relayJson(200, relayBody()),
      ]);
      final service = serviceOn(adapter);

      final first = await service.fetchForJoin();
      clock.advance(const Duration(minutes: 10));
      final second = await service.fetchForJoin();

      expect(adapter.requests, hasLength(2));
      expect(
        (second as RelayCredentialMinted).credential,
        isNot(same((first as RelayCredentialMinted).credential)),
      );
      expect(
        service.refreshDueAt,
        t0.add(const Duration(hours: 5, minutes: 10)),
      );
    });

    test(
      'the refresh starts when less than one hour is left, and not before',
      () async {
        final adapter = RelayAdapter([
          relayJson(200, relayBody()),
          relayJson(200, relayBody()),
        ]);
        final service = serviceOn(adapter);
        final joined =
            (await service.fetchForJoin() as RelayCredentialMinted).credential;

        // Five hours in, exactly one hour of six is left: not less than one.
        clock.advance(const Duration(hours: 5));
        final notYet = await service.refreshIfDue();

        expect(notYet, isA<RelayCredentialHeld>());
        expect((notYet as RelayCredentialHeld).credential, same(joined));
        expect(adapter.requests, hasLength(1));

        // One second later, less than an hour is left.
        clock.advance(const Duration(seconds: 1));
        final refreshed = await service.refreshIfDue();

        expect(refreshed, isA<RelayCredentialMinted>());
        expect(
          (refreshed as RelayCredentialMinted).credential,
          isNot(same(joined)),
        );
        expect(adapter.requests, hasLength(2));
        expect(
          service.refreshDueAt,
          t0.add(const Duration(hours: 10, seconds: 1)),
        );
        expect(await service.refreshIfDue(), isA<RelayCredentialHeld>());
        expect(adapter.requests, hasLength(2));
      },
    );

    test('release forgets the credential, and holding none is due', () async {
      final adapter = RelayAdapter([
        relayJson(200, relayBody()),
        relayJson(200, relayBody()),
      ]);
      final service = serviceOn(adapter);
      await service.fetchForJoin();

      service.release();

      expect(service.refreshDueAt, isNull);
      expect(await service.refreshIfDue(), isA<RelayCredentialMinted>());
      expect(adapter.requests, hasLength(2));
    });

    test('a mint still in flight when the call ends is not kept', () async {
      final port = _PendingPort();
      final service = RelayCredentialService(
        remote: port,
        deployment: const FixedVoiceDeployment(voiceConfigured: true),
        clock: clock,
      );

      final joining = service.fetchForJoin();
      service.release();
      port.answer(Result.success(_credential(t0)));

      expect(await joining, isA<RelayCredentialMinted>());
      expect(service.refreshDueAt, isNull);
    });
  });

  group('a 429', () {
    test('waits for Retry-After before anything is asked again', () async {
      final adapter = RelayAdapter([
        throttled(retryAfter: '30'),
        relayJson(200, relayBody()),
      ]);
      final service = serviceOn(adapter);
      final retryAt = t0.add(const Duration(seconds: 30));

      final first = await service.fetchForJoin();

      expect(first, isA<RelayMintThrottled>());
      expect((first as RelayMintThrottled).retryAt, retryAt);
      expect(service.isVoiceAvailable, isTrue);
      expect(adapter.requests, hasLength(1));

      clock.advance(const Duration(seconds: 29));
      final cooling = await service.fetchForJoin();
      final refresh = await service.refreshIfDue();

      expect((cooling as RelayMintThrottled).retryAt, retryAt);
      expect((refresh as RelayMintThrottled).retryAt, retryAt);
      expect(adapter.requests, hasLength(1));

      clock.advance(const Duration(seconds: 1));
      expect(await service.fetchForJoin(), isA<RelayCredentialMinted>());
      expect(adapter.requests, hasLength(2));
    });

    test(
      'with no usable Retry-After cools down for the minute the scope counts',
      () async {
        final adapter = RelayAdapter([
          throttled(),
          relayJson(200, relayBody()),
        ]);
        final service = serviceOn(adapter);

        final first = await service.fetchForJoin();

        expect(
          (first as RelayMintThrottled).retryAt,
          t0.add(RelayCredentialService.throttleFallback),
        );
        expect(
          RelayCredentialService.throttleFallback,
          const Duration(minutes: 1),
        );

        clock.advance(const Duration(seconds: 59));
        expect(await service.fetchForJoin(), isA<RelayMintThrottled>());
        expect(adapter.requests, hasLength(1));

        clock.advance(const Duration(seconds: 1));
        expect(await service.fetchForJoin(), isA<RelayCredentialMinted>());
        expect(adapter.requests, hasLength(2));
      },
    );

    test('on a refresh keeps the held credential in force', () async {
      final adapter = RelayAdapter([
        relayJson(200, relayBody()),
        throttled(retryAfter: '30'),
        relayJson(200, relayBody()),
      ]);
      final service = serviceOn(adapter);
      await service.fetchForJoin();
      final dueAt = service.refreshDueAt!;

      clock.current = dueAt.add(const Duration(seconds: 1));
      final throttledRefresh = await service.refreshIfDue();

      expect(throttledRefresh, isA<RelayMintThrottled>());
      expect(service.refreshDueAt, dueAt);

      clock.advance(const Duration(seconds: 30));
      expect(await service.refreshIfDue(), isA<RelayCredentialMinted>());
      expect(adapter.requests, hasLength(3));
    });
  });

  test('a failed mint holds nothing and bars nothing', () async {
    // The client replays a timeout once, so two timeouts are one failure.
    final adapter = RelayAdapter([
      relayTimeout(),
      relayTimeout(),
      relayJson(200, relayBody()),
    ]);
    final service = serviceOn(adapter);

    final failed = await service.fetchForJoin();

    expect(
      (failed as RelayMintFailed).failure,
      isA<TransportFailure>().having(
        (failure) => failure.kind,
        'kind',
        TransportFailureKind.timeout,
      ),
    );
    expect(service.refreshDueAt, isNull);
    expect(service.isVoiceAvailable, isTrue);

    expect(await service.fetchForJoin(), isA<RelayCredentialMinted>());
    expect(adapter.requests, hasLength(3));
  });
}

RelayCredential _credential(DateTime mintedAt) => RelayCredential(
  urls: relayUrls,
  username: relayUsername,
  credential: relayPassword,
  lifetime: const Duration(hours: 6),
  expiresAt: mintedAt.add(const Duration(hours: 6)),
);

/// A mint that answers when the test says so.
final class _PendingPort implements RelayCredentialPort {
  final _answer = Completer<Result<RelayCredential>>();

  void answer(Result<RelayCredential> result) => _answer.complete(result);

  @override
  Future<Result<RelayCredential>> mint() => _answer.future;
}
