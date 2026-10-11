import 'dart:async';
import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_platform_port.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';

/// One call [FakeAttachmentPlatform] received, in the order it arrived.
sealed class AttachmentPlatformCall {
  const AttachmentPlatformCall();
}

final class AttachmentPickCall extends AttachmentPlatformCall {
  const AttachmentPickCall({required this.kind, required this.maxBytes});

  final AttachmentPickKind kind;
  final int maxBytes;
}

final class AttachmentOpenCall extends AttachmentPlatformCall {
  const AttachmentOpenCall({required this.file, required this.mimeType});

  final File file;
  final String mimeType;
}

final class AttachmentSaveCall extends AttachmentPlatformCall {
  const AttachmentSaveCall({
    required this.file,
    required this.name,
    required this.mimeType,
  });

  final File file;
  final String name;
  final String mimeType;
}

final class AttachmentShareCall extends AttachmentPlatformCall {
  const AttachmentShareCall({required this.file, required this.mimeType});

  final File file;
  final String mimeType;
}

/// An [AttachmentPlatformPort] that records each call and answers what the
/// test programmed.
///
/// A queued answer is used once, in order; with the queue empty the standing
/// answer is used. An answer may be a [Future] the test completes later, to
/// hold a picker open. Every operation is cancelled or succeeds until told
/// otherwise: a pick answers that the user closed the picker.
final class FakeAttachmentPlatform implements AttachmentPlatformPort {
  final calls = <AttachmentPlatformCall>[];

  FutureOr<Result<PickedAttachment>> pickAnswer = const Result.failure(
    CancellationFailure(CancellationFailureKind.requestedByUser),
  );
  FutureOr<Result<void>> openAnswer = const Result<void>.success(null);
  FutureOr<Result<void>> saveAnswer = const Result<void>.success(null);
  FutureOr<Result<void>> shareAnswer = const Result<void>.success(null);

  final _pickQueue = <FutureOr<Result<PickedAttachment>>>[];
  final _openQueue = <FutureOr<Result<void>>>[];
  final _saveQueue = <FutureOr<Result<void>>>[];
  final _shareQueue = <FutureOr<Result<void>>>[];

  List<AttachmentPickCall> get picks =>
      calls.whereType<AttachmentPickCall>().toList(growable: false);
  List<AttachmentOpenCall> get opens =>
      calls.whereType<AttachmentOpenCall>().toList(growable: false);
  List<AttachmentSaveCall> get saves =>
      calls.whereType<AttachmentSaveCall>().toList(growable: false);
  List<AttachmentShareCall> get shares =>
      calls.whereType<AttachmentShareCall>().toList(growable: false);

  void enqueuePick(FutureOr<Result<PickedAttachment>> answer) =>
      _pickQueue.add(answer);
  void enqueueOpen(FutureOr<Result<void>> answer) => _openQueue.add(answer);
  void enqueueSave(FutureOr<Result<void>> answer) => _saveQueue.add(answer);
  void enqueueShare(FutureOr<Result<void>> answer) => _shareQueue.add(answer);

  /// A pick that answers [file] as the outgoing copy, with its real length.
  void pickFile(
    File file, {
    String displayName = 'document.pdf',
    String mimeType = 'application/pdf',
    AttachmentMediaKind? mediaKind,
    int? width,
    int? height,
  }) => enqueuePick(
    Result.success(
      PickedAttachment(
        file: file,
        displayName: displayName,
        mimeType: mimeType,
        length: file.lengthSync(),
        mediaKind:
            mediaKind ??
            (width == null
                ? AttachmentMediaKind.file
                : AttachmentMediaKind.image),
        width: width,
        height: height,
      ),
    ),
  );

  @override
  Future<Result<PickedAttachment>> pick({
    required AttachmentPickKind kind,
    required int maxBytes,
  }) {
    calls.add(AttachmentPickCall(kind: kind, maxBytes: maxBytes));
    return _next(_pickQueue, pickAnswer);
  }

  @override
  Future<Result<void>> open({required File file, required String mimeType}) {
    calls.add(AttachmentOpenCall(file: file, mimeType: mimeType));
    return _next(_openQueue, openAnswer);
  }

  @override
  Future<Result<void>> save({
    required File file,
    required String name,
    required String mimeType,
  }) {
    calls.add(AttachmentSaveCall(file: file, name: name, mimeType: mimeType));
    return _next(_saveQueue, saveAnswer);
  }

  @override
  Future<Result<void>> share({required File file, required String mimeType}) {
    calls.add(AttachmentShareCall(file: file, mimeType: mimeType));
    return _next(_shareQueue, shareAnswer);
  }

  Future<T> _next<T>(List<FutureOr<T>> queue, FutureOr<T> standing) async =>
      queue.isEmpty ? await standing : await queue.removeAt(0);
}
