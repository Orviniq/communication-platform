import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';

/// Where a relay credential comes from: `POST /api/v1/me/relay`.
///
/// The route takes a full-scope token and no body, reads no row and writes
/// none. It counts against the `relay` scope, 60 calls a minute for each
/// account, which is why it is called at a join and on a refresh and never at
/// launch.
abstract interface class RelayCredentialPort implements Port {
  /// Mints one credential.
  ///
  /// A refusal is a `BackendFailure` carrying the error `code`. Two codes
  /// change what the caller does: `voice_unconfigured`, which no retry can
  /// change, and `throttled`, whose `Retry-After` is on the failure.
  Future<Result<RelayCredential>> mint();
}

/// Whether this deployment serves voice at all: `voice_configured` from
/// `GET /api/v1/config`.
///
/// Read at the moment it is asked, because the published configuration can
/// arrive after the application has started on its stored or fallback one.
abstract interface class VoiceDeploymentPort implements Port {
  bool get voiceConfigured;
}
