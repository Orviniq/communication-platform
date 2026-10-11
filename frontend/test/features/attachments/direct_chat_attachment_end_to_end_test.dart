import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_downloads.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_uploads.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_upload_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_transport.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_allowance_store.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_application_fanout_adapter.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/attachment_crypto_fake.dart';
import '../../support/attachment_platform_fake.dart';
import '../../support/local_send_harness.dart';

/// ADR-089, end to end: a file one device picks reaches another device of the
/// direct chat, through one attachment server, and comes out as the same
/// bytes.
///
/// Device A is the local user of the send harness and device B its peer. Each
/// has its own database, private cache, file cache and transport, and they
/// share two things only: the in-memory server, and the crypto port. The Rust
/// core does not run in a host test; the fake stands for the one core both
/// devices run, and its pull refuses metadata other than its push's, so B
/// decrypts only with the descriptor A sent.
///
/// What crosses from A to B is the event A's send path encoded, applied to B
/// as an authenticated commit from A's user and device. The pairwise sealing
/// between them is not in this test.
void main() {
  // Two devices, so two databases at once: the point of this file.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final now = DateTime.utc(2026, 10, 11, 9);
  final conversationId = protocolBytesToHex(harnessConversationId);
  late Directory temporary;
  late _AttachmentServer server;
  late FakeAttachmentCryptoPort crypto;
  late _Clock clock;
  late _DeviceA a;
  late _DeviceB b;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('cp_end_to_end_');
    server = _AttachmentServer(Random(11));
    crypto = FakeAttachmentCryptoPort();
    clock = _Clock(now);
    a = _DeviceA(
      root: await _cacheRoot(temporary, 'a'),
      server: server,
      crypto: crypto,
      clock: clock,
    );
    b = _DeviceB(
      root: await _cacheRoot(temporary, 'b'),
      server: server,
      crypto: crypto,
      clock: clock,
    );
  });

  tearDown(() async {
    await a.close();
    await b.close();
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  /// Applies on B the event A's send path encoded last, as a commit from A.
  Future<ApplicationEventRecord> deliverLastToB() async {
    final sent = a.protocol.encoded.last;
    await applyCommit(
      b.database,
      ApplicationEventCommit(
        event: sent.event,
        canonicalBytes: sent.bytes,
        currentUserId: peerUserId,
        currentDeviceId: peerDeviceId,
        conversationKind: ConversationKind.direct.index,
        peerUserId: localUserId,
        localOrigin: false,
        authenticatedAt: now,
      ),
    );
    return sent.event;
  }

  /// A's reaction to [messageId], sent by A's send path and applied on B: a
  /// re-fold of the message on both devices.
  Future<void> reactFromA(Uint8List messageId) async {
    final reacted = await a.sender.setReaction(
      currentUserId: localUserId,
      currentDeviceId: localDeviceId,
      conversationId: conversationId,
      messageId: protocolBytesToHex(messageId),
      emoji: '\u{1F44D}',
    );
    expect(reacted, isA<Success<void>>());
    final event = await deliverLastToB();
    expect(event.kindValue, ApplicationEventKind.reactionSet.wireValue);
  }

  /// Sends a file of [length] bytes from A to B and answers what A picked
  /// and the body A's message carried.
  Future<_Sent> sendFromA({
    int length = 70000,
    String name = 'minutes.pdf',
    String caption = 'for Monday',
  }) async {
    final plaintext = Uint8List(length);
    for (var index = 0; index < length; index += 1) {
      plaintext[index] = (index ^ (index >> 8) ^ 0x5a) & 0xff;
    }
    final picked = await a.pick(name: name, bytes: plaintext);
    final job = a.uploads.enqueue(
      conversationId: conversationId,
      target: const AttachmentUploadTarget.direct(peerUserId),
      attachment: picked,
      caption: caption,
    );
    expect(job, isA<Success<AttachmentUploadJob>>());
    await _until(() => a.uploads.jobs.isEmpty);

    final event = await deliverLastToB();
    expect(event.kindValue, ApplicationEventKind.messageCreate.wireValue);
    expect(event.senderUserId, protocolUuidBytes(localUserId));
    expect(event.senderDeviceId, protocolUuidBytes(localDeviceId));
    return _Sent(plaintext: plaintext, body: event.body as MessageCreateBody);
  }

  Future<AttachmentLocalState?> rowOn(
    AttachmentLocalStatePort states,
    String attachmentId,
  ) async =>
      (await states.read(attachmentId) as Success<AttachmentLocalState?>).value;

  /// Downloads on B the attachment its row names, and answers the row after.
  Future<AttachmentLocalState?> downloadOnB(String attachmentId) async {
    final row = (await rowOn(b.states, attachmentId))!;
    b.downloads.download(messageId: row.messageId, descriptor: row.descriptor);
    await _until(() => b.downloads.jobs.isEmpty);
    return rowOn(b.states, attachmentId);
  }

  test('a file A picks reaches B, which downloads, verifies and decrypts '
      'the same bytes', () async {
    final sent = await sendFromA();

    // The message A sent names one attachment, which the server holds.
    final descriptor = sent.body.attachments.single;
    final id = descriptor.capabilityId;
    expect(sent.body.contentType, MessageContentType.attachment);
    expect(sent.body.text, 'for Monday');
    expect(server.stored.keys, [id]);
    expect(server.stored[id], hasLength(262144));
    expect(descriptor.plaintextSize, sent.plaintext.length);
    expect(descriptor.displayName, 'minutes.pdf');

    // A's own row is ready from its copy: nothing was downloaded.
    final own = (await rowOn(a.states, id))!;
    expect(own.state, AttachmentTransferState.ready);
    expect(own.expiresAt, now.add(const Duration(days: 7)));
    expect(await (await a.cache.peek(id))!.readAsBytes(), sent.plaintext);
    expect(server.downloads, isEmpty);

    // B's row comes from the commit alone, and it is not downloaded.
    final received = (await rowOn(b.states, id))!;
    expect(received.state, AttachmentTransferState.queued);
    expect(received.cacheId, isNull);
    expect(received.messageId, protocolBytesToHex(sent.body.messageId));
    expect(received.descriptor.displayName, 'minutes.pdf');
    expect(received.descriptor.caption, 'for Monday');
    expect(await b.cache.peek(id), isNull);

    final ready = (await downloadOnB(id))!;

    expect(server.downloads, [id]);
    expect(ready.state, AttachmentTransferState.ready);
    expect(ready.expiresAt, now.add(const Duration(days: 7)));
    final file = (await b.cache.peek(id))!;
    expect(await file.readAsBytes(), sent.plaintext);
    expect(file.path, endsWith('${Platform.pathSeparator}minutes.pdf'));
    expect(crypto.lastPullWasFinal, isTrue);
  });

  test('a reaction re-folds the message on B, and B keeps its file', () async {
    final sent = await sendFromA();
    final id = sent.body.attachments.single.capabilityId;
    final downloaded = (await downloadOnB(id))!;
    final file = (await b.cache.peek(id))!;

    await reactFromA(sent.body.messageId);

    final reactions = await b.database
        .select(b.database.messageReactions)
        .get();
    expect(reactions.single.messageId, downloaded.messageId);
    final kept = (await rowOn(b.states, id))!;
    expect(kept.state, AttachmentTransferState.ready);
    expect(kept.cacheId, downloaded.cacheId);
    expect(kept.expiresAt, downloaded.expiresAt);
    expect(await file.readAsBytes(), sent.plaintext);
    // A re-folded its own message too, and kept its own copy.
    expect((await rowOn(a.states, id))!.state, AttachmentTransferState.ready);
    expect(server.downloads, [id]);
  });

  test(
    'delete for me on B removes the row, and the next sweep the file',
    () async {
      final sent = await sendFromA();
      final id = sent.body.attachments.single.capabilityId;
      final messageId = (await downloadOnB(id))!.messageId;
      final file = (await b.cache.peek(id))!;

      final deleted = await b.manage.deleteForMe(messageId);

      expect(deleted, isA<Success<void>>());
      expect(b.sweep.requests, 1);
      // When the sweep was asked for, the row was gone and the file was not.
      expect(b.sweep.rowsBefore, [0]);
      expect(b.sweep.fileBefore, [true]);
      expect(await rowOn(b.states, id), isNull);
      expect(await file.exists(), isFalse);
      expect(await b.cache.peek(id), isNull);
      // A's copy is A's: B's deletion reaches neither A nor the server.
      expect((await rowOn(a.states, id))!.state, AttachmentTransferState.ready);
      expect(server.stored.keys, [id]);
    },
  );

  test(
    'a body the server forgot gives expired, which a re-fold keeps',
    () async {
      final sent = await sendFromA();
      final id = sent.body.attachments.single.capabilityId;
      server.forget(id);

      final expired = (await downloadOnB(id))!;

      expect(server.downloads, [id]);
      expect(expired.state, AttachmentTransferState.expired);
      expect(expired.cacheId, isNull);
      expect(await b.cache.peek(id), isNull);
      expect(b.files(), isEmpty);

      await reactFromA(sent.body.messageId);

      expect(
        (await rowOn(b.states, id))!.state,
        AttachmentTransferState.expired,
      );
      // And a tap on it now asks the server nothing.
      await downloadOnB(id);
      expect(server.downloads, [id]);
    },
  );
}

/// `<parent>/<name>/secure_attachment_cache`: a private cache root.
Future<Directory> _cacheRoot(Directory parent, String name) => Directory(
  [parent.path, name, privateAttachmentCacheName].join(Platform.pathSeparator),
).create(recursive: true);

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 1000; attempt += 1) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out');
}

