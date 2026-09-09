import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/features/networking/infrastructure/api/backend_error_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The published vocabulary, and the two places where a status is not enough.
///
/// The rule everything here rests on is that a client branches on `code`. A
/// `detail` string is the server's wording, never a screen's, and on
/// `invalid_request` it is not even a string — so nothing but the code and the
/// published wait crosses this function.
void main() {
  BackendFailureCode mapped(int status, String? code, {Duration? retryAfter}) =>
      mapBackendFailure(
        statusCode: status,
        wireCode: code,
        retryAfter: retryAfter,
      ).code;

  group('the codes this surface answers', () {
    const vocabulary = <(int, String, BackendFailureCode)>[
      (400, 'invalid_request', BackendFailureCode.invalidRequest),
      (400, 'bad_bucket', BackendFailureCode.badBucket),
      (400, 'identity_required', BackendFailureCode.identityRequired),
      (401, 'unauthenticated', BackendFailureCode.invalidToken),
      (401, 'invalid_token', BackendFailureCode.invalidToken),
      (401, 'token_revoked', BackendFailureCode.tokenRevoked),
      (401, 'invalid_credentials', BackendFailureCode.invalidCredentials),
      (403, 'account_inactive', BackendFailureCode.accountInactive),
      (403, 'scope_forbidden', BackendFailureCode.scopeForbidden),
      (403, 'forbidden', BackendFailureCode.forbidden),
      (404, 'not_found', BackendFailureCode.notFound),
      (405, 'method_not_allowed', BackendFailureCode.methodNotAllowed),
      (409, 'username_taken', BackendFailureCode.usernameTaken),
      (409, 'stale_version', BackendFailureCode.staleVersion),
      (409, 'device_limit', BackendFailureCode.deviceLimit),
      (409, 'prekey_limit', BackendFailureCode.prekeyLimit),
      (409, 'devicelog_limit', BackendFailureCode.deviceLogLimit),
      (413, 'payload_too_large', BackendFailureCode.payloadTooLarge),
      (413, 'quota_exceeded', BackendFailureCode.quotaExceeded),
      (429, 'throttled', BackendFailureCode.throttled),
      (500, 'server_error', BackendFailureCode.serverError),
      (503, 'storage_full', BackendFailureCode.storageFull),
      (503, 'unavailable', BackendFailureCode.unavailable),
      (503, 'voice_unconfigured', BackendFailureCode.voiceUnconfigured),
    ];

    test('every one of them maps to a value of its own', () {
      for (final (status, wire, expected) in vocabulary) {
        expect(mapped(status, wire), expected, reason: wire);
      }
    });

    test('every value but the catch-all is reachable from the wire', () {
      // The other direction, so a value nothing answers cannot survive here
      // the way `bad_request`, `token_not_valid`, `device_scope_required` and
      // `keypackage_limit` did.
      final reached = {for (final entry in vocabulary) entry.$3};

      expect(
        reached,
        {...BackendFailureCode.values}..remove(BackendFailureCode.unknown),
      );
    });

    test('a code no route answers any more is not one of them', () {
      for (final retired in const [
        'bad_request',
        'token_not_valid',
        'device_scope_required',
        'keypackage_limit',
      ]) {
        // Placed by status where the surface documents one, and never by a
        // name this build still recognises.
        expect(
          mapped(409, retired),
          BackendFailureCode.unknown,
          reason: retired,
        );
      }
    });
  });

  group('429 and 503 are not the same signal', () {
    test('backing off carries the wait the server published', () {
      final failure = mapBackendFailure(
        statusCode: 429,
        wireCode: 'throttled',
        retryAfter: const Duration(seconds: 17),
      );

      expect(failure.code, BackendFailureCode.throttled);
      expect(failure.retryAfter, const Duration(seconds: 17));
    });

    test('an outage carries no wait, even when a header offers one', () {
      // `Retry-After` belongs to the one code that publishes it. A caller that
      // read it off an outage would treat "come back in 17 seconds" as the
      // server's answer when the server said no such thing.
      final failure = mapBackendFailure(
        statusCode: 503,
        wireCode: 'unavailable',
        retryAfter: const Duration(seconds: 17),
      );

      expect(failure.code, BackendFailureCode.unavailable);
      expect(failure.retryAfter, isNull);
    });

    test('they are different values, and neither is the other', () {
      expect(mapped(429, 'throttled'), isNot(mapped(503, 'unavailable')));
    });

    test('an outage and a deployment with no voice stay apart at 503', () {
      // Both are `503`. One clears on its own and the other never does, so a
      // client that retried `voice_unconfigured` would be waiting for a
      // feature the operator did not configure.
      expect(mapped(503, 'unavailable'), BackendFailureCode.unavailable);
      expect(
        mapped(503, 'voice_unconfigured'),
        BackendFailureCode.voiceUnconfigured,
      );
    });
  });

  group('a spent allowance and a full disk are not the same refusal', () {
    test('the day is spent at 413 and the disk is gone at 503', () {
      // `quota_exceeded` is this account's own allowance for this UTC day:
      // nothing was stored and nothing was charged, so a retry before the day
      // turns answers the same way and the attachment is held. `storage_full`
      // is the operator's disk, is nobody's fault, and clears when space is
      // freed rather than when the day turns.
      expect(mapped(413, 'quota_exceeded'), BackendFailureCode.quotaExceeded);
      expect(mapped(503, 'storage_full'), BackendFailureCode.storageFull);
    });

    test('the two refusals that share 413 stay apart', () {
      expect(
        mapped(413, 'payload_too_large'),
        BackendFailureCode.payloadTooLarge,
      );
      expect(
        mapped(413, 'quota_exceeded'),
        isNot(mapped(413, 'payload_too_large')),
      );
    });

    test('neither shared status is ever decided by the status alone', () {
      // A body with no code this build knows is `unknown` at both, because
      // guessing which half of the pair it was is the one thing worse than
      // saying nothing: it would hold an attachment the server never charged
      // for, or spend the day's allowance on a body that was merely too big.
      expect(mapped(413, null), BackendFailureCode.unknown);
      expect(mapped(503, null), BackendFailureCode.unknown);
    });
  });

  group('a body with no code this build knows', () {
    test('is placed by the status the surface documents for it', () {
      expect(mapped(400, null), BackendFailureCode.invalidRequest);
      expect(mapped(401, null), BackendFailureCode.invalidToken);
      expect(mapped(403, null), BackendFailureCode.forbidden);
      expect(mapped(404, null), BackendFailureCode.notFound);
      expect(mapped(405, null), BackendFailureCode.methodNotAllowed);
      expect(mapped(429, null), BackendFailureCode.throttled);
      expect(mapped(500, null), BackendFailureCode.serverError);
    });

    test('is unknown where the status decides nothing', () {
      expect(mapped(418, 'nonsense'), BackendFailureCode.unknown);
      expect(mapped(451, null), BackendFailureCode.unknown);
    });

    test('a throttled answer keeps its wait even with no code', () {
      // A proxy that answered the status without the envelope still published
      // a wait, and honouring it is the whole point of reading the header.
      final failure = mapBackendFailure(
        statusCode: 429,
        wireCode: null,
        retryAfter: const Duration(seconds: 3),
      );

      expect(failure.code, BackendFailureCode.throttled);
      expect(failure.retryAfter, const Duration(seconds: 3));
    });
  });

  group('the classification each code carries', () {
    test('the server, and not these bytes, is a transport result', () {
      for (final code in const [
        BackendFailureCode.throttled,
        BackendFailureCode.unavailable,
        BackendFailureCode.serverError,
      ]) {
        expect(
          BackendFailure(code).category,
          FailureCategory.transport,
          reason: code.name,
        );
      }
    });

    test('both refusals about room are storage results', () {
      for (final code in const [
        BackendFailureCode.quotaExceeded,
        BackendFailureCode.storageFull,
      ]) {
        expect(
          BackendFailure(code).category,
          FailureCategory.storage,
          reason: code.name,
        );
      }
    });

    test('the three client defects are validation results', () {
      for (final code in const [
        BackendFailureCode.payloadTooLarge,
        BackendFailureCode.methodNotAllowed,
        BackendFailureCode.deviceLogLimit,
      ]) {
        expect(
          BackendFailure(code).category,
          FailureCategory.validation,
          reason: code.name,
        );
      }
    });
  });
}
