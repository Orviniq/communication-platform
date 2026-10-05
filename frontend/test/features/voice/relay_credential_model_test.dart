import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/relay_fakes.dart';

void main() {
  final mintedAt = DateTime.utc(2026, 9, 30, 12);

  RelayCredential credential({
    List<String> urls = relayUrls,
    Duration lifetime = const Duration(hours: 6),
  }) => RelayCredential(
    urls: urls,
    username: relayUsername,
    credential: relayPassword,
    lifetime: lifetime,
    expiresAt: mintedAt.add(lifetime),
  );

  group('the ICE configuration', () {
    test('holds one relay server for each URL, and nothing else', () {
      final configuration = credential().iceConfiguration;

      expect(configuration.transportPolicy, IceTransportPolicy.relay);
      expect(IceTransportPolicy.values, [IceTransportPolicy.relay]);
      expect(configuration.servers.map((server) => server.url), relayUrls);
      for (final server in configuration.servers) {
        expect(server.url, startsWith('turn:'));
        expect(server.url, isNot(contains('stun')));
        expect(server.username, relayUsername);
        expect(server.credential, relayPassword);
      }
    });

    test('keeps the operator order, and cannot be added to', () {
      final configuration = credential(
        urls: const [
          'turn:chat.orviniq.com:3478?transport=tcp',
          'turn:198.51.100.10:3478',
        ],
      ).iceConfiguration;

      expect(configuration.servers.map((server) => server.url), const [
        'turn:chat.orviniq.com:3478?transport=tcp',
        'turn:198.51.100.10:3478',
      ]);
      expect(
        () => configuration.servers.add(configuration.servers.first),
        throwsUnsupportedError,
      );
    });

    test('cannot be built around a STUN server or any other server', () {
      // The configuration is built only from a credential, and a credential
      // is built only from relay URLs, however it is constructed.
      for (final urls in const [
        <String>[],
        ['stun:chat.orviniq.com:3478'],
        ['turn:chat.orviniq.com:3478', 'stun:stun.l.google.com:19302'],
        ['turns:chat.orviniq.com:5349'],
      ]) {
        expect(() => credential(urls: urls), throwsArgumentError);
      }
    });

    test('a credential cannot drift from the URLs it was built with', () {
      final urls = List.of(relayUrls);
      final built = credential(urls: urls);

      urls.add('stun:chat.orviniq.com:3478');

      expect(built.urls, relayUrls);
      expect(built.iceConfiguration.servers, hasLength(2));
      expect(() => built.urls.add(relayUrls.first), throwsUnsupportedError);
    });

    test('a credential needs a user name, a password and a lifetime', () {
      expect(
        () => RelayCredential(
          urls: relayUrls,
          username: '',
          credential: relayPassword,
          lifetime: const Duration(hours: 6),
          expiresAt: mintedAt,
        ),
        throwsArgumentError,
      );
      expect(
        () => RelayCredential(
          urls: relayUrls,
          username: relayUsername,
          credential: '',
          lifetime: const Duration(hours: 6),
          expiresAt: mintedAt,
        ),
        throwsArgumentError,
      );
      expect(
        () => RelayCredential(
          urls: relayUrls,
          username: relayUsername,
          credential: relayPassword,
          lifetime: Duration.zero,
          expiresAt: mintedAt,
        ),
        throwsArgumentError,
      );
    });
  });

  group('the lifetime rule', () {
    test('a refresh starts once less than an hour is left, and not before', () {
      final held = credential();
      final oneHourLeft = held.expiresAt.subtract(const Duration(hours: 1));

      expect(held.refreshDueAt, oneHourLeft);
      expect(held.isRefreshDueAt(mintedAt), isFalse);
      expect(held.isRefreshDueAt(oneHourLeft), isFalse);
      expect(
        held.isRefreshDueAt(oneHourLeft.add(const Duration(milliseconds: 1))),
        isTrue,
      );
      expect(held.isRefreshDueAt(held.expiresAt), isTrue);
      expect(
        held.isRefreshDueAt(held.expiresAt.add(const Duration(hours: 1))),
        isTrue,
      );
    });

    test('from two hours up, the margin is the contract hour exactly', () {
      for (final hours in const [2, 3, 6, 24]) {
        final held = credential(lifetime: Duration(hours: hours));

        expect(
          held.refreshDueAt,
          held.expiresAt.subtract(const Duration(hours: 1)),
          reason: '$hours hours',
        );
      }
    });

    test(
      'a lifetime under two hours refreshes at half-life, never at birth',
      () {
        // An operator may set any lifetime. Under the contract hour alone, a
        // credential good for an hour or less would be due the moment it was
        // minted, and so would every one minted to replace it.
        for (final lifetime in const [
          Duration(minutes: 30),
          Duration(hours: 1),
          Duration(hours: 1, seconds: 1),
          Duration(minutes: 90),
        ]) {
          final held = credential(lifetime: lifetime);
          final halfLife = mintedAt.add(lifetime ~/ 2);

          expect(held.refreshDueAt, halfLife, reason: '$lifetime');
          expect(held.isRefreshDueAt(mintedAt), isFalse, reason: '$lifetime');
          expect(held.isRefreshDueAt(halfLife), isFalse, reason: '$lifetime');
          expect(
            held.isRefreshDueAt(halfLife.add(const Duration(seconds: 1))),
            isTrue,
            reason: '$lifetime',
          );
        }
      },
    );
  });
}
