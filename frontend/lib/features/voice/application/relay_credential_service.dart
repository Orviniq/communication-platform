import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';

/// Holds the relay credential of the call in progress, and decides when to
/// fetch one.
///
/// The lifetime rule is §N rule 9 and `voice-signalling-v1.md`, "The
/// credential":
///
/// - **Fetch at a join, never at launch.** [fetchForJoin] mints one credential
///   each time it is called. Minting at startup would spend the `relay` scope
///   on launches that place no call, and hold a bearer credential for a relay
///   the user may never reach.
/// - **Fetch another under an hour.** [refreshIfDue] mints only once the held
///   credential is inside its final hour, and [refreshDueAt] says when that
///   begins, so the call can wake at that moment instead of polling. What the
///   call does with the new one — an ICE restart — is the call's.
/// - **In memory only.** The credential lives in this object until [release],
///   which the call runs when it ends.
///
/// Two answers stop it asking. A deployment that serves no voice —
/// `voice_configured` false, or `503 voice_unconfigured` from the route itself
/// — is [VoiceUnavailable], and after the `503` nothing is asked again for the
/// life of this object: the relay list is empty, and a retry cannot fill it.
/// `429 throttled` is a cooldown of exactly `Retry-After`, during which nothing
/// is asked either.
final class RelayCredentialService {
  RelayCredentialService({
    required this.remote,
    required this.deployment,
    required this.clock,
  });

  /// The cooldown when a `429` carries no usable `Retry-After`. The route
  /// always sends one; a proxy's own `429` might not. The `relay` scope counts
  /// calls in a minute, so waiting a minute always clears it.
  static const throttleFallback = Duration(minutes: 1);

  final RelayCredentialPort remote;
  final VoiceDeploymentPort deployment;
  final TimeSource clock;

  RelayCredential? _held;
  DateTime? _coolingDownUntil;
  bool _refusedByServer = false;

  /// Moves on every [release], so that a mint still in flight when a call
  /// ends is not kept afterwards.
  int _generation = 0;

  /// Whether a call may be offered: the deployment says it serves voice, and
  /// the route has not said otherwise.
  bool get isVoiceAvailable => deployment.voiceConfigured && !_refusedByServer;

  /// When the held credential enters its final hour, or null when none is held.
  DateTime? get refreshDueAt => _held?.refreshDueAt;

  /// A credential for a join: always a fresh mint, unless voice is unavailable
  /// or a cooldown is running.
  Future<RelayCredentialOutcome> fetchForJoin() => _mintUnlessBarred();

  /// Mints another credential only when the held one is due for a refresh.
  ///
  /// Holding none counts as due.
  Future<RelayCredentialOutcome> refreshIfDue() {
    final held = _held;
    if (held != null && !held.isRefreshDueAt(clock.now())) {
      return Future.value(RelayCredentialHeld(held));
    }
    return _mintUnlessBarred();
  }

  /// Forgets the held credential. The call runs this when it ends.
  void release() {
    _held = null;
    _generation += 1;
  }

  Future<RelayCredentialOutcome> _mintUnlessBarred() {
    if (!isVoiceAvailable) {
      return Future.value(const VoiceUnavailable());
    }
    final coolingDownUntil = _coolingDownUntil;
    if (coolingDownUntil != null && clock.now().isBefore(coolingDownUntil)) {
      return Future.value(RelayMintThrottled(coolingDownUntil));
    }
    return _mint();
  }

  Future<RelayCredentialOutcome> _mint() async {
    final generation = _generation;
    final minted = await remote.mint();
    switch (minted) {
      case Success(value: final credential):
        _coolingDownUntil = null;
        if (generation == _generation) {
          _held = credential;
        }
        return RelayCredentialMinted(credential);
      // Decided on the `code` the failure carries, never on the status: `503`
      // is also `unavailable` and `storage_full`, and those are outages rather
      // than a statement about the deployment.
      case FailureResult(
        failure: BackendFailure(code: BackendFailureCode.voiceUnconfigured),
      ):
        _refusedByServer = true;
        return const VoiceUnavailable();
      case FailureResult(
        failure: BackendFailure(
          code: BackendFailureCode.throttled,
          :final retryAfter,
        ),
      ):
        // Counted from the answer, which is when the server started counting.
        final retryAt = clock.now().add(retryAfter ?? throttleFallback);
        _coolingDownUntil = retryAt;
        return RelayMintThrottled(retryAt);
      case FailureResult(:final failure):
        return RelayMintFailed(failure);
    }
  }
}
