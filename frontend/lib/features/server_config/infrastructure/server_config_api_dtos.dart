import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';

/// The `ConfigOut` body of `GET /api/v1/config`, and the shape the answer is
/// stored in.
///
/// Parsing and encoding sit together on purpose: the durable row holds the wire
/// object verbatim, so one parser establishes the invariants for both, and a
/// stored row this build cannot read fails exactly the way a malformed body
/// does.
///
/// All fifteen fields are required by the contract and every one of them is
/// checked. An unknown sixteenth is ignored rather than refused: `ConfigOut`
/// declares no `additionalProperties: false`, and a client that threw away
/// `envelope_ttl_days` because the server had grown a field would lose the one
/// value it cannot obtain any other way.
final class ServerConfigResponseDto {
  const ServerConfigResponseDto(this.config);

  factory ServerConfigResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    return ServerConfigResponseDto(
      ServerConfig(
        envelopeTtlDays: _positiveInt(json['envelope_ttl_days']),
        attachmentTtlDays: _positiveInt(json['attachment_ttl_days']),
        attachmentDailyBytes: _positiveInt(json['attachment_daily_bytes']),
        mailboxMaxBytes: _positiveInt(json['mailbox_max_bytes']),
        maxDevicesPerUser: _positiveInt(json['max_devices_per_user']),
        maxDeviceLogRecords: _positiveInt(json['max_devicelog_records']),
        sessionTokenDays: _positiveInt(json['session_token_days']),
        sendBatchMax: _positiveInt(json['send_batch_max']),
        ackMax: _positiveInt(json['ack_max']),
        drainPageMax: _positiveInt(json['drain_page_max']),
        claimMax: _positiveInt(json['claim_max']),
        envelopeBuckets: _buckets(json['envelope_buckets']),
        attachmentBuckets: _buckets(json['attachment_buckets']),
        signalBuckets: _buckets(json['signal_buckets']),
        voiceConfigured: _boolean(json['voice_configured']),
        // Anything this parses came from the route, whether it arrived just now
        // or was stored by an earlier session that read it. There is no other
        // way to reach a `ServerConfig` with this set.
        fromDeployment: true,
      ),
    );
  }

  final ServerConfig config;

  Map<String, Object?> toJson() => <String, Object?>{
    'envelope_ttl_days': config.envelopeTtlDays,
    'attachment_ttl_days': config.attachmentTtlDays,
    'attachment_daily_bytes': config.attachmentDailyBytes,
    'mailbox_max_bytes': config.mailboxMaxBytes,
    'max_devices_per_user': config.maxDevicesPerUser,
    'max_devicelog_records': config.maxDeviceLogRecords,
    'session_token_days': config.sessionTokenDays,
    'send_batch_max': config.sendBatchMax,
    'ack_max': config.ackMax,
    'drain_page_max': config.drainPageMax,
    'claim_max': config.claimMax,
    'envelope_buckets': config.envelopeBuckets.toList(growable: false),
    'attachment_buckets': config.attachmentBuckets.toList(growable: false),
    'signal_buckets': config.signalBuckets.toList(growable: false),
    'voice_configured': config.voiceConfigured,
  };
}

/// Every published limit bounds something the client then does, and zero bounds
/// it to nothing: a `send_batch_max` of 0 carries no message and a
/// `drain_page_max` of 0 drains no envelope. Refusing the value is refusing the
/// body, which leaves the caller on what it already stored.
int _positiveInt(Object? value) {
  if (value is! int || value < 1) {
    throw const MalformedApiBody();
  }
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) {
    throw const MalformedApiBody();
  }
  return value;
}

/// A bucket set is small, exact and fixed by the deployment. It is sorted here
/// rather than required to arrive sorted — the order is the server's tuple
/// order and nothing depends on the server keeping it — so that the largest
/// bucket is always the last one.
Set<int> _buckets(Object? value) {
  if (value is! List<Object?> || value.isEmpty || value.length > _maxBuckets) {
    throw const MalformedApiBody();
  }
  final sizes = <int>[];
  for (final size in value) {
    if (size is! int || size < 1 || sizes.contains(size)) {
      throw const MalformedApiBody();
    }
    sizes.add(size);
  }
  sizes.sort();
  return Set<int>.unmodifiable(sizes);
}

/// Six is the largest set the server defines. The ceiling is here so that a
/// body which is well-formed JSON but is not a bucket set cannot become a
/// collection the client then iterates.
const _maxBuckets = 64;
