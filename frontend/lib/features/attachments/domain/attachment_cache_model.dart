import 'dart:math';

/// The bounds of the decrypted-file cache (ADR-089 D8).
abstract final class AttachmentCacheLimits {
  /// How long an entry lives after its last open. The expiry is the last
  /// open plus this, so the earliest expiry is the least recently opened
  /// entry.
  static const lifetime = Duration(days: 7);

  /// The most the decrypted files may hold together.
  static const maximumBytes = 256 * 1024 * 1024;
}

/// Whether [value] is a cache id: 32 lowercase hexadecimal characters.
///
/// A cache id names one directory of decrypted or outgoing files, or one
/// temporary file. It is random, so it says nothing about the attachment, its
/// capability or its name.
bool isAttachmentCacheId(String value) => _cacheId.hasMatch(value);

/// A new cache id: 16 bytes of [random] as 32 lowercase hexadecimal
/// characters. [random] is `Random.secure()` everywhere but in a test.
String newAttachmentCacheId(Random random) => [
  for (var index = 0; index < 16; index += 1)
    random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

final _cacheId = RegExp(r'^[0-9a-f]{32}$');
