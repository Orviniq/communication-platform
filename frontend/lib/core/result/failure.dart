/// Failure groups that presentation can map to reviewed, localized copy.
///
/// These types deliberately carry stable classifications only. Raw backend response
/// messages, server payloads, and exception text must remain in infrastructure logs
/// with redaction and must never cross this boundary.
sealed class Failure {
  const Failure();

  FailureCategory get category;
}

enum FailureCategory {
  transport,
  authentication,
  validation,
  security,
  storage,
  unsupportedProtocol,
  cancellation,
}

final class TransportFailure extends Failure {
  const TransportFailure(this.kind);

  final TransportFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.transport;
}

enum TransportFailureKind {
  offline,
  timeout,
  connectionRejected,
  responseTooLarge,
  requestTooLarge,

  /// The transport refused to trust the peer: the chain did not terminate at
  /// the provisioned authority, or hostname verification failed.
  ///
  /// Distinct from [offline] on purpose. A rejected certificate is a security
  /// result and must never be retried or presented as a network outage.
  trustRejected,
}

final class AuthenticationFailure extends Failure {
  const AuthenticationFailure(this.kind);

  final AuthenticationFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.authentication;
}

enum AuthenticationFailureKind { sessionExpired, accessDenied }

final class ValidationFailure extends Failure {
  const ValidationFailure(this.kind);

  final ValidationFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.validation;
}

enum ValidationFailureKind { invalidInput, conflict, limitExceeded }

final class SecurityFailure extends Failure {
  const SecurityFailure(this.kind);

  final SecurityFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.security;
}

enum SecurityFailureKind {
  unauthenticatedInput,
  integrityCheckFailed,
  policyBlocked,
  malformedServerResponse,
}

/// Stable error codes exported by the version-1 native crypto ABI.
///
/// The code is safe to inspect, but no native error string, input, key, or
/// ciphertext is retained by this failure.
enum CryptoCoreFailureCode {
  invalidArgument(1),
  inputTooLarge(2),
  outputTooSmall(3),
  malformedInput(4),
  invalidHandle(5),
  wrongHandleType(6),
  authenticationFailed(7),
  unsupportedVersion(8),
  unsupportedOperation(9),
  resourceExhausted(10),
  entropyUnavailable(11),
  stateViolation(12),
  internalFailure(13),
  panicContained(14);

  const CryptoCoreFailureCode(this.wireValue);

  final int wireValue;

  static CryptoCoreFailureCode? fromWireValue(int wireValue) {
    for (final code in values) {
      if (code.wireValue == wireValue) {
        return code;
      }
    }
    return null;
  }
}

final class CryptoCoreFailure extends Failure {
  const CryptoCoreFailure(this.code);

  final CryptoCoreFailureCode code;

  @override
  FailureCategory get category => switch (code) {
    CryptoCoreFailureCode.invalidArgument ||
    CryptoCoreFailureCode.inputTooLarge ||
    CryptoCoreFailureCode.outputTooSmall ||
    CryptoCoreFailureCode.malformedInput ||
    CryptoCoreFailureCode.resourceExhausted => FailureCategory.validation,
    CryptoCoreFailureCode.unsupportedVersion ||
    CryptoCoreFailureCode.unsupportedOperation =>
      FailureCategory.unsupportedProtocol,
    CryptoCoreFailureCode.invalidHandle ||
    CryptoCoreFailureCode.wrongHandleType ||
    CryptoCoreFailureCode.authenticationFailed ||
    CryptoCoreFailureCode.entropyUnavailable ||
    CryptoCoreFailureCode.stateViolation ||
    CryptoCoreFailureCode.internalFailure ||
    CryptoCoreFailureCode.panicContained => FailureCategory.security,
  };

  @override
  String toString() => 'CryptoCoreFailure(code: ${code.name})';
}

final class StorageFailure extends Failure {
  const StorageFailure(this.kind);

  final StorageFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.storage;
}

enum StorageFailureKind { unavailable, migrationBlocked, capacityExceeded }

final class UnsupportedProtocolFailure extends Failure {
  const UnsupportedProtocolFailure(this.kind);

  final UnsupportedProtocolFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.unsupportedProtocol;
}

enum UnsupportedProtocolFailureKind { version, eventKind, capability }

final class CancellationFailure extends Failure {
  const CancellationFailure(this.kind);

  final CancellationFailureKind kind;

  @override
  FailureCategory get category => FailureCategory.cancellation;
}

enum CancellationFailureKind { requestedByUser, lifecycleInterrupted }

/// Stable backend reasons. Arbitrary backend `detail` values never cross this type.
///
/// One value per `code` the surface answers, named after it. The wire
/// vocabulary is fixed and small, so a name that is not the code's own is a
/// second spelling of the same fact and drifts from it — which is what
/// `bad_request`, `token_not_valid`, `device_scope_required` and
/// `keypackage_limit` did before they were deleted from here.
enum BackendFailureCode {
  invalidRequest,
  usernameTaken,
  invalidCredentials,
  accountInactive,
  invalidToken,
  tokenRevoked,
  scopeForbidden,
  forbidden,
  notFound,
  methodNotAllowed,
  badBucket,
  staleVersion,
  identityRequired,
  deviceLimit,
  prekeyLimit,
  deviceLogLimit,
  payloadTooLarge,
  quotaExceeded,
  throttled,
  serverError,
  storageFull,
  unavailable,
  voiceUnconfigured,
  unknown,
}

/// A documented backend error mapped to a safe, exhaustive client value.
final class BackendFailure extends Failure {
  const BackendFailure(this.code, {this.retryAfter});

  final BackendFailureCode code;
  final Duration? retryAfter;

  @override
  FailureCategory get category => switch (code) {
    BackendFailureCode.invalidCredentials ||
    BackendFailureCode.accountInactive ||
    BackendFailureCode.invalidToken ||
    BackendFailureCode.tokenRevoked ||
    BackendFailureCode.scopeForbidden ||
    BackendFailureCode.forbidden => FailureCategory.authentication,
    // The day's allowance and the server's disk are both storage, and they are
    // still two different sentences on a screen: see [BackendFailureCode].
    BackendFailureCode.quotaExceeded ||
    BackendFailureCode.storageFull => FailureCategory.storage,
    BackendFailureCode.voiceUnconfigured => FailureCategory.unsupportedProtocol,
    // Backing off, an outage and an internal failure are all "the server, not
    // these bytes". None of them is decided against the request in hand.
    BackendFailureCode.throttled ||
    BackendFailureCode.unavailable ||
    BackendFailureCode.serverError => FailureCategory.transport,
    BackendFailureCode.invalidRequest ||
    BackendFailureCode.usernameTaken ||
    BackendFailureCode.notFound ||
    BackendFailureCode.methodNotAllowed ||
    BackendFailureCode.badBucket ||
    BackendFailureCode.staleVersion ||
    BackendFailureCode.identityRequired ||
    BackendFailureCode.deviceLimit ||
    BackendFailureCode.prekeyLimit ||
    BackendFailureCode.deviceLogLimit ||
    BackendFailureCode.payloadTooLarge ||
    BackendFailureCode.unknown => FailureCategory.validation,
  };
}
