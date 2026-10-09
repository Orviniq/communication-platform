import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';

/// What the user asked to attach from (ADR-089 D2).
///
/// [photo] and [camera] give a picture this device re-encoded; [file] gives
/// the exact bytes of whatever was chosen.
enum AttachmentPickKind { photo, file, camera }

/// A file the user chose, copied into the private cache before anything is
/// encrypted (ADR-089 D3).
///
/// [file] is the outgoing copy, which its holder deletes or hands on.
/// [displayName] and [mimeType] already passed `safeAttachmentName` and
/// `safeMimeType`; [length] is the bytes on disk. [width] and [height] are
/// set for an image and may be set for a file of an image type.
final class PickedAttachment {
  const PickedAttachment({
    required this.file,
    required this.displayName,
    required this.mimeType,
    required this.length,
    required this.mediaKind,
    this.width,
    this.height,
  });

  /// The largest width or height a descriptor carries.
  static const maximumDimension = 8192;

  final File file;
  final String displayName;
  final String mimeType;
  final int length;
  final AttachmentMediaKind mediaKind;
  final int? width;
  final int? height;

  @override
  String toString() => 'PickedAttachment(<redacted>)';
}