final class _Sent {
  const _Sent({required this.plaintext, required this.body});

  final Uint8List plaintext;
  final MessageCreateBody body;
}

/// The sending device: the picker, the upload queue on the real transport,
/// and the send path that commits the message to its own database.
final class _DeviceA {
  _DeviceA({
    required this.root,
    required _AttachmentServer server,
    required FakeAttachmentCryptoPort crypto,
    required TimeSource clock,
  }) : database = LocalDatabase(NativeDatabase.memory()) {
    states = DriftAttachmentLocalState(database);
    cache = AttachmentFileCache(
      root: root,
      states: states,
      clock: clock,
      random: Random(21),
    );
    transport = _transport(database, root, server, clock);
    sender = SendConversationEvents(
      repository: DriftConversationDomainRepository(database),
      protocol: protocol,
      fanout: PairwiseApplicationFanoutAdapter(
        PairwiseFanoutCoordinator(
          store: DriftPairwiseTransportStore(database),
          liveDevices: _Unused(),
          claims: _Unused(),
          crypto: _Unused(),
          clock: clock,
        ),
      ),
      clock: clock,
      attachments: _Sweep(root, cache, holds, states),
    );
    uploads = AttachmentUploads(
      platform: platform,
      holds: holds,
      limits: () => (
        buckets: AttachmentCryptoProtocolV1.buckets.toSet(),
        dailyBytes: 268435456,
      ),
      clock: clock,
      files: () async => cache,
      allowance: () async => DriftAttachmentAllowanceStore(database),
      states: () async => states,
      transfer: () async => AttachmentTransferService(
        crypto: AttachmentCryptoService(crypto),
        transport: transport,
        storage: PrivateAttachmentStorage(root: root, random: Random(22)),
      ),
      messages: () async => _SendAttachments(sender),
      random: Random(23),
    );
  }

