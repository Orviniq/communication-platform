import 'dart:convert';

import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/authentication_api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('login response DTO', () {
    test('a body carrying token and expires_in parses in both scopes', () {
      final receivedAt = DateTime.utc(2026, 9, 8, 12);

      final register = LoginAccountResponseDto.fromJson({
        'token': _jwt(2000000000),
        'expires_in': 600,
        'user_id': userId,
        'scope': 'register',
      }).toDomain(receivedAt: receivedAt);

      expect(register.scope, AccountSessionScope.register);
      expect(register.accessToken, _jwt(2000000000));
      expect(register.userId, userId);
      // A register token names no device, because a session token is bound to
      // one and this token's only power is `POST /me/devices`.
      expect(register.deviceId, isNull);
      expect(
        register.accessExpiresAt,
        receivedAt.add(const Duration(minutes: 10)),
      );

      final full = LoginAccountResponseDto.fromJson({
        'token': _jwt(2000000001),
        'expires_in': 2592000,
        'user_id': userId,
        'device_id': deviceId,
        'scope': 'full',
      }).toDomain(receivedAt: receivedAt);

      expect(full.scope, AccountSessionScope.full);
      expect(full.accessToken, _jwt(2000000001));
      expect(full.deviceId, deviceId);
      // The lifetime is stated relative to the moment the server issued the
      // token, not decoded out of the claims.
      expect(full.accessExpiresAt, receivedAt.add(const Duration(days: 30)));
    });

    test('a body naming access instead of token is refused', () {
      // `access` and its `refresh` companion were the retired pair. The server
      // answers neither field now, so a body that carries one is not this
      // server's answer and nothing about it may be salvaged — not the token
      // hiding in `access`, and not the account it names.
      expect(
        () => LoginAccountResponseDto.fromJson({
          'access': _jwt(2000000000),
          'refresh': _jwt(2000000100),
          'user_id': userId,
          'device_id': deviceId,
          'scope': 'full',
        }),
        throwsA(isA<MalformedApiBody>()),
      );

      // The same body with the token field the contract does name parses, so
      // the refusal above is about the field and not about anything else in it.
      expect(
        LoginAccountResponseDto.fromJson({
          'token': _jwt(2000000000),
          'expires_in': 2592000,
          'user_id': userId,
          'device_id': deviceId,
          'scope': 'full',
        }).token,
        _jwt(2000000000),
      );
    });

    test('a full body still needs the device the token is bound to', () {
      expect(
        () => LoginAccountResponseDto.fromJson({
          'token': _jwt(2000000000),
          'expires_in': 2592000,
          'user_id': userId,
          'scope': 'full',
        }),
        throwsA(isA<MalformedApiBody>()),
      );
      // And a register body must not name one, for the same reason.
      expect(
        () => LoginAccountResponseDto.fromJson({
          'token': _jwt(2000000000),
          'expires_in': 600,
          'user_id': userId,
          'device_id': deviceId,
          'scope': 'register',
        }),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('a lifetime the contract cannot state fails closed', () {
      for (final expiresIn in const <Object?>[null, 0, -1, '600', 600.0]) {
        expect(
          () => LoginAccountResponseDto.fromJson({
            'token': _jwt(2000000000),
            'expires_in': expiresIn,
            'user_id': userId,
            'scope': 'register',
          }),
          throwsA(isA<MalformedApiBody>()),
          reason: 'expires_in: $expiresIn',
        );
      }
    });
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

String _jwt(int expiry) {
  final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiry})))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}
