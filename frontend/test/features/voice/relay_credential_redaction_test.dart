import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/infrastructure/dio_relay_credential_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/relay_credential_api_dtos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/relay_fakes.dart';

/// The user name and the password open the relay to whoever holds them, so
/// neither may reach a log line, a diagnostic, or a string form that a log
/// line could be built from.
void main() {
  test(
    'no log line or diagnostic holds the user name or the password',
    () async {
      final printed = <String>[];
      final diagnostics = CapturingDiagnostics();
      final outcomes = <RelayCredentialOutcome>[];
      final adapter = RelayAdapter([
        relayJson(200, relayBody()),
        relayJson(200, relayBody()),
        relayJson(
          429,
          {'code': 'throttled', 'detail': 'Request was throttled.'},
          headers: {
            'retry-after': ['5'],
          },
        ),
        // Refused for its URL, while carrying a live-looking pair.
        relayJson(200, relayBody()..['urls'] = ['stun:chat.orviniq.com:3478']),
        relayJson(503, {
          'code': 'voice_unconfigured',
          'detail': 'This deployment serves no voice relay.',
        }),
      ]);

      // Restored inside the body: a foundation debug variable must not outlive
      // the test. `debugPrint` is where a stray print, an assertion message and
      // a framework error dump all come out, and the zone catches `print`.
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) {
          printed.add(message);
        }
      };
      try {
        await runZoned(
          () async {
            final clock = MutableClock(DateTime.utc(2026, 9, 30, 12));
            final service = RelayCredentialService(
              remote: DioRelayCredentialRepository(
                relayRestClient(adapter, diagnostics: diagnostics),
                clock: clock,
              ),
              deployment: const FixedVoiceDeployment(voiceConfigured: true),
              clock: clock,
            );
            const pastTheMargin = Duration(hours: 5, seconds: 1);

            outcomes.add(await service.fetchForJoin());
            clock.advance(pastTheMargin);
            outcomes.add(await service.refreshIfDue());
            clock.advance(pastTheMargin);
            outcomes.add(await service.refreshIfDue());
            clock.advance(const Duration(seconds: 10));
            outcomes.add(await service.refreshIfDue());
            outcomes.add(await service.fetchForJoin());
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        );
      } finally {
        debugPrint = original;
      }

      // Every path was taken, once, and nothing was replayed.
      expect(outcomes.map((outcome) => outcome.runtimeType), const [
        RelayCredentialMinted,
        RelayCredentialMinted,
        RelayMintThrottled,
        RelayMintFailed,
        VoiceUnavailable,
      ]);
      expect(adapter.requests, hasLength(5));
      expect(diagnostics.events.map((event) => event.statusCode), const [
        200,
        200,
        429,
        200,
        503,
      ]);

      final credential = (outcomes.first as RelayCredentialMinted).credential;
      final configuration = credential.iceConfiguration;
      final written = <String>[
        ...printed,
        ...diagnostics.events.map(formatRedactedDiagnostic),
        for (final outcome in outcomes) outcome.toString(),
        for (final outcome in outcomes)
          if (outcome is RelayMintFailed) outcome.failure.toString(),
        credential.toString(),
        configuration.toString(),
        configuration.servers.toString(),
        for (final server in configuration.servers) server.toString(),
        Result.success(credential).toString(),
        RelayCredentialResponseDto.fromJson(relayBody()).toString(),
      ];
      for (final text in written) {
        expect(text, isNot(contains(relayUsername)));
        expect(text, isNot(contains(relayPassword)));
      }
    },
  );

  test('a refused credential does not echo what it refused', () {
    // A URL can be refused while a live pair sits beside it, and an error is
    // text that ends up in a log.
    for (final build in <void Function()>[
      () => RelayCredential(
        urls: const ['stun:chat.orviniq.com:3478'],
        username: relayUsername,
        credential: relayPassword,
        lifetime: const Duration(hours: 6),
        expiresAt: DateTime.utc(2026, 9, 30, 18),
      ),
      () => RelayCredential(
        urls: relayUrls,
        username: relayUsername,
        credential: relayPassword,
        lifetime: Duration.zero,
        expiresAt: DateTime.utc(2026, 9, 30, 18),
      ),
    ]) {
      expect(
        build,
        throwsA(
          isA<ArgumentError>()
              .having(
                (error) => error.toString(),
                'text',
                isNot(contains(relayPassword)),
              )
              .having(
                (error) => error.toString(),
                'text',
                isNot(contains(relayUsername)),
              ),
        ),
      );
    }
  });
}
