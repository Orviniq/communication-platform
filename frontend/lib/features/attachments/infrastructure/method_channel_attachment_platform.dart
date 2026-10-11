import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_platform_port.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:flutter/services.dart';

/// [AttachmentPlatformPort] over `AttachmentChannel.kt` (ADR-089).
///
/// A pick's answer becomes a [PickedAttachment] only after every field is
/// present and of its type, the kind is the one asked for, the length is
/// within the limit asked for, and the path is an outgoing copy in the private
/// cache: `secure_attachment_cache/outgoing/<32 hex>/<name>`, as the native
/// side makes it. The name and the type pass through [safeAttachmentName] and
/// [safeMimeType] here as well, because nothing the platform says is trusted
/// for display. Each error code is accepted only from the method that can
/// give it; any other answer is malformed.
///
/// Nothing here logs, and a failure carries a kind and nothing else.
final class MethodChannelAttachmentPlatform implements AttachmentPlatformPort {
  MethodChannelAttachmentPlatform();

  static const channelName = 'communication_platform/attachments';
  static const _channel = MethodChannel(channelName);

  static const _pickCodes = {
    'busy',
    'tooLarge',
    'unreadable',
    'unsupportedImage',
    'noCameraApp',
    'noApp',
    'invalid_argument',
  };
  static const _openCodes = {'noApp', 'invalid_argument'};
  static const _saveCodes = {
    'busy',
    'noApp',
    'writeFailed',
    'invalid_argument',
  };
  static const _shareCodes = {'invalid_argument', 'share_failed'};

  static final _copyPath = RegExp(r'^[0-9a-f]{32}/([^/\\\u0000]+)$');

  /// `<private cache>/outgoing/`, once the platform has named it.
  String? _outgoingDirectory;

  @override
  Future<Result<PickedAttachment>> pick({
    required AttachmentPickKind kind,
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) {
      return const Result.failure(_refused);
    }
    final reply = await _invoke('pick', {
      'kind': switch (kind) {
        AttachmentPickKind.photo => 'photo',
        AttachmentPickKind.file => 'file',
        AttachmentPickKind.camera => 'camera',
      },
      'maxBytes': maxBytes,
    }, codes: _pickCodes);
    final failure = reply.failure;
    if (failure != null) {
      return Result.failure(failure);
    }
    final answer = reply.answer;
    if (answer == null) {
      return const Result.failure(_cancelled);
    }
    final outgoing = await _outgoing();
    final picked = outgoing == null
        ? null
        : _parse(answer, kind: kind, maxBytes: maxBytes, outgoing: outgoing);
    return picked == null
        ? const Result.failure(_malformed)
        : Result.success(picked);
  }

  @override
  Future<Result<void>> open({
    required File file,
    required String mimeType,
  }) async {
    final reply = await _invoke('openVerifiedFile', {
      'path': file.path,
      'mime': safeMimeType(mimeType),
    }, codes: _openCodes);
    return _done(reply);
  }

  @override
  Future<Result<void>> save({
    required File file,
    required String name,
    required String mimeType,
  }) async {
    final reply = await _invoke('saveVerifiedFile', {
      'path': file.path,
      'name': safeAttachmentName(name),
      'mime': safeMimeType(mimeType),
    }, codes: _saveCodes);
    final failure = reply.failure;
    if (failure != null) {
      return Result.failure(failure);
    }
    return switch (reply.answer) {
      true => const Result<void>.success(null),
      false => const Result.failure(_cancelled),
      _ => const Result.failure(_malformed),
    };
  }

  @override
  Future<Result<void>> share({
    required File file,
    required String mimeType,
  }) async {
    final reply = await _invoke('shareVerifiedFile', {
      'path': file.path,
      'mime': safeMimeType(mimeType),
    }, codes: _shareCodes);
    return _done(reply);
  }

