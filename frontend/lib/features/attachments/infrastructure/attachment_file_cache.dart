import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/domain/attachment_cache_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';

/// The decrypted files of attachments, and the picker's copies, in the
/// private cache (ADR-089 D8).
///
/// Everything lives under one root, `secure_attachment_cache` in the
/// application's cache directory, which the native side deletes recursively
/// at logout and at revocation:
///
/// | Path | Holds |
/// |---|---|
/// | `plain/<id>/<safe name>` | one decrypted, verified file |
/// | `outgoing/<id>/<safe name>` | one copy the picker made, before it is sent |
/// | `<id>.tmp` | a temporary file of encryption or download |
///
/// Each id is a random cache id ([newAttachmentCacheId]), so no path holds a
/// capability, and the only display name on disk is the file's own name inside
/// its directory, where Open, Save and Share need it. The `attachments` row
/// names the id of its file, and the file names nothing.
///
/// **Bounds.** An entry expires [lifetime] after its last open, so the earliest
/// expiry is the least recently opened entry, and that is the one evicted
/// first while `plain/` holds more than [maximumBytes]. An evicted, expired or
/// missing entry returns its row to `queued`: "not downloaded".
///
/// **Sweeps.** [sweep] deletes what no row names and clears each row whose
/// file is gone or expired. The first sweep of an instance also deletes every
/// file at the top level, and [beforeTransfer] runs it before the first
/// transfer and makes every later one wait for it.
///
/// Every operation runs one at a time, in the order called, so a sweep never
/// sees a file between its move and the row that names it. Nothing here logs,
/// and a failure carries a kind and nothing else.
final class AttachmentFileCache {
  AttachmentFileCache({
    required Directory root,
    required this.states,
    required this.clock,
    Random? random,
    this.lifetime = AttachmentCacheLimits.lifetime,
    this.maximumBytes = AttachmentCacheLimits.maximumBytes,
  }) : _root = root.path,
       _random = random ?? Random.secure();

  final AttachmentLocalStatePort states;
  final TimeSource clock;
  final Duration lifetime;
  final int maximumBytes;
  final String _root;
  final Random _random;

  Future<void> _tail = Future<void>.value();

  /// The first sweep, once it has started.
  Future<void>? _firstSweep;

  static final _separator = Platform.pathSeparator;

  String get _plain => '$_root${_separator}plain';
  String get _outgoing => '$_root${_separator}outgoing';
  String _plainDirectory(String id) => '$_plain$_separator$id';

  /// Moves the picker's [copy] into `plain/` as the decrypted file of
  /// [attachmentId], which the message that carries it has just made: the
  /// sender's copy of what it sent. Answers the new cache id.
  ///
  /// [copy] has to be `outgoing/<id>/<name>` under the root, and its
  /// directory goes whole, under a new id; anything else in it is deleted
  /// first. Until the move the copy stays where it was, and after it a
  /// failure to record the row deletes it, so plaintext is never left where
  /// no row names it.
  Future<Result<String>> adoptOutgoing({
    required String attachmentId,
    required File copy,
  }) => _serial(() async {
    final outgoingId = _outgoingIdOf(copy);
    if (outgoingId == null) {
      return const Result.failure(_refused);
    }
    final source = Directory('$_outgoing$_separator$outgoingId');
    final id = newAttachmentCacheId(_random);
    try {
      if (!await _isRegularFile(copy.path)) {
        return const Result.failure(_unavailable);
      }
      await for (final entity in source.list(followLinks: false)) {
        if (entity.path != copy.path) {
          await entity.delete(recursive: true);
        }
      }
      await Directory(_plain).create(recursive: true);
      await source.rename(_plainDirectory(id));
    } on FileSystemException {
      return const Result.failure(_unavailable);
    }
    return _admit(attachmentId, id);
  });

  /// Moves a decrypted, verified temporary [file] to `plain/<new id>/<name>`
  /// as the file of [attachmentId], [name] made safe for the file system.
  /// Answers the new cache id.
  ///
  /// [file] has to be a temporary file at the top level of the root. After
  /// the move a failure to record the row deletes it.
  Future<Result<String>> adoptDecrypted({
    required String attachmentId,
    required File file,
    required String name,
  }) => _serial(() async {
    if (!_isTopLevel(file.path)) {
      return const Result.failure(_refused);
    }
    final id = newAttachmentCacheId(_random);
    final directory = Directory(_plainDirectory(id));
    try {
      if (!await _isRegularFile(file.path)) {
        return const Result.failure(_unavailable);
      }
      await directory.create(recursive: true);
      await file.rename(
        '${directory.path}$_separator${plainAttachmentFileName(name)}',
      );
    } on FileSystemException {
      await _delete(directory);
      return const Result.failure(_unavailable);
    }
    return _admit(attachmentId, id);
  });