  final Directory root;
  final LocalDatabase database;
  final platform = FakeAttachmentPlatform();
  final holds = AttachmentOutgoingHolds();
  final protocol = _CapturingProtocol();
  late final DriftAttachmentLocalState states;
  late final AttachmentFileCache cache;
  late final DioAttachmentTransport transport;
  late final SendConversationEvents sender;
  late final AttachmentUploads uploads;
  var _copies = 0;

  /// A pick of [bytes] named [name], whose copy the picker writes into the
  /// private cache while it is open, as the Android side does.
  Future<PickedAttachment> pick({
    required String name,
    required Uint8List bytes,
  }) async {
    final answer = Completer<Result<PickedAttachment>>();
    platform.enqueuePick(answer.future);
    final picking = uploads.pick(AttachmentPickKind.file);
    await _until(() => platform.picks.length > _copies);
    _copies += 1;
    final copy = File(
      [
        root.path,
        'outgoing',
        _copies.toRadixString(16).padLeft(32, '0'),
        name,
      ].join(Platform.pathSeparator),
    );
    await copy.parent.create(recursive: true);
    await copy.writeAsBytes(bytes);
    answer.complete(
      Result.success(
        PickedAttachment(
          file: copy,
          displayName: name,
          mimeType: 'application/pdf',
          length: bytes.length,
          mediaKind: AttachmentMediaKind.file,
        ),
      ),
    );
    return ((await picking) as Success<PickedAttachment>).value;
  }

  Future<void> close() async {
    await uploads.close();
    await transport.close();
    await database.close();
  }
}

/// The receiving device: its projection of A's events, the download queue on
/// the real transport, and the deletions of its own conversation state.
final class _DeviceB {
  _DeviceB({
    required this.root,
    required _AttachmentServer server,
    required FakeAttachmentCryptoPort crypto,
    required TimeSource clock,
  }) : database = LocalDatabase(NativeDatabase.memory()) {
    states = DriftAttachmentLocalState(database);
    cache = AttachmentFileCache(
      root: root,
      states: states,
      clock: clock,
      random: Random(31),
    );
    transport = _transport(database, root, server, clock);
    downloads = AttachmentDownloads(
      holds: holds,
      files: () async => cache,
      states: () async => states,
      transfer: () async => AttachmentTransferService(
        crypto: AttachmentCryptoService(crypto),
        transport: transport,
        storage: PrivateAttachmentStorage(root: root, random: Random(32)),
      ),
    );
    sweep = _Sweep(root, cache, holds, states);
    manage = ManageLocalConversationState(
      DriftConversationDomainRepository(database),
      attachments: sweep,
    );
  }