  Future<({Object? answer, Failure? failure})> _invoke(
    String method,
    Map<String, Object?> arguments, {
    required Set<String> codes,
  }) async {
    try {
      final answer = await _channel.invokeMethod<Object?>(method, arguments);
      return (answer: answer, failure: null);
    } on PlatformException catch (error) {
      return (
        answer: null,
        failure: codes.contains(error.code)
            ? _failureFor(error.code)
            : _malformed,
      );
    } on MissingPluginException {
      return (answer: null, failure: _unavailable);
    }
  }

  /// Open and Share answer nothing when the system took the file.
  Result<void> _done(({Object? answer, Failure? failure}) reply) {
    final failure = reply.failure;
    if (failure != null) {
      return Result.failure(failure);
    }
    return reply.answer == null
        ? const Result<void>.success(null)
        : const Result.failure(_malformed);
  }

  Future<String?> _outgoing() async {
    final known = _outgoingDirectory;
    if (known != null) {
      return known;
    }
    final reply = await _invoke(
      'privateCacheDirectory',
      const {},
      codes: const {},
    );
    final root = reply.answer;
    if (root is! String || !root.startsWith('/') || root.endsWith('/')) {
      return null;
    }
    return _outgoingDirectory = '$root/outgoing/';
  }

  PickedAttachment? _parse(
    Object answer, {
    required AttachmentPickKind kind,
    required int maxBytes,
    required String outgoing,
  }) {
    if (answer is! Map<Object?, Object?>) {
      return null;
    }
    final path = answer['path'];
    final name = answer['name'];
    final mime = answer['mime'];
    final size = answer['size'];
    final mediaKind = answer['kind'];
    final width = answer['width'];
    final height = answer['height'];
    if (path is! String ||
        name is! String ||
        mime is! String ||
        size is! int ||
        mediaKind is! String ||
        (width != null && width is! int) ||
        (height != null && height is! int)) {
      return null;
    }
    if (!_isOutgoingCopy(path, outgoing) || size < 0 || size > maxBytes) {
      return null;
    }
    final expected = kind == AttachmentPickKind.file
        ? AttachmentMediaKind.file
        : AttachmentMediaKind.image;
    if (mediaKind != expected.name) {
      return null;
    }
    final w = width as int?;
    final h = height as int?;
    if ((w == null) != (h == null) ||
        (w != null && !_isDimension(w)) ||
        (h != null && !_isDimension(h))) {
      return null;
    }
    final safeMime = safeMimeType(mime);
    if (expected == AttachmentMediaKind.image &&
        (w == null || !safeMime.startsWith('image/'))) {
      return null;
    }
    return PickedAttachment(
      file: File(path),
      displayName: safeAttachmentName(name),
      mimeType: safeMime,
      length: size,
      mediaKind: expected,
      width: w,
      height: h,
    );
  }

  bool _isOutgoingCopy(String path, String outgoing) {
    if (!path.startsWith(outgoing)) {
      return false;
    }
    final match = _copyPath.firstMatch(path.substring(outgoing.length));
    final name = match?.group(1);
    return name != null && name != '.' && name != '..';
  }

  static bool _isDimension(int value) =>
      value >= 1 && value <= PickedAttachment.maximumDimension;

  static Failure _failureFor(String code) => switch (code) {
    'busy' => const ValidationFailure(ValidationFailureKind.conflict),
    'tooLarge' => const ValidationFailure(ValidationFailureKind.limitExceeded),
    'unsupportedImage' => const ValidationFailure(
      ValidationFailureKind.invalidInput,
    ),
    'unreadable' ||
    'writeFailed' => const StorageFailure(StorageFailureKind.unavailable),
    'noCameraApp' || 'noApp' => _unavailable,
    'invalid_argument' || 'share_failed' => _refused,
    _ => _malformed,
  };

  static const _cancelled = CancellationFailure(
    CancellationFailureKind.requestedByUser,
  );
  static const _unavailable = UnsupportedProtocolFailure(
    UnsupportedProtocolFailureKind.capability,
  );
  static const _refused = SecurityFailure(SecurityFailureKind.policyBlocked);
  static const _malformed = SecurityFailure(
    SecurityFailureKind.malformedServerResponse,
  );
}