  /// The decrypted file in directory [cacheId], or null when there is none.
  Future<File?> resolve(String cacheId) => _serial(() => _resolve(cacheId));

  /// The decrypted file of [attachmentId], with its expiry moved to now plus
  /// [lifetime], or null when it has none.
  ///
  /// A file that expired or went missing is forgotten here, and its row
  /// returns to `queued`.
  Future<File?> open(String attachmentId) => _serial(() async {
    final read = await states.read(attachmentId);
    final state = read is Success<AttachmentLocalState?> ? read.value : null;
    final cacheId = state?.cacheId;
    final expiresAt = state?.expiresAt;
    if (state == null ||
        state.state != AttachmentTransferState.ready ||
        cacheId == null ||
        expiresAt == null) {
      return null;
    }
    final now = clock.now().toUtc();
    final file = expiresAt.isAfter(now) ? await _resolve(cacheId) : null;
    if (file == null) {
      await _forget(attachmentId, cacheId);
      return null;
    }
    // A failed touch keeps the old expiry. The file is still there to open,
    // and the worst that follows is an earlier eviction.
    await states.touch(
      attachmentId: attachmentId,
      expiresAt: now.add(lifetime),
    );
    return file;
  });

  /// Deletes directory [cacheId] and what it holds.
  Future<void> remove(String cacheId) => _serial(() async {
    if (isAttachmentCacheId(cacheId)) {
      await _delete(Directory(_plainDirectory(cacheId)));
    }
  });

  /// Makes the cache agree with the rows.
  ///
  /// It deletes every `plain/` entry that no row names, clears each row whose
  /// file is missing or whose expiry has passed and deletes its directory,
  /// deletes every `outgoing/` entry that none of [liveOutgoing] is in, and
  /// then holds the bound. The first sweep of this instance also deletes every
  /// file at the top level: the transport keeps the record of a partial
  /// download in memory only, so before the first transfer no temporary file
  /// is anybody's.
  ///
  /// [liveOutgoing] is every outgoing copy something in this process still
  /// holds. A sweep never fails: what it could not do waits for the next one,
  /// and when the rows cannot be read it deletes nothing at all.
  Future<void> sweep({required Iterable<File> liveOutgoing}) {
    final first = _firstSweep;
    if (first == null) {
      return _firstSweep = _serial(() => _sweep(liveOutgoing, topLevel: true));
    }
    return _serial(() => _sweep(liveOutgoing, topLevel: false));
  }

  /// Completes when the first sweep has run, running it if nothing has yet.
  ///
  /// Each transfer awaits this before it makes a temporary file.
  Future<void> beforeTransfer({required Iterable<File> liveOutgoing}) =>
      _firstSweep ?? sweep(liveOutgoing: liveOutgoing);

  Future<Result<String>> _admit(String attachmentId, String id) async {
    final previous = await states.read(attachmentId);
    final marked = await states.markCached(
      attachmentId: attachmentId,
      cacheId: id,
      expiresAt: clock.now().toUtc().add(lifetime),
    );
    if (marked case FailureResult(:final failure)) {
      await _delete(Directory(_plainDirectory(id)));
      return Result.failure(failure);
    }
    // A file this attachment already had is replaced, not kept beside it.
    if (previous case Success(
      value: AttachmentLocalState(:final cacheId?),
    ) when cacheId != id) {
      await _delete(Directory(_plainDirectory(cacheId)));
    }
    await _holdBound();
    return Result.success(id);
  }

  Future<void> _sweep(
    Iterable<File> liveOutgoing, {
    required bool topLevel,
  }) async {
    try {
      await _sweepOnce(liveOutgoing, topLevel: topLevel);
    } on Exception {
      // A sweep never fails, or the first one would fail every transfer that
      // waits for it. What this one could not do waits for the next.
    }
  }

  Future<void> _sweepOnce(
    Iterable<File> liveOutgoing, {
    required bool topLevel,
  }) async {
    final listed = await states.listCached();
    if (listed is! Success<List<CachedAttachmentEntry>>) {
      return;
    }
    final now = clock.now().toUtc();
    final named = <String>{};
    for (final entry in listed.value) {
      final cacheId = entry.cacheId;
      final expiresAt = entry.expiresAt;
      if (cacheId == null ||
          expiresAt == null ||
          !expiresAt.isAfter(now) ||
          await _resolve(cacheId) == null) {
        await _forget(entry.attachmentId, cacheId);
      } else {
        named.add(cacheId);
      }
    }
    await _deleteEntriesOf(Directory(_plain), keeping: named);
    await _deleteEntriesOf(
      Directory(_outgoing),
      keeping: {for (final copy in liveOutgoing) ?_outgoingIdOf(copy)},
    );
    if (topLevel) {
      await _deleteTopLevelFiles();
    }
    await _holdBound();
  }

