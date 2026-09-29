import 'package:communication_platform/core/result/failure.dart';

/// The relay credential `POST /api/v1/me/relay` mints, as this device holds it.
///
/// A TURN REST API user name and password for the self-hosted coturn of server
/// ADR-0021, the URLs that name that relay, and how long the pair stays good.
/// It is everything a call needs from the server before its first `signal`
/// frame (`backend/CLIENT_CONTRACT.md` §N rule 9).
///
/// **Secret-bearing.** [credential] opens the relay to whoever holds it until
/// [expiresAt]. This class therefore deliberately has no string form, and
/// neither has anything built from it: it is kept in memory for as long as a
/// call needs it, and never written to the database or to a log
/// (`voice-signalling-v1.md`, "The credential").
///
/// [username] is passed through unchanged. It is an expiry timestamp, a colon
/// and sixteen random bytes, and it carries no account identifier and no device
/// identifier, so nothing reads one out of it. Nothing reads the timestamp
/// either: [expiresAt] is `expires_in` counted on this device's own clock, so a
/// device whose clock disagrees with the server's still refreshes on time.
final class RelayCredential {
  /// Every URL must be a relay URL ([isRelayTurnUrl]), and there must be at
  /// least one. The parse boundary in
  /// `infrastructure/relay_credential_api_dtos.dart` refuses a body that breaks
  /// this before it gets here. The checks are repeated because they are what
  /// keeps a STUN server out of [iceConfiguration], whatever built the value.
  ///
  /// No message names a refused value: a refused URL may sit beside a live
  /// credential, and an error is text that can end up in a log.
  RelayCredential({
    required Iterable<String> urls,
    required this.username,
    required this.credential,
    required this.lifetime,
    required this.expiresAt,
  }) : urls = List.unmodifiable(urls) {
    if (this.urls.isEmpty || !this.urls.every(isRelayTurnUrl)) {
      throw ArgumentError('A relay credential names one or more turn: URLs.');
    }
    if (username.isEmpty || credential.isEmpty) {
      throw ArgumentError('A relay credential has a user name and a password.');
    }
    if (lifetime <= Duration.zero) {
      throw ArgumentError('A relay credential is good for some time.');
    }
  }

  /// The contract's margin: another credential is fetched once less than this
  /// much of the held one remains (§N rule 9).
  static const refreshMargin = Duration(hours: 1);

  /// The relay's `turn:` URLs, in the order the operator wrote them.
  final List<String> urls;

  /// The TURN user name, passed through unchanged.
  final String username;

  /// The TURN password: standard base64 of an HMAC over [username].
  final String credential;

  /// `expires_in`: how long the pair stays good, counted from its mint.
  final Duration lifetime;

  /// When the relay stops accepting the pair, on this device's clock.
  ///
  /// Anchored on the moment the request was sent. The server mints after
  /// that, so this is never later than the relay's own expiry.
  final DateTime expiresAt;

  /// The ICE configuration a call's connections are built with: one server for
  /// each of [urls], each with this [username] and [credential], and the
  /// `relay` transport policy. Nothing else — no STUN server and no other
  /// server (§N rule 2).
  late final RelayIceConfiguration iceConfiguration = RelayIceConfiguration._([
    for (final url in urls)
      RelayIceServer._(url: url, username: username, credential: credential),
  ]);

  /// When this credential enters the stretch in which the next one is fetched.
  ///
  /// [refreshMargin] before [expiresAt], unless the whole [lifetime] is under
  /// twice that margin — then half the lifetime. `RELAY_CREDENTIAL_TTL_SECONDS`
  /// is an operator setting with no floor. At an hour or less every credential
  /// would be born inside its own final hour, so each refresh would mint
  /// another that was already due, and the loop would stop only at the `relay`
  /// throttle; just above an hour, the mints would come seconds apart. From two
  /// hours up, which includes the default six, the margin is the contract's
  /// hour exactly.
  DateTime get refreshDueAt => expiresAt.subtract(
    lifetime >= refreshMargin * 2 ? refreshMargin : lifetime ~/ 2,
  );

  /// Whether another credential should be fetched at [now]: strictly less
  /// than the margin remains. With exactly the margin left, not yet.
  bool isRefreshDueAt(DateTime now) => now.isAfter(refreshDueAt);
}