  final Directory root;
  final LocalDatabase database;
  final holds = AttachmentOutgoingHolds();
  late final DriftAttachmentLocalState states;
  late final AttachmentFileCache cache;
  late final DioAttachmentTransport transport;
  late final AttachmentDownloads downloads;
  late final _Sweep sweep;
  late final ManageLocalConversationState manage;

  /// Every file in B's private cache, as paths below it.
  List<String> files() => [
    for (final entity in root.listSync(recursive: true))
      if (entity is File) entity.path.substring(root.path.length + 1),
  ];

  Future<void> close() async {
    await downloads.close();
    await transport.close();
    await database.close();
  }
}

/// A device's own transport, as the networking foundation builds it, on a
/// `Dio` whose adapter is the shared server.
DioAttachmentTransport _transport(
  LocalDatabase database,
  Directory root,
  _AttachmentServer server,
  TimeSource clock,
) => DioAttachmentTransport(
  tokens: const _FullTokens(),
  config: const FixedServerConfig.fallback(),
  allowance: DriftAttachmentAllowanceStore(database),
  clock: clock,
  storage: PrivateAttachmentStorage(root: root, random: Random(41)),
  dio: Dio()..httpClientAdapter = server,
);

/// The two attachment routes of the server, in memory.
///
/// `POST /api/v1/attachments` takes one multipart part named `blob`, stores
/// its bytes under a new 43-character id, and answers `201` with the id and
/// the size. A part that is not exactly one bucket long is `400 bad_bucket`.
/// `GET /api/v1/attachments/{id}` answers the stored bytes under a strong
/// `ETag`, and `404` once the id is forgotten, as after the retention sweep.
/// A request without the bearer token is `401`.
final class _AttachmentServer implements HttpClientAdapter {
  _AttachmentServer(this._random);

  static const _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  static final _download = RegExp(r'^/api/v1/attachments/([A-Za-z0-9_-]{43})$');

  final Random _random;

  /// Each stored body, by its id, in the order of upload.
  final stored = <String, Uint8List>{};

  /// The id of each `GET`, in order, answered or not.
  final downloads = <String>[];

  /// Deletes [id]'s body, as the retention sweep does.
  void forget(String id) => stored.remove(id);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await _read(requestStream);
    if (options.headers['Authorization'] != 'Bearer access') {
      return _json(401, {'code': 'invalid_token'});
    }
    final path = options.uri.path;
    if (options.method == 'POST' && path == '/api/v1/attachments') {
      return _upload(options, body);
    }
    final download = _download.firstMatch(path);
    if (options.method == 'GET' && download != null) {
      final id = download.group(1)!;
      downloads.add(id);
      final bytes = stored[id];
      if (bytes == null) {
        return ResponseBody.fromString('', 404);
      }
      return ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/octet-stream'],
          Headers.contentLengthHeader: ['${bytes.length}'],
          'accept-ranges': ['bytes'],
          'etag': ['"${id.substring(0, 12)}-${bytes.length}"'],
        },
      );
    }
    return ResponseBody.fromString('', 404);
  }

  ResponseBody _upload(RequestOptions options, Uint8List body) {
    final type =
        options.headers[Headers.contentTypeHeader] as String? ??
        options.contentType;
    final boundary = type == null
        ? null
        : RegExp(r'^multipart/form-data; boundary=(.+)$').firstMatch(type);
    final blob = boundary == null ? null : _blobPart(body, boundary.group(1)!);
    if (blob == null) {
      return _json(400, {'code': 'validation_failed'});
    }
    if (!AttachmentCryptoProtocolV1.buckets.contains(blob.length)) {
      return _json(400, {'code': 'bad_bucket'});
    }
    final id = String.fromCharCodes([
      for (var index = 0; index < 43; index += 1)
        _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
    ]);
    stored[id] = blob;
    return _json(201, {'attachment_id': id, 'size': blob.length});
  }

  @override
  void close({bool force = false}) {}
}