  /// Evicts the earliest expiry first while `plain/` holds more than
  /// [maximumBytes].
  Future<void> _holdBound() async {
    final listed = await states.listCached();
    if (listed is! Success<List<CachedAttachmentEntry>>) {
      return;
    }
    final entries = <({String attachmentId, String cacheId, int bytes})>[];
    var total = 0;
    final ordered =
        [
          for (final entry in listed.value)
            if (entry.cacheId != null && entry.expiresAt != null) entry,
        ]..sort((left, right) {
          final byExpiry = left.expiresAt!.compareTo(right.expiresAt!);
          return byExpiry != 0
              ? byExpiry
              : left.attachmentId.compareTo(right.attachmentId);
        });
    for (final entry in ordered) {
      final file = await _resolve(entry.cacheId!);
      final bytes = file == null ? 0 : await _length(file);
      total += bytes;
      entries.add((
        attachmentId: entry.attachmentId,
        cacheId: entry.cacheId!,
        bytes: bytes,
      ));
    }
    for (final entry in entries) {
      if (total <= maximumBytes) {
        return;
      }
      await _forget(entry.attachmentId, entry.cacheId);
      total -= entry.bytes;
    }
  }

  /// Returns the row of [attachmentId] to `queued`, then deletes directory
  /// [cacheId].
  ///
  /// The row goes first: a directory no row names is deleted by the next
  /// sweep, while a row that names nothing would show a file nobody can open.
  Future<void> _forget(String attachmentId, String? cacheId) async {
    await states.clearCache(attachmentId);
    if (cacheId != null && isAttachmentCacheId(cacheId)) {
      await _delete(Directory(_plainDirectory(cacheId)));
    }
  }

  Future<File?> _resolve(String cacheId) async {
    if (!isAttachmentCacheId(cacheId)) {
      return null;
    }
    final directory = Directory(_plainDirectory(cacheId));
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
      File? found;
      await for (final entity in directory.list(followLinks: false)) {
        // Exactly one regular file. A link, a directory or a second file is
        // not what adoption leaves, so the entry is not trusted.
        if (entity is! File || found != null) {
          return null;
        }
        found = entity;
      }
      return found;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _deleteEntriesOf(
    Directory directory, {
    required Set<String> keeping,
  }) async {
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final prefix = directory.path.length + _separator.length;
      await for (final entity in directory.list(followLinks: false)) {
        if (!keeping.contains(entity.path.substring(prefix))) {
          await _delete(entity);
        }
      }
    } on FileSystemException {
      // The next sweep tries again.
    }
  }

  Future<void> _deleteTopLevelFiles() async {
    try {
      await for (final entity in Directory(_root).list(followLinks: false)) {
        if (entity is! Directory) {
          await _delete(entity);
        }
      }
    } on FileSystemException {
      // No root yet, or one this sweep cannot read: nothing to delete.
    }
  }

  /// The id of the outgoing copy [copy] is, or null unless its path is
  /// exactly `outgoing/<id>/<name>` under the root.
  String? _outgoingIdOf(File copy) {
    final prefix = '$_outgoing$_separator';
    if (!copy.path.startsWith(prefix)) {
      return null;
    }
    final parts = copy.path.substring(prefix.length).split(_separator);
    return parts.length == 2 &&
            isAttachmentCacheId(parts.first) &&
            _isName(parts.last)
        ? parts.first
        : null;
  }

  bool _isTopLevel(String path) {
    final prefix = '$_root$_separator';
    return path.startsWith(prefix) &&
        _isName(path.substring(prefix.length)) &&
        !path.substring(prefix.length).contains(_separator);
  }

  static bool _isName(String value) =>
      value.isNotEmpty && value != '.' && value != '..';

  static Future<bool> _isRegularFile(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.file;

  static Future<int> _length(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  static Future<void> _delete(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: true);
    } on FileSystemException {
      // The next sweep tries again; the wipe deletes it in any case.
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  String toString() => 'AttachmentFileCache(<redacted>)';

  static const _refused = SecurityFailure(SecurityFailureKind.policyBlocked);
  static const _unavailable = StorageFailure(StorageFailureKind.unavailable);
}

/// The name a decrypted file is given in its directory: [name] made safe as
/// a display name, then cut to the 255 bytes of UTF-8 a file system allows
/// for one name, whole characters only.
String plainAttachmentFileName(String name) {
  final safe = safeAttachmentName(name);
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in safe.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > 255) {
      break;
    }
    buffer.write(character);
  }
  return buffer.toString();
}