/// The ICE transport policy a call's connections use.
///
/// One value, on purpose. `all` gathers host and server-reflexive candidates,
/// and either one puts a participant's own address in front of every other
/// participant — the property the relay exists to remove (§N rule 2, server
/// ADR-0021 point 2).
enum IceTransportPolicy { relay }

/// What a call's connections are configured with, built only from a
/// [RelayCredential].
///
/// There is no other way to build one, so it holds relay servers and nothing
/// else: every server is one of the credential's `turn:` URLs, and no STUN
/// server, foreign server or fallback can be added to it. Secret-bearing,
/// because each server carries the credential, and with no string form for the
/// same reason.
final class RelayIceConfiguration {
  RelayIceConfiguration._(Iterable<RelayIceServer> servers)
    : servers = List.unmodifiable(servers);

  /// One for each of the credential's URLs, in the operator's order.
  final List<RelayIceServer> servers;

  IceTransportPolicy get transportPolicy => IceTransportPolicy.relay;
}

/// One entry of [RelayIceConfiguration.servers]: one `turn:` URL, and the
/// credential that opens it.
final class RelayIceServer {
  const RelayIceServer._({
    required this.url,
    required this.username,
    required this.credential,
  });

  final String url;
  final String username;
  final String credential;
}

/// Whether [value] is a URL this client configures as a relay: `turn:`, a
/// host, an optional port and an optional `?transport=udp` or `?transport=tcp`
/// (RFC 7065 §3.1).
///
/// Narrower than RFC 7065, each time because the contract is:
///
/// - **`turn:` only.** The route names `turn:` URLs, and the relay has no TLS
///   listener (`backend/SECURITY.md`, "Voice"). A `turns:` URL would also hand
///   libwebrtc a trust decision nobody has made: it checks a TLS relay against
///   its own compiled-in roots and the platform store, user-installed
///   authorities included, and never against the provisioned one (ADR-078).
/// - **`udp` or `tcp`.** The two transports libwebrtc accepts. Anything else
///   would fail the whole configuration when a connection is created, rather
///   than here, where it can be named.
/// - **A plain host.** A DNS name, an IPv4 address or a bracketed IPv6
///   literal, with no user information, path, fragment or percent-encoding,
///   and a port from 1 to 65535.
bool isRelayTurnUrl(String value) {
  final match = _relayTurnUrl.firstMatch(value);
  if (match == null) {
    return false;
  }
  final port = match.group(1);
  if (port == null) {
    return true;
  }
  final number = int.parse(port);
  return number >= 1 && number <= 65535;
}

final RegExp _relayTurnUrl = RegExp(
  r'^turn:'
  r'(?:\[[0-9A-Fa-f:.]+\]'
  r'|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)'
  r'(?::([0-9]{1,5}))?'
  r'(?:\?transport=(?:udp|tcp))?$',
);

/// What asking for a relay credential came to.
sealed class RelayCredentialOutcome {
  const RelayCredentialOutcome();
}

/// A credential was minted for this request. It is the one held from now on,
/// unless the call ended while it was being minted.
final class RelayCredentialMinted extends RelayCredentialOutcome {
  const RelayCredentialMinted(this.credential);

  final RelayCredential credential;
}

/// The held credential is not yet due for a refresh, so nothing was fetched.
final class RelayCredentialHeld extends RelayCredentialOutcome {
  const RelayCredentialHeld(this.credential);

  final RelayCredential credential;
}

/// This deployment serves no voice: `voice_configured` is false, or the route
/// answered `503 voice_unconfigured`.
///
/// Not a fault and not a backoff. A retry cannot make a relay appear, so
/// nothing is asked again, and a call is not offered (*Voice not set up on
/// this server*).
final class VoiceUnavailable extends RelayCredentialOutcome {
  const VoiceUnavailable();
}

/// `429 throttled`: nothing is asked before [retryAt], and the join cools down
/// until then (*Rate limited*).
final class RelayMintThrottled extends RelayCredentialOutcome {
  const RelayMintThrottled(this.retryAt);

  final DateTime retryAt;
}

/// The mint did not complete: offline, a timeout, a refused token, a server
/// failure, or a body that was not a credential. Nothing is held from it, and
/// the next request asks again.
final class RelayMintFailed extends RelayCredentialOutcome {
  const RelayMintFailed(this.failure);

  final Failure failure;
}
