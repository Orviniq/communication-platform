import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// [bytes] as a person reads a size: bytes below one kilobyte, then
/// kilobytes, then megabytes, counted in 1,024s as the upload sizes are.
///
/// One decimal below ten, and none above, so the six upload sizes read as
/// 64 KB to 64 MB.
String formatAttachmentSize(AppLocalizations strings, int bytes) {
  const kilobyte = 1024;
  const megabyte = 1024 * 1024;
  if (bytes < kilobyte) {
    return strings.attachmentSizeBytes('$bytes');
  }
  if (bytes < megabyte) {
    return strings.attachmentSizeKilobytes(_amount(bytes / kilobyte));
  }
  return strings.attachmentSizeMegabytes(_amount(bytes / megabyte));
}

String _amount(double value) {
  if (value >= 10) {
    return '${value.round()}';
  }
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// The local time of [moment], an instant in UTC, as this device shows a
/// time of day (ADR-089 D6: the turn of the server's UTC day, in local time).
String formatAttachmentTime(BuildContext context, DateTime moment) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(moment.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// What the screen says about a pick that failed, one sentence for each
/// failure of `AttachmentPlatformPort.pick`, or null for the user's own
/// cancel, which says nothing.
///
/// [limitBytes] is the pick's byte limit, which the "too large" sentence
/// states.
String? attachmentPickFailureMessage(
  AppLocalizations strings,
  Failure failure, {
  required int? limitBytes,
}) => switch (failure) {
  CancellationFailure() => null,
  ValidationFailure(kind: ValidationFailureKind.conflict) =>
    strings.attachmentPickBusy,
  ValidationFailure(kind: ValidationFailureKind.limitExceeded) =>
    limitBytes == null
        ? strings.attachmentPickUnreadable
        : strings.attachmentPickTooLarge(
            formatAttachmentSize(strings, limitBytes),
          ),
  ValidationFailure(kind: ValidationFailureKind.invalidInput) =>
    strings.attachmentPickUnsupportedImage,
  StorageFailure() => strings.attachmentPickUnreadable,
  UnsupportedProtocolFailure() => strings.attachmentPickNoCamera,
  SecurityFailure(kind: SecurityFailureKind.policyBlocked) =>
    strings.attachmentPickRefused,
  _ => strings.attachmentPickMalformed,
};
