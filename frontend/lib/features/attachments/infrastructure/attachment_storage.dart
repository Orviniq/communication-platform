// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_cache_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:flutter/services.dart';

export 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart'
    show AttachmentStoragePort;

/// The name of the private cache directory, which the native side deletes
/// recursively at logout and at revocation (`ProtectedStorageChannel.kt`).
const privateAttachmentCacheName = 'secure_attachment_cache';

/// The private cache, as the platform names it, or null when it names none.
///
/// Every attachment file lives under this one directory, because it is the
/// one the wipe deletes (ADR-089 D8). There is no fallback: a directory the
/// wipe does not reach would keep decrypted files after a logout. So the
/// answer is used only when it is an absolute path with no empty, `.` or `..`
/// segment whose last segment is [privateAttachmentCacheName]; a channel that
/// fails, answers nothing or answers anything else leaves attachments not
/// available.
Future<Directory?> privateAttachmentCacheRoot() async {
  final Object? answer;
  try {
    answer = await const MethodChannel(
      MethodChannelAttachmentPlatform.channelName,
    ).invokeMethod<Object?>('privateCacheDirectory');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
  return answer is String && isPrivateAttachmentCacheRoot(answer)
      ? Directory(answer)
      : null;
}

/// Whether [path] can be the private cache: see [privateAttachmentCacheRoot].
bool isPrivateAttachmentCacheRoot(String path) {
  if (!path.startsWith('/')) {
    return false;
  }
  final segments = path.substring(1).split('/');
  return segments.last == privateAttachmentCacheName &&
      segments.every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

/// The temporary files of encryption and download, at the top level of the
/// private cache.
///
/// Each name is a random cache id and `.tmp`, so a name says nothing about the
/// attachment it belongs to: not its capability, not its display name, and not
/// how many came before it. The adapter never hands out a path for sharing;
/// a decrypted file is shared only after `AttachmentFileCache` moved it into
/// `plain/`.
final class PrivateAttachmentStorage implements AttachmentStoragePort {
  PrivateAttachmentStorage({required Directory root, Random? random})
    : _root = root,
      _random = random ?? Random.secure();

  final Directory _root;
  final Random _random;

  /// The storage on the private cache, or null when the platform names none.
  static Future<PrivateAttachmentStorage?> forPlatform() async {
    final root = await privateAttachmentCacheRoot();
    return root == null ? null : PrivateAttachmentStorage(root: root);
  }

  @override
  Future<File> createEncryptedTemp() => _newFile();

  @override
  Future<File> createDecryptedTemp() => _newFile();

  @override
  Future<void> delete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best effort. A file left behind stays in the private cache, which the
      // first sweep of the next process clears and the wipe deletes.
    }
  }

  Future<File> _newFile() async {
    await _root.create(recursive: true);
    return File(
      '${_root.path}${Platform.pathSeparator}'
      '${newAttachmentCacheId(_random)}.tmp',
    );
  }

  @override
  String toString() => 'PrivateAttachmentStorage(<redacted>)';
}
