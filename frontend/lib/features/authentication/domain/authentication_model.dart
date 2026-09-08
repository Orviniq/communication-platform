/// Local validation is only an immediate-feedback aid. The backend remains
/// authoritative and can reject any submitted value.
abstract final class AuthenticationInputPolicy {
  static final RegExp _usernamePattern = RegExp(r'^[a-z0-9_]{3,32}$');

  static String normalizeUsername(String value) => value.trim().toLowerCase();

  static bool isUsernameValid(String value) =>
      _usernamePattern.hasMatch(normalizeUsername(value));

  static bool isPasswordValid(String value) =>
      value.length >= 10 && value.length <= 256;
}

enum AccountSessionScope { register, full }

/// A successful registration contains no credential and no activation status.
final class AccountRegistration {
  const AccountRegistration({required this.userId});

  final String userId;
}

/// Secret-bearing grant used only between the repository and session adapter.
///
/// Passwords are never retained here. This type deliberately has no custom string
/// representation so credentials cannot be accidentally formatted for UI or logs.
final class AccountSessionGrant {
  const AccountSessionGrant({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.userId,
    required this.scope,
    this.deviceId,
  });

  final String accessToken;
  final DateTime accessExpiresAt;
  final String userId;
  final String? deviceId;
  final AccountSessionScope scope;
}

final class LoginHint {
  const LoginHint({this.username, this.deviceId});

  final String? username;
  final String? deviceId;

  bool appliesTo(String normalizedUsername) =>
      deviceId != null &&
      username != null &&
      AuthenticationInputPolicy.normalizeUsername(username!) ==
          normalizedUsername;
}

final class AccountSessionBoundary {
  const AccountSessionBoundary({
    required this.userId,
    required this.scope,
    required this.offline,
    this.securitySetupComplete = true,
    this.deviceId,
  });

  final String userId;
  final String? deviceId;
  final AccountSessionScope scope;
  final bool offline;
  final bool securitySetupComplete;
}
