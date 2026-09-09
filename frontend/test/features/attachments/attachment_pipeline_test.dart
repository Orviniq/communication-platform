import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/attachment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_transport.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('attachment header and sizing contract', () {
    test('matches the version-1 deterministic header vector', () {
      final header = _header(plaintextSize: 15, metadataHashByte: 0xea);
      final parsed = AttachmentHeaderV1.parse(header);

      expect(ascii.decode(header.sublist(0, 8)), 'CPAFV001');
      expect(parsed.chunkSize, 64 * 1024);
      expect(parsed.plaintextSize, 15);
      expect(parsed.streamSize, 32);
      expect(parsed.bucketSize, 65536);
      expect(parsed.metadataHash, everyElement(0xea));
      expect(attachmentBucketFor(65536), 262144);
      expect(() => attachmentBucketFor(67108864), throwsFormatException);
    });

    test(
      'rejects malicious names, MIME, dimensions, and non-smallest buckets',
      () {
        final descriptor = _descriptor(
          plaintextSize: 15,
          displayName: r'../../folder\payload.html',
          mimeType: 'text/html',
        );
        expect(descriptor.displayName, 'payload.html');
        expect(descriptor.mimeType, 'application/octet-stream');
        expect(descriptor.isInlineImage, isFalse);

        expect(
          () => _descriptor(plaintextSize: 15, bucketSize: 262144),
          throwsFormatException,
        );
        expect(
          () => _descriptor(plaintextSize: 15, width: 9000),
          throwsFormatException,
        );
      },
    );
  });

  group('bounded streaming pipeline', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('cp_attachment_test_');
    });

    tearDown(() async {
      if (await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    });

    test(
      'large input stays chunk bounded and round trips only after final tag',
      () async {
        final crypto = _RecordingCryptoPort();
        final service = AttachmentCryptoService(crypto);
        final plaintext = Uint8List(2 * 1024 * 1024 + 7);
        for (var index = 0; index < plaintext.length; index += 1) {
          plaintext[index] = index & 0xff;
        }
        final encrypted = File('${temporary.path}/encrypted.bin');
        final encryptedResult = await service.encryptToFile(
          source: AttachmentSource(
            length: plaintext.length,
            displayName: '../camera.jpg',
            mimeType: 'image/jpeg',
            mediaKind: AttachmentMediaKind.image,
            openRead: () => Stream.value(plaintext),
          ),
          destination: encrypted,
        );
        final descriptor =
            (encryptedResult as Success<AttachmentDescriptor>).value;

        expect(await encrypted.length(), descriptor.bucketSize);
        expect(
          descriptor.encryptedSize,
          encryptedStreamSize(plaintext.length, 65536),
        );
        expect(crypto.maximumPushBytes, lessThanOrEqualTo(65536));
        expect(crypto.pushCalls, greaterThan(20));

        final decrypted = File('${temporary.path}/decrypted.bin');
        final decryptedResult = await service.decryptStreamToFile(
          descriptor: descriptor,
          ciphertext: encrypted.openRead(),
          destination: decrypted,
        );
        expect(decryptedResult, isA<Success<void>>());
        expect(await decrypted.readAsBytes(), plaintext);
        expect(crypto.maximumPullBytes, lessThanOrEqualTo(65536 + 17));
        expect(crypto.lastPullWasFinal, isTrue);
      },
    );

    test(
      'truncation, reorder, corruption, and missing final tag wipe output',
      () async {
        final crypto = _RecordingCryptoPort();
        final service = AttachmentCryptoService(crypto);
        final plaintext = Uint8List(2 * 65536 + 31);
        final encrypted = File('${temporary.path}/encrypted.bin');
        final result = await service.encryptToFile(
          source: AttachmentSource(
            length: plaintext.length,
            displayName: 'document.pdf',
            mimeType: 'application/pdf',
            openRead: () => Stream.value(plaintext),
          ),
          destination: encrypted,
        );
        final descriptor = (result as Success<AttachmentDescriptor>).value;
        final original = await encrypted.readAsBytes();

        final truncated = Uint8List.fromList(
          original.sublist(0, original.length - 1),
        );
        await _expectCorruptAndWiped(
          service,
          descriptor,
          Stream.value(truncated),
          File('${temporary.path}/truncated.out'),
        );

        final corrupted = Uint8List.fromList(original)..[95] ^= 1;
        await _expectCorruptAndWiped(
          service,
          descriptor,
          Stream.value(corrupted),
          File('${temporary.path}/corrupt.out'),
        );

        const prefix = 66 + 24;
        const fullChunk = 65536 + 17;
        final reordered = BytesBuilder(copy: false)
          ..add(original.sublist(0, prefix))
          ..add(original.sublist(prefix + fullChunk, prefix + 2 * fullChunk))
          ..add(original.sublist(prefix, prefix + fullChunk))
          ..add(original.sublist(prefix + 2 * fullChunk));
        await _expectCorruptAndWiped(
          service,
          descriptor,
          Stream.value(reordered.takeBytes()),
          File('${temporary.path}/reordered.out'),
        );

        final missingFinal = Uint8List.fromList(original)
          ..[prefix + descriptor.encryptedSize - 1] = 0;
        await _expectCorruptAndWiped(
          service,
          descriptor,
          Stream.value(missingFinal),
          File('${temporary.path}/final.out'),
        );
      },
    );

    test('cancellation leaves no partial encrypted artifact', () async {
      final signal = CancellationSignal()..cancel();
      final destination = File('${temporary.path}/cancelled.bin');
      final result = await AttachmentCryptoService(_RecordingCryptoPort())
          .encryptToFile(
            source: AttachmentSource(
              length: 32,
              displayName: 'cancel.txt',
              mimeType: 'text/plain',
              openRead: () => Stream.value(Uint8List(32)),
            ),
            destination: destination,
            cancellation: signal,
          );

      expect(result, isA<FailureResult<AttachmentDescriptor>>());
      expect(await destination.exists(), isFalse);
    });
  });

  test(
    'cache evicts by bound, expires entries, and wipes owned files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cp_attachment_cache_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final storage = PrivateAttachmentStorage(root: root);
      final cache = BoundedAttachmentCache(
        storage: storage,
        maximumEntries: 2,
        maximumBytes: 20,
      );
      final files = <File>[];
      for (var index = 0; index < 3; index += 1) {
        final file = File('${root.path}/$index.bin')
          ..writeAsBytesSync(List.filled(8, index));
        files.add(file);
        await cache.put(
          attachmentId: 'id-$index',
          file: file,
          bytes: 8,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
        );
      }
      expect(await files.first.exists(), isFalse);
      expect(cache.totalBytes, 16);

      final expired = File('${root.path}/expired.bin')..writeAsBytesSync([1]);
      await cache.put(
        attachmentId: 'expired',
        file: expired,
        bytes: 1,
        expiresAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );
      expect(await cache.read('expired'), isNull);
      expect(await expired.exists(), isFalse);

      await cache.wipe();
      expect(cache.totalBytes, 0);
      expect(await files[1].exists(), isFalse);
      expect(await files[2].exists(), isFalse);
    },
  );

  group('backend attachment contract', () {
    test(
      'maps upload quota exhaustion without exposing backend detail',
      () async {
        final dio = Dio();
        dio.httpClientAdapter = _QueueAdapter([
          (options, requestStream, cancelFuture) async {
            await requestStream?.drain<void>();
            return ResponseBody.fromString(
              '{"code":"quota_exceeded","detail":"sensitive"}',
              413,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            );
          },
        ]);
        final transport = DioAttachmentTransport(
          serverOrigin: Uri.parse('https://chat.example.test'),
          tokens: _FullTokenCoordinator(),
          config: const FixedServerConfig.fallback(),
          allowance: _RecordingAllowance(),
          clock: const _FixedClock(),
          dio: dio,
        );
        final root = await Directory.systemTemp.createTemp('cp_quota_test_');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final file = File('${root.path}/blob')
          ..writeAsBytesSync(Uint8List(65536));

        final result = await transport.upload(
          encryptedFile: file,
          bucketSize: 65536,
        );
        final failure =
            (result as FailureResult<AttachmentUploadResponse>).failure;
        expect(
          failure,
          isA<BackendFailure>().having(
            (value) => value.code,
            'code',
            BackendFailureCode.quotaExceeded,
          ),
        );
        expect(failure.toString(), isNot(contains('sensitive')));
      },
    );

    test('what is left of the day is read before the bytes are sent', () async {
      final dio = Dio();
      dio.httpClientAdapter = _QueueAdapter([]);
      // The default allowance is 256 MiB and this day has spent all but 32 KiB
      // of it, so a 64 KiB bucket cannot fit. Nothing reaches the wire: the
      // refusal is the same one the server would have sent, arrived at without
      // spending the upload to discover it.
      final allowance = _RecordingAllowance(spentBytes: 268435456 - 32768);
      final transport = DioAttachmentTransport(
        serverOrigin: Uri.parse('https://chat.example.test'),
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: allowance,
        clock: const _FixedClock(),
        dio: dio,
      );
      final root = await Directory.systemTemp.createTemp('cp_allowance_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final file = File('${root.path}/blob')
        ..writeAsBytesSync(Uint8List(65536));

      final result = await transport.upload(
        encryptedFile: file,
        bucketSize: 65536,
      );

      expect(
        (result as FailureResult<AttachmentUploadResponse>).failure,
        isA<BackendFailure>().having(
          (value) => value.code,
          'code',
          BackendFailureCode.quotaExceeded,
        ),
      );
      expect(allowance.recorded, isEmpty);
    });

    test('a length outside the published buckets never leaves', () async {
      final dio = Dio();
      dio.httpClientAdapter = _QueueAdapter([]);
      final allowance = _RecordingAllowance();
      final transport = DioAttachmentTransport(
        serverOrigin: Uri.parse('https://chat.example.test'),
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: allowance,
        clock: const _FixedClock(),
        dio: dio,
      );
      final root = await Directory.systemTemp.createTemp('cp_bucket_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final file = File('${root.path}/blob')..writeAsBytesSync(Uint8List(4096));

      final result = await transport.upload(
        encryptedFile: file,
        bucketSize: 4096,
      );

      expect(
        (result as FailureResult<AttachmentUploadResponse>).failure,
        isA<ValidationFailure>(),
      );
      expect(allowance.recorded, isEmpty);
    });

    test('maps expired capability to not-found and writes no bytes', () async {
      final dio = Dio();
      dio.httpClientAdapter = _QueueAdapter([
        (options, requestStream, cancelFuture) async =>
            ResponseBody.fromString('', 404),
      ]);
      final transport = DioAttachmentTransport(
        serverOrigin: Uri.parse('https://chat.example.test'),
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: _RecordingAllowance(),
        clock: const _FixedClock(),
        dio: dio,
      );
      final sink = _CollectingSink();
      final result = await transport.download(
        capabilityId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        destination: sink,
        expectedBucketSize: 65536,
      );
      await sink.close();

      final failure = (result as FailureResult<void>).failure;
      expect(
        failure,
        isA<BackendFailure>().having(
          (value) => value.code,
          'code',
          BackendFailureCode.notFound,
        ),
      );
      expect(sink.bytes, isEmpty);
    });
  });
}

Future<void> _expectCorruptAndWiped(
  AttachmentCryptoService service,
  AttachmentDescriptor descriptor,
  Stream<List<int>> stream,
  File destination,
) async {
  final result = await service.decryptStreamToFile(
    descriptor: descriptor,
    ciphertext: stream,
    destination: destination,
  );
  expect(result, isA<FailureResult<void>>());
  expect(await destination.exists(), isFalse);
}

EncryptedAttachmentDescriptor _descriptor({
  required int plaintextSize,
  int? bucketSize,
  String displayName = 'file.txt',
  String mimeType = 'text/plain',
  int? width,
}) {
  final streamSize = encryptedStreamSize(plaintextSize, 65536);
  final bucket = bucketSize ?? attachmentBucketFor(plaintextSize);
  return EncryptedAttachmentDescriptor(
    capabilityId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    key: Uint8List(32),
    header: _header(plaintextSize: plaintextSize, bucketSize: bucket),
    secretstreamHeader: Uint8List(24),
    encryptedSize: streamSize,
    bucketSize: bucket,
    plaintextSize: plaintextSize,
    displayName: displayName,
    mimeType: mimeType,
    mediaKind: AttachmentMediaKind.file,
    width: width,
  );
}

Uint8List _header({
  required int plaintextSize,
  int? bucketSize,
  int metadataHashByte = 0,
}) {
  final streamSize = encryptedStreamSize(plaintextSize, 65536);
  final bucket = bucketSize ?? attachmentBucketFor(plaintextSize);
  final bytes = Uint8List(66);
  bytes.setAll(0, ascii.encode('CPAFV001'));
  bytes[8] = 1;
  final data = ByteData.sublistView(bytes);
  data.setUint32(10, 65536, Endian.big);
  data.setUint64(14, plaintextSize, Endian.big);
  data.setUint64(22, streamSize, Endian.big);
  data.setUint32(30, bucket, Endian.big);
  bytes.fillRange(34, 66, metadataHashByte);
  return bytes;
}

final class _RecordingCryptoPort implements AttachmentCryptoPort {
  Uint8List _metadata = Uint8List(0);
  int _pushSequence = 0;
  int _pullSequence = 0;
  int maximumPushBytes = 0;
  int maximumPullBytes = 0;
  int pushCalls = 0;
  bool lastPullWasFinal = false;

  @override
  Future<Result<AttachmentCryptoPushSession>> createPush({
    required int plaintextSize,
    required int bucketSize,
    required Uint8List metadata,
  }) async {
    _metadata = Uint8List.fromList(metadata);
    _pushSequence = 0;
    final streamSize = encryptedStreamSize(plaintextSize, 65536);
    return Result.success(
      AttachmentCryptoPushSession(
        handle: 1,
        key: Uint8List(32),
        header: _header(plaintextSize: plaintextSize, bucketSize: bucketSize),
        secretstreamHeader: Uint8List(24),
        plaintextSize: plaintextSize,
        streamSize: streamSize,
        bucketSize: bucketSize,
      ),
    );
  }

  @override
  Future<Result<Uint8List>> pushChunk({
    required AttachmentCryptoPushSession session,
    required Uint8List plaintext,
    required bool finalChunk,
  }) async {
    maximumPushBytes = maximumPushBytes < plaintext.length
        ? plaintext.length
        : maximumPushBytes;
    pushCalls += 1;
    final output = Uint8List(plaintext.length + 17)
      ..setRange(0, plaintext.length, plaintext)
      ..[plaintext.length] = _pushSequence & 0xff
      ..fillRange(
        plaintext.length + 1,
        plaintext.length + 16,
        _checksum(plaintext),
      )
      ..[plaintext.length + 16] = finalChunk ? 1 : 0;
    _pushSequence += 1;
    return Result.success(output);
  }

  @override
  Future<Result<AttachmentCryptoPullSession>> createPull({
    required Uint8List key,
    required Uint8List header,
    required Uint8List secretstreamHeader,
    required Uint8List metadata,
  }) async {
    if (!listEquals(metadata, _metadata)) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    _pullSequence = 0;
    lastPullWasFinal = false;
    return const Result.success(AttachmentCryptoPullSession(2));
  }

  @override
  Future<Result<AttachmentDecryptedChunk>> pullChunk({
    required AttachmentCryptoPullSession session,
    required Uint8List ciphertext,
  }) async {
    maximumPullBytes = maximumPullBytes < ciphertext.length
        ? ciphertext.length
        : maximumPullBytes;
    if (ciphertext.length < 17) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    final plaintextLength = ciphertext.length - 17;
    final plaintext = ciphertext.sublist(0, plaintextLength);
    if (ciphertext[plaintextLength] != (_pullSequence & 0xff)) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    final checksum = _checksum(plaintext);
    for (
      var index = plaintextLength + 1;
      index < plaintextLength + 16;
      index += 1
    ) {
      if (ciphertext[index] != checksum) {
        return const Result.failure(
          CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
        );
      }
    }
    final finalChunk = ciphertext.last == 1;
    lastPullWasFinal = finalChunk;
    _pullSequence += 1;
    return Result.success(
      AttachmentDecryptedChunk(plaintext: plaintext, finalChunk: finalChunk),
    );
  }

  @override
  Future<Result<void>> closeSession({
    required int handle,
    bool abort = false,
  }) async => const Result.success(null);

  @override
  Future<Result<Uint8List>> randomBytes(int length) async =>
      Result.success(Uint8List(length));
}

int _checksum(List<int> bytes) {
  var value = 0;
  for (final byte in bytes) {
    value = (value + byte) & 0xff;
  }
  return value;
}

typedef _AdapterHandler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture,
    );

