/// Authentication scope carried by the login body beside the session token.
///
/// The server no longer puts `scope` in the token claims (ADR-0023). It is the
/// discriminator between the two login success shapes and nothing more.
enum SessionScope { register, full }

/// Secret-bearing access material. This class deliberately has no custom string form.
final class AccessToken {
  const AccessToken({
    required this.value,
    required this.expiresAt,
    required this.scope,
  });

  final String value;
  final DateTime expiresAt;
  final SessionScope scope;
}

/// One device-bound session. A renewal issues another token and retires none,
/// so several live tokens may exist for one device at once.
final class SessionTokens {
  const SessionTokens({
    required this.accessToken,
    this.userId,
    this.deviceId,
    this.username,
  });

  final AccessToken accessToken;
  final String? userId;
  final String? deviceId;
  final String? username;
}

enum SessionTerminationReason { logout, revoked, expired }
