/// Local validation is only an immediate-feedback aid. The backend remains
/// authoritative and can reject any submitted value.
abstract final class AuthenticationInputPolicy {
  static final RegExp _usernamePattern = RegExp(r'^[a-z0-9_]{3,32}$');

  static String normalizeUsername(String value) => value.trim().toLowerCase();

  static bool isUsernameValid(String value) =>
      _usernamePattern.hasMatch(normalizeUsername(value));

  /// The longest password any route accepts, from the `maxLength` every
  /// password field in `backend/openapi.json` carries.
  static const int maximumPasswordLength = 256;

  static bool isPasswordValid(String value) =>
      value.length >= 10 && value.length <= maximumPasswordLength;
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

/// What `DELETE /api/v1/me` answered, as the three states a screen can act on.
///
/// The route's other answers are ordinary failures and stay in
/// [Result.failure]; these three are outcomes the user is expected to reach and
/// must be told apart without reading a code or a `detail` string.
sealed class AccountErasureOutcome {
  const AccountErasureOutcome();
}

/// The account is gone and this device holds nothing of it any more.
///
/// Reached by `204`, and by the `401 token_revoked` that a retry of a lost
/// answer gets: the device the token named went with the account, so the first
/// call landed.
final class AccountErased extends AccountErasureOutcome {
  const AccountErased();
}

/// The password was wrong, and the account is still there to try again on.
final class AccountErasurePasswordRejected extends AccountErasureOutcome {
  const AccountErasurePasswordRejected({
    required this.attemptsUsed,
    required this.attemptsAllowed,
  }) : assert(attemptsUsed > 0, 'a rejection is at least one attempt'),
       assert(attemptsAllowed > 0, 'the allowance is at least one attempt');

  /// Wrong passwords this client has sent inside the window the server is
  /// counting. It is this client's own tally, so an attempt made from another
  /// device is absent from it and the server locks sooner than this suggests.
  final int attemptsUsed;

  /// The wrong passwords that lock the username, for wording that warns before
  /// the last one. The server decides; this never gates the call.
  final int attemptsAllowed;

  int get attemptsRemaining =>
      attemptsUsed >= attemptsAllowed ? 0 : attemptsAllowed - attemptsUsed;
}

/// The username is in a cool-off and this route is refusing until it ends.
///
/// The same `throttled` code carries the account's ordinary rate limit and the
/// per-name lock five wrong passwords earn, and only the `detail` text tells
/// them apart — which is not a thing to branch on. The wording a screen shows
/// has to hold for both, and has to say that the lock stops
/// `POST /api/v1/auth/login` too: a locked account cannot sign in on any
/// device until it lifts.
final class AccountErasureLocked extends AccountErasureOutcome {
  const AccountErasureLocked({this.retryAfter});

  /// The `Retry-After` wait, when the answer carried one.
  final Duration? retryAfter;
}
