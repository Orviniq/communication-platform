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
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
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
          tokens: _FullTokenCoordinator(),
          config: const FixedServerConfig.fallback(),
          allowance: _RecordingAllowance(),
          clock: const _FixedClock(),
          storage: const _UnusedStorage(),
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

    test('the upload reads the code, because two pairs share a status', () async {
      // `413` is the day's allowance and it is also a body above the route's
      // cap; `503` is the operator's disk and it is also an outage. The screen
      // says something different for each, and the sync engine retires a body
      // that is too large while holding one the day refused — so a status read
      // without its code would be a coin toss between them.
      const refusals = <(int, String, BackendFailureCode)>[
        (413, 'quota_exceeded', BackendFailureCode.quotaExceeded),
        (413, 'payload_too_large', BackendFailureCode.payloadTooLarge),
        (503, 'storage_full', BackendFailureCode.storageFull),
        (503, 'unavailable', BackendFailureCode.unavailable),
      ];
      final root = await Directory.systemTemp.createTemp('cp_refusal_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final file = File('${root.path}/blob')
        ..writeAsBytesSync(Uint8List(65536));

      for (final (status, wire, expected) in refusals) {
        final dio = Dio();
        dio.httpClientAdapter = _QueueAdapter([
          (options, requestStream, cancelFuture) async {
            await requestStream?.drain<void>();
            return ResponseBody.fromString(
              '{"code":"$wire","detail":"sensitive"}',
              status,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            );
          },
        ]);
        final allowance = _RecordingAllowance();
        final transport = DioAttachmentTransport(
          tokens: _FullTokenCoordinator(),
          config: const FixedServerConfig.fallback(),
          allowance: allowance,
          clock: const _FixedClock(),
          storage: const _UnusedStorage(),
          dio: dio,
        );

        final result = await transport.upload(
          encryptedFile: file,
          bucketSize: 65536,
        );

        final failure =
            (result as FailureResult<AttachmentUploadResponse>).failure;
        expect(
          failure,
          isA<BackendFailure>().having((value) => value.code, 'code', expected),
          reason: wire,
        );
        expect(failure.toString(), isNot(contains('sensitive')));
        // A refusal spends nothing, whichever of the four it was.
        expect(allowance.recorded, isEmpty, reason: wire);
      }
    });

    test('what is left of the day is read before the bytes are sent', () async {
      final dio = Dio();
      dio.httpClientAdapter = _QueueAdapter([]);
      // The default allowance is 256 MiB and this day has spent all but 32 KiB
      // of it, so a 64 KiB bucket cannot fit. Nothing reaches the wire: the
      // refusal is the same one the server would have sent, arrived at without
      // spending the upload to discover it.
      final allowance = _RecordingAllowance(spentBytes: 268435456 - 32768);
      final transport = DioAttachmentTransport(
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: allowance,
        clock: const _FixedClock(),
        storage: const _UnusedStorage(),
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
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: allowance,
        clock: const _FixedClock(),
        storage: const _UnusedStorage(),
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

    test('maps expired capability to not-found and keeps no bytes', () async {
      final root = await Directory.systemTemp.createTemp('cp_expired_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final dio = Dio();
      dio.httpClientAdapter = _QueueAdapter([
        (options, requestStream, cancelFuture) async =>
            ResponseBody.fromString('', 404),
      ]);
      final transport = DioAttachmentTransport(
        tokens: _FullTokenCoordinator(),
        config: const FixedServerConfig.fallback(),
        allowance: _RecordingAllowance(),
        clock: const _FixedClock(),
        storage: PrivateAttachmentStorage(root: root),
        dio: dio,
      );
      final result = await transport.download(
        capabilityId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        expectedBucketSize: 65536,
      );

      final failure = (result as FailureResult<File>).failure;
      expect(
        failure,
        isA<BackendFailure>().having(
          (value) => value.code,
          'code',
          BackendFailureCode.notFound,
        ),
      );
      expect(root.listSync(), isEmpty);
    });
  });

  group('a large download resumes where it stopped (ADR-083)', () {
    const capability = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const bucket = 16777216;
    const tag = '"66f9a1b2-1000000"';
    const moved = '"66f9c3d4-1000000"';
    const dropped = HttpException('Connection closed while receiving data');
    late Directory root;
    late Uint8List object;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cp_resume_test_');
      // Every byte depends on its position, so bytes continued from the wrong
      // offset cannot come out equal by accident.
      object = Uint8List(bucket);
      for (var index = 0; index < bucket; index += 1) {
        object[index] = (index ^ (index >> 8) ^ (index >> 16)) & 0xff;
      }
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    ({DioAttachmentTransport transport, _QueueAdapter server}) serve(
      List<_AdapterHandler> answers,
    ) {
      final server = _QueueAdapter(answers);
      return (
        transport: DioAttachmentTransport(
          tokens: _FullTokenCoordinator(),
          config: const FixedServerConfig.fallback(),
          allowance: _RecordingAllowance(),
          clock: const _FixedClock(),
          storage: PrivateAttachmentStorage(root: root),
          dio: Dio()..httpClientAdapter = server,
        ),
        server: server,
      );
    }

    // The whole object under [etag], cut off after [bytes] by a connection
    // that drops.
    _AdapterHandler dropsAfter(int bytes, {String? etag = tag}) =>
        (options, requestStream, cancelFuture) async => _streamed(
          [Uint8List.sublistView(object, 0, bytes)],
          200,
          headers: {
            'accept-ranges': ['bytes'],
            if (etag != null) 'etag': [etag],
          },
          thenFail: dropped,
        );

    // The rest of the object from [offset], as nginx answers a range.
    _AdapterHandler continuesFrom(
      int offset, {
      String etag = tag,
      String? range,
    }) =>
        (options, requestStream, cancelFuture) async => _streamed(
          [Uint8List.sublistView(object, offset)],
          206,
          headers: {
            'etag': [etag],
            'content-range': [range ?? 'bytes $offset-${bucket - 1}/$bucket'],
          },
        );

    _AdapterHandler whole({String etag = tag}) =>
        (options, requestStream, cancelFuture) async => _streamed(
          [object],
          200,
          headers: {
            'etag': [etag],
          },
        );

    _AdapterHandler refuses(int status) =>
        (options, requestStream, cancelFuture) async =>
            ResponseBody.fromString('', status);

    Future<Result<File>> fetch(
      DioAttachmentTransport transport, {
      CancellationSignal? cancellation,
      void Function(int bytes)? onProgress,
    }) => transport.download(
      capabilityId: capability,
      expectedBucketSize: bucket,
      cancellation: cancellation,
      onProgress: onProgress,
    );

    List<String> kept() => [
      for (final entry in root.listSync()) entry.uri.pathSegments.last,
    ];

    test('only the two largest buckets resume', () {
      expect(DioAttachmentTransport.resumableBuckets, {16777216, 67108864});
    });

    test(
      'a dropped download is taken up from the byte it stopped at',
      () async {
        const stoppedAt = 5 * 1048576;
        final (:transport, :server) = serve([
          dropsAfter(stoppedAt),
          continuesFrom(stoppedAt),
        ]);

        final first = await fetch(transport);

        expect(
          (first as FailureResult<File>).failure,
          isA<TransportFailure>().having(
            (failure) => failure.kind,
            'kind',
            TransportFailureKind.offline,
          ),
        );
        expect(server.requests.single.headers['Range'], isNull);
        expect(kept(), hasLength(1), reason: 'the bytes it fetched are kept');

        final progress = <int>[];
        final second = await fetch(transport, onProgress: progress.add);

        final file = (second as Success<File>).value;
        expect(server.requests[1].headers['Range'], 'bytes=$stoppedAt-');
        expect(server.requests[1].headers['If-Range'], tag);
        expect(progress, [bucket], reason: 'counted from where it stopped');
        expect(await file.length(), bucket);
        expect(listEquals(await file.readAsBytes(), object), isTrue);
        expect(kept(), [file.uri.pathSegments.last]);
      },
    );

    test('a whole answer to a range starts the file again', () async {
      final (:transport, :server) = serve([dropsAfter(1048576), whole()]);
      await fetch(transport);

      final second = await fetch(transport);

      // Appended to what was kept, the object would run a mebibyte past the
      // bucket and be refused as too large.
      final file = (second as Success<File>).value;
      expect(server.requests[1].headers['Range'], 'bytes=1048576-');
      expect(await file.length(), bucket);
      expect(listEquals(await file.readAsBytes(), object), isTrue);
    });

    test(
      'a tag that moved reports the attachment gone and keeps nothing',
      () async {
        for (final answer in [
          whole(etag: moved),
          continuesFrom(1048576, etag: moved),
        ]) {
          final (:transport, :server) = serve([
            dropsAfter(1048576),
            answer,
            refuses(404),
          ]);
          await fetch(transport);

          final second = await fetch(transport);

          expect(
            (second as FailureResult<File>).failure,
            isA<BackendFailure>().having(
              (failure) => failure.code,
              'code',
              BackendFailureCode.notFound,
            ),
          );
          expect(kept(), isEmpty);
          await fetch(transport);
          expect(server.requests[2].headers['Range'], isNull);
        }
      },
    );

    test('a refusal or a cancellation keeps the bytes', () async {
      const stoppedAt = 1048576;
      final cancellation = CancellationSignal();
      final (:transport, :server) = serve([
        (options, requestStream, cancelFuture) async => _streamed(
          [
            Uint8List.sublistView(object, 0, stoppedAt),
            Uint8List.sublistView(object, stoppedAt),
          ],
          200,
          headers: {
            'etag': [tag],
          },
        ),
        refuses(429),
        continuesFrom(stoppedAt),
      ]);

      // Cancelled as soon as the first mebibyte is on disk.
      final cancelled = await fetch(
        transport,
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );
      final throttled = await fetch(transport);
      final resumed = await fetch(transport);

      expect(
        (cancelled as FailureResult<File>).failure,
        isA<CancellationFailure>(),
      );
      expect(
        (throttled as FailureResult<File>).failure,
        isA<BackendFailure>().having(
          (failure) => failure.code,
          'code',
          BackendFailureCode.throttled,
        ),
      );
      expect(server.requests[1].headers['Range'], 'bytes=$stoppedAt-');
      expect(server.requests[2].headers['Range'], 'bytes=$stoppedAt-');
      final file = (resumed as Success<File>).value;
      expect(listEquals(await file.readAsBytes(), object), isTrue);
    });

    test('a 404 or a 416 to a resume keeps nothing', () async {
      for (final status in [404, 416]) {
        final (:transport, :server) = serve([
          dropsAfter(1048576),
          refuses(status),
          refuses(404),
        ]);
        await fetch(transport);

        final second = await fetch(transport);

        expect(second, isA<FailureResult<File>>(), reason: '$status');
        expect(server.requests[1].headers['Range'], 'bytes=1048576-');
        expect(kept(), isEmpty, reason: '$status');
        await fetch(transport);
        expect(server.requests[2].headers['Range'], isNull, reason: '$status');
      }
    });

    test('a continuation that breaks the length rule keeps nothing', () async {
      const stoppedAt = 1048576;
      final continuations = <(_AdapterHandler, Matcher)>[
        // Bytes from the start of the object, offered as a continuation.
        (
          continuesFrom(stoppedAt, range: 'bytes 0-${bucket - 1}/$bucket'),
          isA<SecurityFailure>().having(
            (failure) => failure.kind,
            'kind',
            SecurityFailureKind.malformedServerResponse,
          ),
        ),
        // The right range, and one byte past the bucket.
        (
          (options, requestStream, cancelFuture) async => _streamed(
            [Uint8List.sublistView(object, stoppedAt), Uint8List(1)],
            206,
            headers: {
              'etag': [tag],
              'content-range': ['bytes $stoppedAt-${bucket - 1}/$bucket'],
            },
          ),
          isA<TransportFailure>().having(
            (failure) => failure.kind,
            'kind',
            TransportFailureKind.responseTooLarge,
          ),
        ),
      ];
      for (final (answer, failure) in continuations) {
        final (:transport, :server) = serve([dropsAfter(stoppedAt), answer]);
        await fetch(transport);

        final second = await fetch(transport);

        expect((second as FailureResult<File>).failure, failure);
        expect(kept(), isEmpty);
      }
    });

    test('the four small buckets start again from zero', () async {
      for (final small in [65536, 262144, 1048576, 4194304]) {
        final smallObject = Uint8List.sublistView(object, 0, small);
        final (:transport, :server) = serve([
          (options, requestStream, cancelFuture) async => _streamed(
            [Uint8List.sublistView(smallObject, 0, small ~/ 2)],
            200,
            headers: {
              'etag': [tag],
            },
            thenFail: dropped,
          ),
          (options, requestStream, cancelFuture) async => _streamed(
            [smallObject],
            200,
            headers: {
              'etag': [tag],
            },
          ),
        ]);

        final first = await transport.download(
          capabilityId: capability,
          expectedBucketSize: small,
        );

        expect(first, isA<FailureResult<File>>(), reason: '$small');
        expect(kept(), isEmpty, reason: '$small');
        final second = await transport.download(
          capabilityId: capability,
          expectedBucketSize: small,
        );
        expect(server.requests[1].headers['Range'], isNull, reason: '$small');
        final file = (second as Success<File>).value;
        expect(await file.length(), small);
        await file.delete();
      }
    });

    test('an answer without a strong tag cannot be taken up again', () async {
      for (final etag in [null, 'W/"66f9a1b2-1000000"']) {
        final (:transport, :server) = serve([
          dropsAfter(1048576, etag: etag),
          whole(),
        ]);
        await fetch(transport);

        expect(kept(), isEmpty, reason: '$etag');
        final second = await fetch(transport);
        expect(server.requests[1].headers['Range'], isNull, reason: '$etag');
        expect(server.requests[1].headers['If-Range'], isNull, reason: '$etag');
        await (second as Success<File>).value.delete();
      }
    });
  });

  group('the transfer service and the file a download hands it', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cp_transfer_test_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('decrypts the file it is handed, then deletes it', () async {
      final crypto = AttachmentCryptoService(_RecordingCryptoPort());
      final plaintext = Uint8List(70000);
      for (var index = 0; index < plaintext.length; index += 1) {
        plaintext[index] = index & 0xff;
      }
      final fetched = File('${root.path}/fetched.bin');
      final encrypted = await crypto.encryptToFile(
        source: AttachmentSource(
          length: plaintext.length,
          displayName: 'notes.txt',
          mimeType: 'text/plain',
          openRead: () => Stream.value(plaintext),
        ),
        destination: fetched,
      );
      final descriptor = (encrypted as Success<AttachmentDescriptor>).value
          .withCapability('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      final service = AttachmentTransferService(
        crypto: crypto,
        transport: _HandingTransport(Result.success(fetched)),
        storage: PrivateAttachmentStorage(root: root),
      );

      final result = await service.downloadAndDecrypt(descriptor: descriptor);

      final decrypted = (result as Success<File>).value;
      expect(await decrypted.readAsBytes(), plaintext);
      expect(await fetched.exists(), isFalse);
    });

    test('leaves what a failed download fetched to the transport', () async {
      final service = AttachmentTransferService(
        crypto: AttachmentCryptoService(_RecordingCryptoPort()),
        transport: _HandingTransport(
          const Result.failure(TransportFailure(TransportFailureKind.offline)),
        ),
        storage: PrivateAttachmentStorage(root: root),
      );

      final result = await service.downloadAndDecrypt(
        descriptor: _descriptor(plaintextSize: 10),
      );

      expect((result as FailureResult<File>).failure, isA<TransportFailure>());
      expect(root.listSync(), isEmpty);
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
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handlers[calls++](options, requestStream, cancelFuture);
  }

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

/// An answer whose body is [chunks], followed by [thenFail] when one is given:
/// the way a connection that drops part-way reaches the transport, because
/// Dio passes an error on the body stream through as it is.
ResponseBody _streamed(
  List<Uint8List> chunks,
  int status, {
  Map<String, List<String>> headers = const {},
  Exception? thenFail,
}) {
  Stream<Uint8List> body() async* {
    for (final chunk in chunks) {
      yield chunk;
    }
    if (thenFail != null) {
      throw thenFail;
    }
  }

  return ResponseBody(body(), status, headers: headers);
}

/// Hands the transfer service one fixed answer to every download.
final class _HandingTransport implements AttachmentTransportPort {
  _HandingTransport(this.answer);

  final Result<File> answer;

  @override
  Future<Result<File>> download({
    required String capabilityId,
    required int expectedBucketSize,
    CancellationSignal? cancellation,
    void Function(int bytes)? onProgress,
  }) async => answer;

  @override
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
  }) => throw UnimplementedError('this test only downloads');
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

/// Storage for a test that must make no temporary file: an upload reads the
/// encrypted file it is handed and writes none.
final class _UnusedStorage implements AttachmentStoragePort {
  const _UnusedStorage();

  @override
  Future<File> createEncryptedTemp() => throw StateError('unused');

  @override
  Future<File> createDecryptedTemp() => throw StateError('unused');

  @override
  Future<void> delete(File file) => throw StateError('unused');
}