/// The bytes of the one part named `blob` in a multipart [body], or null when
/// there is no such part.
Uint8List? _blobPart(Uint8List body, String boundary) {
  final opening = ascii.encode('--$boundary\r\n');
  final closing = ascii.encode('\r\n--$boundary--');
  final headersEnd = _indexOf(body, ascii.encode('\r\n\r\n'), 0);
  if (headersEnd < 0 || _indexOf(body, opening, 0) != 0) {
    return null;
  }
  final headers = latin1.decode(body.sublist(opening.length, headersEnd));
  if (!headers.contains('name="blob"')) {
    return null;
  }
  final start = headersEnd + 4;
  final end = _indexOf(body, closing, start);
  if (end < 0 || _indexOf(body, closing, end + 1) >= 0) {
    return null;
  }
  return Uint8List.sublistView(body, start, end);
}

int _indexOf(Uint8List haystack, List<int> needle, int from) {
  outer:
  for (var index = from; index + needle.length <= haystack.length; index++) {
    for (var offset = 0; offset < needle.length; offset += 1) {
      if (haystack[index + offset] != needle[offset]) {
        continue outer;
      }
    }
    return index;
  }
  return -1;
}

Future<Uint8List> _read(Stream<Uint8List>? stream) async {
  final builder = BytesBuilder(copy: false);
  if (stream != null) {
    await for (final chunk in stream) {
      builder.add(chunk);
    }
  }
  return builder.takeBytes();
}

ResponseBody _json(int status, Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

final class _Clock implements TimeSource {
  const _Clock(this._now);

  final DateTime _now;

  @override
  DateTime now() => _now;
}

final class _FullTokens implements AccessTokenCoordinator {
  const _FullTokens();

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

/// A's application protocol: every event it encodes is kept, with the bytes
/// it answered, so the test can hand the same event to B.
final class _CapturingProtocol implements ApplicationProtocolPort {
  final encoded = <({ApplicationEventRecord event, Uint8List bytes})>[];
  var _events = 0;

  @override
  Future<Result<Uint8List>> encode(ApplicationEventRecord event) async {
    final bytes = Uint8List.fromList([1, 2, 3, ...event.eventId]);
    encoded.add((event: event, bytes: bytes));
    return Result.success(bytes);
  }

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) =>
      throw UnimplementedError('the commit carries the decoded event');

  @override
  Future<Result<Uint8List>> generateEventId() async {
    _events += 1;
    return Result.success(sequentialId(_events));
  }

  @override
  Future<Result<Uint8List>> deriveDirectConversationId({
    required Uint8List firstUserId,
    required Uint8List secondUserId,
  }) async => Result.success(harnessConversationId);

  @override
  Future<Result<Uint8List>> deriveSavedConversationId(Uint8List userId) async =>
      Result.success(seededBytes(10, 32));
}

/// The send path the application composes for the upload queue:
/// `sendAttachments` of the session, to the direct chat.
final class _SendAttachments implements AttachmentMessagePort {
  const _SendAttachments(this.sender);

  final SendConversationEvents sender;

  @override
  Future<Result<void>> send({
    required AttachmentUploadTarget target,
    required AttachmentDescriptor descriptor,
    required String? caption,
    required bool imageMessage,
  }) async {
    final sent = await sender.sendAttachments(
      currentUserId: localUserId,
      currentDeviceId: localDeviceId,
      target: DirectConversationTarget(target.peerUserId!),
      attachments: [descriptor],
      caption: caption,
      imageMessage: imageMessage,
    );
    return sent.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }
}

/// The sweep after a deletion, as the application composes it, which also
/// records what was there when it was asked for.
final class _Sweep implements AttachmentSweepPort {
  _Sweep(this.root, this.cache, this.holds, this.states);

  final Directory root;
  final AttachmentFileCache cache;
  final AttachmentOutgoingHolds holds;
  final DriftAttachmentLocalState states;
  var requests = 0;

  /// The attachment rows left, at each request.
  final rowsBefore = <int>[];

  /// Whether a decrypted file was still in the cache, at each request.
  final fileBefore = <bool>[];

  @override
  Future<void> sweepAfterDeletion() async {
    requests += 1;
    final database = states.database;
    rowsBefore.add((await database.select(database.attachments).get()).length);
    final plain = Directory('${root.path}${Platform.pathSeparator}plain');
    fileBefore.add(
      await plain.exists() &&
          plain.listSync(recursive: true).whereType<File>().isNotEmpty,
    );
    await cache.sweep(liveOutgoing: holds.live);
  }
}

final class _Unused
    implements
        PairwiseLiveDeviceResolverPort,
        PairwiseSelectiveClaimPort,
        PairwiseOutboundPreparationPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
