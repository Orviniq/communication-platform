import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';

enum RestMethod { get, post, put, delete, head }

enum AuthenticationRequirement { none, registerOrFull, full }

/// Automatic replay is disabled unless the caller proves the operation is safe.
enum ReplaySafety { never, readOnly, contractIdempotent }

final class NetworkTimeouts {
  const NetworkTimeouts({
    this.connect = const Duration(seconds: 10),
    this.send = const Duration(seconds: 30),
    this.receive = const Duration(seconds: 30),
  });

  final Duration connect;
  final Duration send;
  final Duration receive;
}

final class PayloadLimits {
  const PayloadLimits({
    required this.maximumRequestBytes,
    required this.maximumResponseBytes,
  }) : assert(maximumRequestBytes >= 0),
       assert(maximumResponseBytes > 0);

  final int maximumRequestBytes;
  final int maximumResponseBytes;
}

/// Wire constants copied from the authoritative backend API documents.
abstract final class ApiContractLimits {
  static const maximumEnvelopeTargets = 256;
  static const maximumAcknowledgementIds = 200;
  static const maximumClaimDeviceIds = 100;
  static const maximumDeviceLogRecords = 50;
  static const maximumWebSocketFrameBytes = 524288;
  static const maximumSignalCharacters = 16384;
  static const maximumAttachmentBytes = 67108864;

  static const envelopeBuckets = {1024, 4096, 16384, 65536, 262144};
  static const profileBuckets = {1024, 4096};
  static const labelBuckets = {256, 1024};
  static const nameBuckets = {256, 1024};
  static const keyPackageBuckets = {4096, 16384};
  static const deviceLogBuckets = {256, 1024};
  static const backupBuckets = {4096, 16384, 65536, 262144, 1048576};
  static const attachmentBuckets = {
    65536,
    262144,
    1048576,
    4194304,
    16777216,
    67108864,
  };

  static const smallJson = PayloadLimits(
    maximumRequestBytes: 64 * 1024,
    maximumResponseBytes: 64 * 1024,
  );
  static const backupJson = PayloadLimits(
    maximumRequestBytes: 1500 * 1024,
    maximumResponseBytes: 1500 * 1024,
  );
  static const prekeyJson = PayloadLimits(
    maximumRequestBytes: 256 * 1024,
    maximumResponseBytes: 64 * 1024,
  );
  static const keyPackageJson = PayloadLimits(
    maximumRequestBytes: 3 * 1024 * 1024,
    maximumResponseBytes: 3 * 1024 * 1024,
  );
  static const envelopeBatchJson = PayloadLimits(
    maximumRequestBytes: 90 * 1024 * 1024,
    maximumResponseBytes: 64 * 1024,
  );
  static const envelopeDrainJson = PayloadLimits(
    maximumRequestBytes: 0,
    maximumResponseBytes: 40 * 1024 * 1024,
  );
}

final class ApiRequest<T> {
  ApiRequest({
    required this.method,
    required this.path,
    required this.decode,
    required this.acceptedStatusCodes,
    required this.authentication,
    required this.limits,
    this.operation = NetworkOperation.api,
    this.replaySafety = ReplaySafety.never,
    this.queryParameters = const {},
    this.headers = const {},
    this.body,
    this.timeouts = const NetworkTimeouts(),
    this.decodeWithHeaders,
  }) {
    if (!path.startsWith('/api/v1/') || Uri.parse(path).hasQuery) {
      throw ArgumentError.value(path, 'path', 'must be an /api/v1/ path');
    }
    if (replaySafety == ReplaySafety.readOnly &&
        method != RestMethod.get &&
        method != RestMethod.head) {
      throw ArgumentError('readOnly replay safety requires GET or HEAD');
    }
    if (headers.keys.any((name) => name.toLowerCase() != 'if-none-match')) {
      throw ArgumentError.value(
        headers,
        'headers',
        'contains an unsafe header',
      );
    }
  }

  final RestMethod method;
  final String path;
  final T Function(Object? json) decode;
  final Set<int> acceptedStatusCodes;
  final AuthenticationRequirement authentication;
  final PayloadLimits limits;
  final NetworkOperation operation;
  final ReplaySafety replaySafety;
  final Map<String, Object?> queryParameters;
  final Map<String, String> headers;
  final Object? body;
  final NetworkTimeouts timeouts;
  final T Function(Object? json, Map<String, List<String>> headers)?
  decodeWithHeaders;

  bool get canReplay => replaySafety != ReplaySafety.never;
}
