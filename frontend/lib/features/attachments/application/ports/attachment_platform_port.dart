import 'dart:io';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';

/// The Android attachment boundary (ADR-089 D2, D3, D4 and D7): the system
/// pickers, the camera app, and Open, Save and Share of a verified file.
///
/// Each outcome is a typed [Result], and each failure is one the screen can
/// name without reading anything else:
///
/// | Outcome | Failure |
/// |---|---|
/// | the user closed the picker, or Save | `CancellationFailure(requestedByUser)` |
/// | a pick or a save is already open | `ValidationFailure(conflict)` |
/// | the file is above the pick's byte limit | `ValidationFailure(limitExceeded)` |
/// | a picture this device cannot decode | `ValidationFailure(invalidInput)` |
/// | the chosen content could not be read | `StorageFailure(unavailable)` from [pick] |
/// | the save could not be written | `StorageFailure(unavailable)` from [save] |
/// | no camera app, or no app to open the file | `UnsupportedProtocolFailure(capability)` |
/// | the platform refused the file it was given | `SecurityFailure(policyBlocked)` |
/// | an answer this code does not accept | `SecurityFailure(malformedServerResponse)` |
///
/// The last row reuses the kind every boundary of this client gives a reply it
/// cannot parse, as the crypto worker's isolate does for its own.
abstract interface class AttachmentPlatformPort {
  /// Lets the user choose a picture, a file or a new photo, and answers the
  /// outgoing copy.
  ///
  /// [maxBytes] is the largest plaintext that fits the largest usable bucket
  /// (`attachmentPlaintextLimit`). A file above it is refused while it is
  /// copied, whatever size its provider declared.
  Future<Result<PickedAttachment>> pick({
    required AttachmentPickKind kind,
    required int maxBytes,
  });

  /// Hands a verified decrypted [file] to the app the user picks to view it.
  Future<Result<void>> open({required File file, required String mimeType});

  /// Writes a copy of a verified decrypted [file] where the user chooses,
  /// offering [name] as the document's name.
  Future<Result<void>> save({
    required File file,
    required String name,
    required String mimeType,
  });

  /// Offers a verified decrypted [file] to the app the user picks to send it
  /// on.
  Future<Result<void>> share({required File file, required String mimeType});
}
