import 'dart:convert';

import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/infrastructure/relay_credential_api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/relay_fakes.dart';

/// The `200` body of `POST /api/v1/me/relay`, and every way it can fail to be
/// one.
void main() {
  test('a full body parses, each field as the route states it', () {
    final parsed = RelayCredentialResponseDto.fromJson(relayBody());

    expect(parsed.urls, relayUrls);
    expect(parsed.username, relayUsername);
    expect(parsed.credential, relayPassword);
    expect(parsed.lifetime, const Duration(hours: 6));
  });

  test('the expiry is counted from the request, on this device', () {
    final requestedAt = DateTime.utc(2026, 9, 30, 12);

    final credential = RelayCredentialResponseDto.fromJson(
      relayBody(),
    ).toDomain(requestedAt: requestedAt);

    expect(credential.urls, relayUrls);
    expect(credential.username, relayUsername);
    expect(credential.credential, relayPassword);
    expect(credential.lifetime, const Duration(hours: 6));
    expect(credential.expiresAt, DateTime.utc(2026, 9, 30, 18));
  });

  test('the user name is passed through, and its timestamp is not read', () {
    // The name's own timestamp says the credential died in 2025. It is the
    // relay's to compare, not this client's: `expires_in` is what counts.
    final body = relayBody()
      ..['username'] = '1735689600:AAAAAAAAAAAAAAAAAAAAAA==';

    final credential = RelayCredentialResponseDto.fromJson(
      body,
    ).toDomain(requestedAt: DateTime.utc(2026, 9, 30, 12));

    expect(credential.username, '1735689600:AAAAAAAAAAAAAAAAAAAAAA==');
    expect(credential.expiresAt, DateTime.utc(2026, 9, 30, 18));
  });

  test('an unknown field is ignored rather than refused', () {
    final body = relayBody()..['realm'] = 'chat.orviniq.com';

    expect(RelayCredentialResponseDto.fromJson(body).username, relayUsername);
  });

  group('a malformed body is refused', () {
    Map<String, Object?> without(String field) => relayBody()..remove(field);
    Map<String, Object?> replacing(String field, Object? value) =>
        relayBody()..[field] = value;

    final cases = <String, Object?>{
      'no body at all': null,
      'a list instead of an object': [relayBody()],
      'a string instead of an object': 'turn:chat.orviniq.com:3478',
      'no urls': without('urls'),
      'no username': without('username'),
      'no credential': without('credential'),
      'no expires_in': without('expires_in'),
      'urls as a string': replacing('urls', relayUrls.first),
      'urls as an object': replacing('urls', {'0': relayUrls.first}),
      'a url that is not a string': replacing('urls', [relayUrls.first, 3478]),
      'a null url': replacing('urls', [null]),
      'an empty urls list': replacing('urls', const <String>[]),
      'more urls than any deployment names': replacing(
        'urls',
        List.filled(RelayCredentialResponseDto.maxRelayUrls + 1, relayUrls[0]),
      ),
      'a username that is not a string': replacing('username', 1757352000),
      'an empty username': replacing('username', ''),
      'a null username': replacing('username', null),
      'a credential that is not a string': replacing('credential', ['x']),
      'an empty credential': replacing('credential', ''),
      'expires_in as a string': replacing('expires_in', '21600'),
      'expires_in as a fraction': replacing('expires_in', 21600.5),
      'expires_in of zero': replacing('expires_in', 0),
      'a negative expires_in': replacing('expires_in', -1),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          () => RelayCredentialResponseDto.fromJson(entry.value),
          throwsA(isA<MalformedApiBody>()),
        );
      });
    }

    test('the most urls a body may carry is accepted', () {
      final body = replacing(
        'urls',
        List.filled(RelayCredentialResponseDto.maxRelayUrls, relayUrls[0]),
      );

      expect(
        RelayCredentialResponseDto.fromJson(body).urls,
        hasLength(RelayCredentialResponseDto.maxRelayUrls),
      );
    });
  });

  group('a URL that is not a relay URL refuses the whole body', () {
    const refused = <String>[
      // STUN is exactly what §N rule 2 forbids, in either form.
      'stun:chat.orviniq.com:3478',
      'stuns:chat.orviniq.com:5349',
      // The relay has no TLS listener, and nothing has decided how one would
      // be trusted.
      'turns:chat.orviniq.com:5349?transport=tcp',
      'TURN:chat.orviniq.com:3478',
      'https://chat.orviniq.com',
      'chat.orviniq.com:3478',
      'turn:',
      'turn://chat.orviniq.com:3478',
      'turn:user@chat.orviniq.com:3478',
      'turn:chat.orviniq.com:3478/path',
      'turn:chat.orviniq.com:3478#fragment',
      'turn:chat%2Eorviniq.com:3478',
      'turn:chat.orviniq.com:3478?transport=tls',
      'turn:chat.orviniq.com:3478?transport=UDP',
      'turn:chat.orviniq.com:3478?transport=udp&x=1',
      'turn:chat.orviniq.com:3478?',
      'turn:chat.orviniq.com:',
      'turn:chat.orviniq.com:0',
      'turn:chat.orviniq.com:65536',
      'turn:chat.orviniq.com:123456',
      'turn:chat..orviniq.com',
      'turn:-chat.orviniq.com',
      'turn:chat.orviniq.com.',
      'turn:2001:db8::1',
      'turn:[2001:db8::1',
      'turn: chat.orviniq.com',
      ' turn:chat.orviniq.com',
      'turn:chat.orviniq.com\n',
      '',
    ];
    for (final url in refused) {
      // Quoted and escaped, so that the three that differ only by white space
      // are three names.
      test(jsonEncode(url), () {
        expect(isRelayTurnUrl(url), isFalse);
        expect(
          () => RelayCredentialResponseDto.fromJson(
            relayBody()..['urls'] = [relayUrls.first, url],
          ),
          throwsA(isA<MalformedApiBody>()),
        );
      });
    }
  });

  test('every form the contract allows is accepted', () {
    const accepted = <String>[
      'turn:chat.orviniq.com',
      'turn:chat.orviniq.com:3478',
      'turn:chat.orviniq.com:3478?transport=udp',
      'turn:chat.orviniq.com:3478?transport=tcp',
      'turn:chat.orviniq.com?transport=tcp',
      'turn:relay-1.orviniq.com:65535',
      'turn:198.51.100.10:3478',
      'turn:[2001:db8::1]:3478?transport=udp',
      'turn:localhost:1',
    ];
    for (final url in accepted) {
      expect(isRelayTurnUrl(url), isTrue, reason: url);
    }

    expect(
      RelayCredentialResponseDto.fromJson(
        relayBody()..['urls'] = accepted,
      ).urls,
      accepted,
    );
  });
}