final class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this.handlers);

  final List<_AdapterHandler> handlers;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handlers[calls++](options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) {}
}

final class _FullTokenCoordinator implements AccessTokenCoordinator {
  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(
        AccessToken(
          value: 'access',
          expiresAt: DateTime.utc(2100),
          scope: SessionScope.full,
        ),
      );

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken) =>
      accessToken();

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}
}

final class _CollectingSink implements IOSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  Uint8List get bytes => _builder.toBytes();

  @override
  void add(List<int> data) => _builder.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  @override
  void write(Object? object) => add(utf8.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => add([charCode]);

  @override
  void writeln([Object? object = '']) => write('$object\n');
}

/// A day's count held in memory, so a test can say what has already been spent.
final class _RecordingAllowance implements AttachmentAllowancePort {
  _RecordingAllowance({this.spentBytes = 0});

  int spentBytes;
  final List<int> recorded = [];

  @override
  Future<AttachmentDailyAllowance> read(DateTime now) async =>
      AttachmentDailyAllowance(day: utcDayOf(now), spentBytes: spentBytes);

  @override
  Future<void> record({required int bytes, required DateTime now}) async {
    recorded.add(bytes);
    spentBytes += bytes;
  }
}

final class _FixedClock implements TimeSource {
  const _FixedClock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 9, 12);
}
