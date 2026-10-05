import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';

/// The `RelayCredentialOut` body of `POST /api/v1/me/relay`.
///
/// All four fields are required by the contract and every one of them is
/// checked. A body is refused, as [MalformedApiBody], when a field is missing
/// or of the wrong type, when `urls` is empty or longer than [maxRelayUrls],
/// when a URL is not a relay URL ([isRelayTurnUrl]), when the user name or the
/// password is empty, and when `expires_in` is not a positive integer. An
/// unknown fifth field is ignored rather than refused: `RelayCredentialOut`
/// declares no `additionalProperties: false`.
///
/// Secret-bearing, like the credential it becomes, and with no string form
/// for the same reason.
final class RelayCredentialResponseDto {
  const RelayCredentialResponseDto._({
    required this.urls,
    required this.username,
    required this.credential,
    required this.lifetime,
  });

  factory RelayCredentialResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    return RelayCredentialResponseDto._(
      urls: _relayUrls(json['urls']),
      username: _secret(json['username']),
      credential: _secret(json['credential']),
      lifetime: readExpiresIn(json['expires_in']),
    );
  }

  /// A deployment names one relay URL for each transport it listens on — the
  /// example configuration names two. The ceiling is here so that a body that
  /// is well-formed JSON but is not a relay list cannot become a list of relay
  /// allocations, one for each URL on every connection of a call.
  static const maxRelayUrls = 16;

  final List<String> urls;
  final String username;
  final String credential;
  final Duration lifetime;

  /// [requestedAt] anchors [lifetime]. The server counts `expires_in` from the
  /// mint, which comes after the request was sent, so the expiry this sets is
  /// never later than the relay's own.
  RelayCredential toDomain({required DateTime requestedAt}) => RelayCredential(
    urls: urls,
    username: username,
    credential: credential,
    lifetime: lifetime,
    expiresAt: requestedAt.toUtc().add(lifetime),
  );
}

List<String> _relayUrls(Object? value) {
  if (value is! List<Object?> ||
      value.isEmpty ||
      value.length > RelayCredentialResponseDto.maxRelayUrls) {
    throw const MalformedApiBody();
  }
  final urls = <String>[];
  for (final url in value) {
    if (url is! String || !isRelayTurnUrl(url)) {
      throw const MalformedApiBody();
    }
    urls.add(url);
  }
  return List.unmodifiable(urls);
}

/// The user name and the password are opaque and are passed through
/// unchanged. Empty is refused: an empty value cannot open the relay.
String _secret(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const MalformedApiBody();
  }
  return value;
}
