import 'package:communication_platform/core/result/failure.dart';

/// The published error vocabulary, mapped to a value the client can branch on.
///
/// Every error of every route is one envelope, `{"code": ..., "detail": ...}`.
/// `detail` is a string on every code but `invalid_request`, where it maps a
/// dotted field path — `otpks.0.pub`, flat, never a nested object — to the list
/// of messages that failed. No error body echoes request input.
///
/// Two rules hold everywhere above this function. Branch on `code`, never on
/// `detail`; and never put a `detail` string on a screen, because it is the
/// server's wording rather than a reviewed, localized one. That is why nothing
/// but the code and the `Retry-After` crosses this boundary.
///
/// | Code | Status | Meaning | What the caller does |
/// |---|---|---|---|
/// | `invalid_request` | 400 | Validation failed | Fix the request. It is a client defect |
/// | `bad_bucket` | 400 | A blob is off-bucket | Pad to a published bucket |
/// | `identity_required` | 400 | A second device before the identity is published | Publish the identity first |
/// | `unauthenticated` / `invalid_token` | 401 | No token, or one that fails a check | Renew, then sign in |
/// | `token_revoked` | 401 | The device or the account is gone | End the session |
/// | `invalid_credentials` | 401 | Wrong username or password | Ask again |
/// | `account_inactive` | 403 | The owner has not activated the account | Wait; there is nothing to poll |
/// | `scope_forbidden` | 403 | A register-scope token on a full-scope route | Finish enrollment |
/// | `forbidden` | 403 | The token names another device than the path | Client defect |
/// | `not_found` | 404 | No such route or resource | Client defect, or a resource that is gone |
/// | `method_not_allowed` | 405 | A wrong method. `Allow` names one route object, not the path | Client defect |
/// | `username_taken` | 409 | The name is in use | Ask for another |
/// | `stale_version` | 409 | A version did not increase | Re-read and retry |
/// | `device_limit` | 409 | The account holds its maximum live devices | Revoke one first |
/// | `prekey_limit` | 409 | A prekey pool is at its cap | Stop uploading |
/// | `devicelog_limit` | 409 | The device log is full | Client defect: append on a change, not on a schedule |
/// | `payload_too_large` | 413 | The body is above the cap of the route | Do not send the same body again |
/// | `quota_exceeded` | 413 | The day's upload allowance is spent | Hold the attachment until 00:00 UTC |
/// | `throttled` | 429 | Too many requests | Read `Retry-After`. Back off |
/// | `server_error` | 500 | An internal failure | Do not retry |
/// | `storage_full` | 503 | The server disk is low | Retry later. The operator must free space |
/// | `unavailable` | 503 | An outage | Retry with a backoff |
/// | `voice_unconfigured` | 503 | This deployment serves no voice | Offer no call |
///
/// Two pairs share a status and mean different things. Both are branched apart
/// here, and both must stay apart on the screen.
///
/// **`429` is not `503`.** `throttled` says this client asked too often and
/// names the wait in `Retry-After`; the request was fine and the same one works
/// after the wait. `unavailable` says the server is saturated or a store it
/// needs is gone. Backing off and an outage are not the same signal: a wait a
/// client chose for itself is not the wait the server just published, and an
/// outage carries no wait at all.
///
/// **`413 quota_exceeded` is not `503 storage_full`.** `quota_exceeded` is the
/// account's own allowance for this UTC day, and it is spent: nothing was
/// stored and nothing was charged, so a retry before 00:00 UTC answers exactly
/// the same way, and the only correct move is to hold the attachment until the
/// day turns. `storage_full` is the server's disk below its free-space floor.
/// It is not the account's fault, no allowance was spent, and it clears when
/// the operator frees space rather than when the day does. The screen says
/// different words for each: one is "you have used today's allowance", the
/// other is "the server has no room right now".
///
/// [statusCode] decides nothing a `code` decides. It is read only where the
/// body carried no code this build knows — a proxy's own page, or a route that
/// grew a code after this build shipped — and every such answer that is not
/// placed by status is [BackendFailureCode.unknown] rather than a guess.
BackendFailure mapBackendFailure({
  required int statusCode,
  required String? wireCode,
  Duration? retryAfter,
}) {
  final code = switch (wireCode) {
    'invalid_request' => BackendFailureCode.invalidRequest,
    'bad_bucket' => BackendFailureCode.badBucket,
    'identity_required' => BackendFailureCode.identityRequired,
    // One value for both: a request with no usable token and a request with a
    // token that failed a check leave this client in the same place, and every
    // caller above already treats them as one.
    'unauthenticated' || 'invalid_token' => BackendFailureCode.invalidToken,
    'token_revoked' => BackendFailureCode.tokenRevoked,
    'invalid_credentials' => BackendFailureCode.invalidCredentials,
    'account_inactive' => BackendFailureCode.accountInactive,
    'scope_forbidden' => BackendFailureCode.scopeForbidden,
    'forbidden' => BackendFailureCode.forbidden,
    'not_found' => BackendFailureCode.notFound,
    'method_not_allowed' => BackendFailureCode.methodNotAllowed,
    'username_taken' => BackendFailureCode.usernameTaken,
    'stale_version' => BackendFailureCode.staleVersion,
    'device_limit' => BackendFailureCode.deviceLimit,
    'prekey_limit' => BackendFailureCode.prekeyLimit,
    'devicelog_limit' => BackendFailureCode.deviceLogLimit,
    'payload_too_large' => BackendFailureCode.payloadTooLarge,
    'quota_exceeded' => BackendFailureCode.quotaExceeded,
    'throttled' => BackendFailureCode.throttled,
    'server_error' => BackendFailureCode.serverError,
    'storage_full' => BackendFailureCode.storageFull,
    'unavailable' => BackendFailureCode.unavailable,
    'voice_unconfigured' => BackendFailureCode.voiceUnconfigured,
    // A body with no code this build knows, placed by the status the surface
    // documents for it. `413` and `503` are deliberately absent: each is shared
    // by two codes that call for different behaviour, and picking one of them
    // from the status is the guess this function exists to refuse.
    _ when statusCode == 400 => BackendFailureCode.invalidRequest,
    _ when statusCode == 401 => BackendFailureCode.invalidToken,
    _ when statusCode == 403 => BackendFailureCode.forbidden,
    _ when statusCode == 404 => BackendFailureCode.notFound,
    _ when statusCode == 405 => BackendFailureCode.methodNotAllowed,
    _ when statusCode == 429 => BackendFailureCode.throttled,
    _ when statusCode == 500 => BackendFailureCode.serverError,
    _ => BackendFailureCode.unknown,
  };
  // The wait belongs to the one code that publishes one. Carrying it on any
  // other would let a caller treat an outage as a timed backoff.
  return code == BackendFailureCode.throttled
      ? BackendFailure(code, retryAfter: retryAfter)
      : BackendFailure(code);
}
