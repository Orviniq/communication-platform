import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';

final class RegisterAccountRequestDto {
  const RegisterAccountRequestDto({
    required this.username,
    required this.password,
  });

  final String username;
  final String password;

  Map<String, Object?> toJson() => {'username': username, 'password': password};
}

final class RegisterAccountResponseDto {
  const RegisterAccountResponseDto._(this.userId);

  factory RegisterAccountResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final userId = json['user_id'];
    if (userId is! String || !_uuid.hasMatch(userId)) {
      throw const MalformedApiBody();
    }
    return RegisterAccountResponseDto._(userId);
  }

  final String userId;

  AccountRegistration toDomain() => AccountRegistration(userId: userId);
}

final class LoginAccountRequestDto {
  const LoginAccountRequestDto({
    required this.username,
    required this.password,
    this.deviceId,
  });

  final String username;
  final String password;
  final String? deviceId;

  Map<String, Object?> toJson() => {
    'username': username,
    'password': password,
    if (deviceId != null) 'device_id': deviceId,
  };
}

/// The two login success shapes, told apart by `scope`.
///
/// A `full` body names the live device the request asked for; a `register` body
/// names no device, because a session token is bound to one and this token's
/// only power is `POST /me/devices`.
final class LoginAccountResponseDto {
  const LoginAccountResponseDto._({
    required this.token,
    required this.expiresIn,
    required this.userId,
    required this.scope,
    this.deviceId,
  });

  factory LoginAccountResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final token = json['token'];
    final userId = json['user_id'];
    final scope = json['scope'];
    if (token is! String ||
        token.isEmpty ||
        userId is! String ||
        !_uuid.hasMatch(userId) ||
        scope is! String) {
      throw const MalformedApiBody();
    }

    final expiresIn = readExpiresIn(json['expires_in']);
    switch (scope) {
      case 'register':
        if (json['device_id'] != null) {
          throw const MalformedApiBody();
        }
        return LoginAccountResponseDto._(
          token: token,
          expiresIn: expiresIn,
          userId: userId,
          scope: AccountSessionScope.register,
        );
      case 'full':
        final deviceId = json['device_id'];
        if (deviceId is! String || !_uuid.hasMatch(deviceId)) {
          throw const MalformedApiBody();
        }
        return LoginAccountResponseDto._(
          token: token,
          expiresIn: expiresIn,
          userId: userId,
          deviceId: deviceId,
          scope: AccountSessionScope.full,
        );
      default:
        throw const MalformedApiBody();
    }
  }

  final String token;
  final Duration expiresIn;
  final String userId;
  final String? deviceId;
  final AccountSessionScope scope;

  /// [receivedAt] anchors [expiresIn], which the server states relative to the
  /// moment it issued the token.
  AccountSessionGrant toDomain({DateTime? receivedAt}) => AccountSessionGrant(
    accessToken: token,
    accessExpiresAt: (receivedAt ?? DateTime.now()).toUtc().add(expiresIn),
    userId: userId,
    deviceId: deviceId,
    scope: scope,
  );
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
