import 'dart:async';
import 'dart:io';

import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:flutter/services.dart';

export 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart'
    show AttachmentStoragePort;

/// Android's system temp/cache directory is private to the application. The
/// adapter never returns a path for sharing; callers use a content URI bridge.
final class PrivateAttachmentStorage implements AttachmentStoragePort {
  PrivateAttachmentStorage({Directory? root})
    : _root = root ?? Directory.systemTemp;

  final Directory _root;
  int _counter = 0;

  static Future<PrivateAttachmentStorage> forPlatform() async {
    if (!Platform.isAndroid) return PrivateAttachmentStorage();
    try {
      final path = await const MethodChannel(
        'communication_platform/attachments',
      ).invokeMethod<String>('privateCacheDirectory');
      if (path != null && path.isNotEmpty) {
        return PrivateAttachmentStorage(root: Directory(path));
      }
    } on PlatformException {
      // Fall back to the Dart private temp directory; it is never shared by
      // path and remains application-private on Android.
    }
    return PrivateAttachmentStorage();
  }

  @override
  Future<File> createEncryptedTemp() => _newFile('cipher');

  @override
  Future<File> createDecryptedTemp({required String safeName}) {
    final name = safeAttachmentName(safeName);
    return _newFile('plain_$name');
  }

  @override
  Future<void> delete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Cleanup is best effort; failed files remain private and are retried by
      // the bounded cache cleanup job.
    }
  }

  Future<File> _newFile(String prefix) async {
    await _root.create(recursive: true);
    _counter += 1;
    return File(
      '${_root.path}/communication_attachment_${prefix}_$_counter.tmp',
    );
  }
}

final class AttachmentCacheEntry {
  const AttachmentCacheEntry({
    required this.attachmentId,
    required this.file,
    required this.bytes,
    required this.expiresAt,
    required this.lastAccessAt,
  });

  final String attachmentId;
  final File file;
  final int bytes;
  final DateTime expiresAt;
  final DateTime lastAccessAt;
}

/// Bounded decrypted-file/thumbnail cache. It owns deletion and never exposes
/// a file after expiry or eviction.
final class BoundedAttachmentCache {
  BoundedAttachmentCache({
    required this.storage,
    this.maximumEntries = 32,
    this.maximumBytes = 64 * 1024 * 1024,
  });

  final AttachmentStoragePort storage;
  final int maximumEntries;
  final int maximumBytes;
  final Map<String, AttachmentCacheEntry> _entries = {};

  int get totalBytes =>
      _entries.values.fold(0, (sum, item) => sum + item.bytes);

  Future<File?> read(String attachmentId, {DateTime? now}) async {
    final entry = _entries[attachmentId];
    if (entry == null) return null;
    final clock = now ?? DateTime.now().toUtc();
    if (!entry.expiresAt.isAfter(clock) || !await entry.file.exists()) {
      await remove(attachmentId);
      return null;
    }
    _entries[attachmentId] = AttachmentCacheEntry(
      attachmentId: entry.attachmentId,
      file: entry.file,
      bytes: entry.bytes,
      expiresAt: entry.expiresAt,
      lastAccessAt: clock,
    );
    return entry.file;
  }

  Future<void> put({
    required String attachmentId,
    required File file,
    required int bytes,
    required DateTime expiresAt,
  }) async {
    await remove(attachmentId);
    _entries[attachmentId] = AttachmentCacheEntry(
      attachmentId: attachmentId,
      file: file,
      bytes: bytes,
      expiresAt: expiresAt,
      lastAccessAt: DateTime.now().toUtc(),
    );
    await _evict();
  }

  Future<void> remove(String attachmentId) async {
    final entry = _entries.remove(attachmentId);
    if (entry != null) await storage.delete(entry.file);
  }

  Future<void> wipe() async {
    final ids = _entries.keys.toList(growable: false);
    for (final id in ids) {
      await remove(id);
    }
  }

  Future<void> _evict() async {
    final now = DateTime.now().toUtc();
    final ordered = _entries.values.toList()
      ..sort((a, b) => a.lastAccessAt.compareTo(b.lastAccessAt));
    for (final entry in ordered) {
      if (!entry.expiresAt.isAfter(now) ||
          _entries.length > maximumEntries ||
          totalBytes > maximumBytes) {
        await remove(entry.attachmentId);
      }
    }
  }
}
