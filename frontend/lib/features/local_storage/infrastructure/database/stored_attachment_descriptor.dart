import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';

/// The descriptor an `attachments` row stores, or null when the bytes are not
/// one.
///
/// The projector writes `encrypted_descriptor` as the JSON map of one
/// attachment in a `messageCreate` body projection: `capability`, `key`,
/// `header`, `stream_header`, `encrypted_size`, `bucket_size`,
/// `plaintext_size`, `name`, `mime`, `media_kind`, `width`, `height`,
/// `caption` and `thumbnail`, the byte fields in base64url.
/// Every reader goes through here, so the timeline, the attachment feature
/// and the Chats list preview cannot disagree about what a row says.
///
/// [EncryptedAttachmentDescriptor] checks every field again, so a row that
/// was written wrong reads as nothing rather than as a descriptor that lies.
EncryptedAttachmentDescriptor? decodeStoredAttachmentDescriptor(
  Uint8List bytes,
) {
  try {
    final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (value is! Map<String, Object?>) return null;
    return EncryptedAttachmentDescriptor(
      capabilityId: value['capability']! as String,
      key: base64Url.decode(value['key']! as String),
      header: base64Url.decode(value['header']! as String),
      secretstreamHeader: base64Url.decode(value['stream_header']! as String),
      encryptedSize: value['encrypted_size']! as int,
      bucketSize: value['bucket_size']! as int,
      plaintextSize: value['plaintext_size']! as int,
      displayName: value['name']! as String,
      mimeType: value['mime']! as String,
      mediaKind: AttachmentMediaKind.values[value['media_kind']! as int],
      width: value['width'] as int?,
      height: value['height'] as int?,
      caption: value['caption'] as String?,
      thumbnail: value['thumbnail'] == null
          ? null
          : base64Url.decode(value['thumbnail']! as String),
    );
  } on Object {
    return null;
  }
}
