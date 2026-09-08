import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';

final class MalformedApiBody implements Exception {
  const MalformedApiBody();
}

Map<String, Object?> requireJsonObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const MalformedApiBody();
  }
  return value;
}

final class HealthResponseDto {
  const HealthResponseDto();

  factory HealthResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    if (json['status'] != 'ok') {
      throw const MalformedApiBody();
    }
    return const HealthResponseDto();
  }
}

/// What `POST /api/v1/auth/renew` answers: the same session, on a later token.
///
/// A register-scope token cannot reach the route — it answers `403
/// scope_forbidden` — so a body that parses is always a full-scope session.
final class SessionTokenResponseDto {
  const SessionTokenResponseDto._({
    required this.token,
    required this.expiresIn,
  });

  factory SessionTokenResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const MalformedApiBody();
    }
    return SessionTokenResponseDto._(
      token: token,
      expiresIn: readExpiresIn(json['expires_in']),
    );
  }

  final String token;
  final Duration expiresIn;

  /// [receivedAt] anchors [expiresIn], which the server states relative to the
  /// moment it issued the token.
  SessionTokens toDomain({DateTime? receivedAt}) => SessionTokens(
    accessToken: AccessToken(
      value: token,
      expiresAt: (receivedAt ?? DateTime.now()).toUtc().add(expiresIn),
      scope: SessionScope.full,
    ),
  );
}

final class ErrorEnvelopeDto {
  const ErrorEnvelopeDto({required this.code});

  factory ErrorEnvelopeDto.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return const ErrorEnvelopeDto(code: null);
    }
    final code = value['code'];
    return ErrorEnvelopeDto(code: code is String ? code : null);
  }

  /// `detail` is intentionally neither parsed nor retained.
  final String? code;
}

final class EmptyResponseDto {
  const EmptyResponseDto();

  factory EmptyResponseDto.fromJson(Object? value) {
    if (value != null) {
      throw const MalformedApiBody();
    }
    return const EmptyResponseDto();
  }
}

final class EnvelopeDto {
  const EnvelopeDto({
    required this.id,
    required this.sequence,
    required this.blob,
  });

  factory EnvelopeDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final id = json['id'];
    final sequence = json['seq'];
    final blob = json['blob'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        sequence is! int ||
        sequence < 1 ||
        blob is! String ||
        !isCanonicalBase64Bucket(blob, ApiContractLimits.envelopeBuckets)) {
      throw const MalformedApiBody();
    }
    return EnvelopeDto(id: id, sequence: sequence, blob: blob);
  }

  final String id;
  final int sequence;
  final String blob;
}

bool isCanonicalBase64Bucket(String value, Set<int> allowedDecodedBytes) {
  if (value.isEmpty ||
      value.length % 4 != 0 ||
      !_standardBase64.hasMatch(value)) {
    return false;
  }
  final padding = value.endsWith('==')
      ? 2
      : value.endsWith('=')
      ? 1
      : 0;
  final decodedBytes = (value.length ~/ 4 * 3) - padding;
  return allowedDecodedBytes.contains(decodedBytes);
}

final class DrainEnvelopesResponseDto {
  const DrainEnvelopesResponseDto({
    required this.envelopes,
    required this.hasMore,
    required this.prunedThrough,
  });

  factory DrainEnvelopesResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final values = json['envelopes'];
    final hasMore = json['has_more'];
    final prunedThrough = json['pruned_through'];
    if (values is! List<Object?> ||
        hasMore is! bool ||
        prunedThrough is! int ||
        prunedThrough < 0 ||
        values.length > 100) {
      throw const MalformedApiBody();
    }
    return DrainEnvelopesResponseDto(
      envelopes: values.map(EnvelopeDto.fromJson).toList(growable: false),
      hasMore: hasMore,
      prunedThrough: prunedThrough,
    );
  }

  final List<EnvelopeDto> envelopes;
  final bool hasMore;
  final int prunedThrough;
}

/// The published lifetime of a token, in seconds.
///
/// The token is opaque to this client: it carries no `scope` claim, and the
/// server publishes `expires_in` so that nothing has to read the claims to
/// learn when a token dies (ADR-0023).
Duration readExpiresIn(Object? value) {
  if (value is! int || value <= 0) {
    throw const MalformedApiBody();
  }
  return Duration(seconds: value);
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _standardBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
