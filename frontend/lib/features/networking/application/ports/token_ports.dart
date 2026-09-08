import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';

/// Protected token persistence. Replacing the stored session must be atomic.
abstract interface class SessionTokenStore implements Port {
  /// The tokens this owner believes are current, which an implementation may
  /// answer from its own memory.
  Future<SessionTokens?> read();

  /// The tokens the durable store actually holds, ignoring anything this owner
  /// has cached.
  ///
  /// The durable row is shared with every other delivery owner in this process
  /// (ADR-050), and a renewal in any of them replaces it. A cached answer is
  /// this owner's last observation, not the truth, so every decision that could
  /// *end a session* is made against this rather than against [read].
  Future<SessionTokens?> readDurable();

  Future<void> replace(SessionTokens tokens);

  Future<void> clear();
}

/// Exchanges the session token this client holds for a later one.
///
/// The call carries its token in the `Authorization` header rather than in an
/// argument, and it is safe to repeat: nothing is written and no generation
/// moves, so a retry issues another token and retires none (ADR-0023).
abstract interface class RenewTokenExchange implements Port {
  Future<Result<SessionTokens>> renew();
}

abstract interface class LogoutTokenExchange implements Port {
  Future<void> revoke({required String accessToken});
}

abstract interface class SessionTerminationHandler implements Port {
  Future<void> terminate(SessionTerminationReason reason);
}

abstract interface class AccessTokenCoordinator implements Port {
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false});

  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken);

  Future<void> logout();

  Future<void> handleRevocation();
}
