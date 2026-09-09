import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/server_config_api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `GET /api/v1/config` answers, and what this client will accept as an
/// answer.
///
/// The body below is the one printed in `backend/core/API.md`, field for field.
/// It is pinned here rather than built from the domain fallback so that a
/// change to either one has to be reconciled against the contract instead of
/// silently agreeing with itself.
void main() {
  Map<String, Object?> body() => <String, Object?>{
    'envelope_ttl_days': 7,
    'attachment_ttl_days': 30,
    'attachment_daily_bytes': 268435456,
    'mailbox_max_bytes': 33554432,
    'max_devices_per_user': 10,
    'max_devicelog_records': 10000,
    'session_token_days': 30,
    'send_batch_max': 256,
    'ack_max': 200,
    'drain_page_max': 100,
    'claim_max': 100,
    'envelope_buckets': [1024, 4096, 16384, 65536, 262144],
    'attachment_buckets': [65536, 262144, 1048576, 4194304, 16777216, 67108864],
    'signal_buckets': [1024, 4096, 16384],
    'voice_configured': true,
  };

  group('a full ConfigOut body', () {
    test('parses into all fifteen fields', () {
      final config = ServerConfigResponseDto.fromJson(body()).config;

      expect(config.envelopeTtlDays, 7);
      expect(config.attachmentTtlDays, 30);
      expect(config.attachmentDailyBytes, 268435456);
      expect(config.mailboxMaxBytes, 33554432);
      expect(config.maxDevicesPerUser, 10);
      expect(config.maxDeviceLogRecords, 10000);
      expect(config.sessionTokenDays, 30);
      expect(config.sendBatchMax, 256);
      expect(config.ackMax, 200);
      expect(config.drainPageMax, 100);
      expect(config.claimMax, 100);
      expect(config.envelopeBuckets, {1024, 4096, 16384, 65536, 262144});
      expect(config.attachmentBuckets, {
        65536,
        262144,
        1048576,
        4194304,
        16777216,
        67108864,
      });
      expect(config.signalBuckets, {1024, 4096, 16384});
      expect(config.voiceConfigured, isTrue);
    });

    test('differs from the fallback in exactly one field', () {
      // The fallback is meant to be the deployment defaults this document
      // prints, so a default deployment publishes what the client already
      // assumed. `voice_configured` is the deliberate exception: the client
      // assumes no voice until a deployment says otherwise, and the body in the
      // document says otherwise.
      final config = ServerConfigResponseDto.fromJson(body()).config;

      expect(config, isNot(ServerConfig.fallback));
      // Where the answer came from is not one of the published fields, and it
      // is the whole difference between a default deployment's answer and the
      // constants this build starts on. Everything else is equal.
      expect(config.fromDeployment, isTrue);
      expect(ServerConfig.fallback.fromDeployment, isFalse);
      expect(
        ServerConfigResponseDto.fromJson(
          body()..['voice_configured'] = false,
        ).config,
        _asStoredAnswer(ServerConfig.fallback),
      );
    });

    test('survives a round trip through its own encoding', () {
      final parsed = ServerConfigResponseDto.fromJson(body()).config;

      final encoded = ServerConfigResponseDto(parsed).toJson();

      expect(encoded, body());
      expect(ServerConfigResponseDto.fromJson(encoded).config, parsed);
    });

    test('a sixteenth field the server grows is ignored, not refused', () {
      // `ConfigOut` declares no `additionalProperties: false`. Refusing the
      // body would throw away `envelope_ttl_days`, the one value with no other
      // observable, because the server had published something new.
      final grown = body()..['something_later'] = 1;

      expect(ServerConfigResponseDto.fromJson(grown).config.envelopeTtlDays, 7);
    });
  });

  group('a body this client will not accept', () {
    test('is not an object at all', () {
      expect(
        () => ServerConfigResponseDto.fromJson(const <Object?>[]),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    for (final field in const [
      'envelope_ttl_days',
      'attachment_ttl_days',
      'attachment_daily_bytes',
      'mailbox_max_bytes',
      'max_devices_per_user',
      'max_devicelog_records',
      'session_token_days',
      'send_batch_max',
      'ack_max',
      'drain_page_max',
      'claim_max',
      'envelope_buckets',
      'attachment_buckets',
      'signal_buckets',
      'voice_configured',
    ]) {
      test('is missing $field', () {
        final missing = body()..remove(field);

        expect(
          () => ServerConfigResponseDto.fromJson(missing),
          throwsA(isA<MalformedApiBody>()),
        );
      });
    }

    test('states a limit as zero', () {
      // Zero bounds the client to nothing: a `send_batch_max` of 0 carries no
      // message. The body is refused so the caller keeps what it held.
      final zero = body()..['send_batch_max'] = 0;

      expect(
        () => ServerConfigResponseDto.fromJson(zero),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('states a limit as a string', () {
      final text = body()..['ack_max'] = '200';

      expect(
        () => ServerConfigResponseDto.fromJson(text),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('states a limit as a fraction', () {
      final fraction = body()..['drain_page_max'] = 100.5;

      expect(
        () => ServerConfigResponseDto.fromJson(fraction),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('publishes an empty bucket set', () {
      final empty = body()..['signal_buckets'] = const <int>[];

      expect(
        () => ServerConfigResponseDto.fromJson(empty),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('publishes a bucket twice', () {
      final duplicated = body()..['signal_buckets'] = const [1024, 1024];

      expect(
        () => ServerConfigResponseDto.fromJson(duplicated),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('publishes a bucket that is not a size', () {
      final zero = body()..['envelope_buckets'] = const [0, 4096];

      expect(
        () => ServerConfigResponseDto.fromJson(zero),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('states voice as a number', () {
      final numeric = body()..['voice_configured'] = 1;

      expect(
        () => ServerConfigResponseDto.fromJson(numeric),
        throwsA(isA<MalformedApiBody>()),
      );
    });
  });

  group('bucket sets', () {
    test('are ordered by size whatever order they arrive in', () {
      final shuffled = body()
        ..['attachment_buckets'] = const [
          67108864,
          65536,
          1048576,
          262144,
          16777216,
          4194304,
        ];

      final config = ServerConfigResponseDto.fromJson(shuffled).config;

      expect(config.attachmentBuckets.toList(), const [
        65536,
        262144,
        1048576,
        4194304,
        16777216,
        67108864,
      ]);
      // Which is what makes the largest bucket readable as the last one: it is
      // the ceiling an upload is measured against.
      expect(config.largestAttachmentBucket, 67108864);
    });

    test('cannot be modified through the parsed value', () {
      final config = ServerConfigResponseDto.fromJson(body()).config;

      expect(() => config.envelopeBuckets.add(2048), throwsUnsupportedError);
    });
  });
}

/// The same limits, said to have come from the deployment rather than from this
/// build. `fromDeployment` is not on the wire and cannot be, so a body parsed
/// from the route always carries it and a constant never does.
ServerConfig _asStoredAnswer(ServerConfig config) => ServerConfig(
  envelopeTtlDays: config.envelopeTtlDays,
  attachmentTtlDays: config.attachmentTtlDays,
  attachmentDailyBytes: config.attachmentDailyBytes,
  mailboxMaxBytes: config.mailboxMaxBytes,
  maxDevicesPerUser: config.maxDevicesPerUser,
  maxDeviceLogRecords: config.maxDeviceLogRecords,
  sessionTokenDays: config.sessionTokenDays,
  sendBatchMax: config.sendBatchMax,
  ackMax: config.ackMax,
  drainPageMax: config.drainPageMax,
  claimMax: config.claimMax,
  envelopeBuckets: config.envelopeBuckets,
  attachmentBuckets: config.attachmentBuckets,
  signalBuckets: config.signalBuckets,
  voiceConfigured: config.voiceConfigured,
  fromDeployment: true,
);
