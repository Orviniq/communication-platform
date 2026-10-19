import 'package:communication_platform/features/signals/domain/peer_status_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// The line a direct chat's header draws under the peer's name for [status]
/// (ADR-098 D11): "online", or "last seen" with the time when it was today or
/// yesterday and with the date before that, or null for nothing.
///
/// Days are this phone's local calendar days, counted against [now].
String? peerStatusLine(
  BuildContext context,
  PeerStatus status, {
  required DateTime now,
}) {
  final strings = AppLocalizations.of(context);
  return switch (status) {
    PeerStatusNone() => null,
    PeerStatusOnline() => strings.chatPeerOnline,
    PeerStatusLastSeen(:final at) => _lastSeen(
      context,
      strings,
      at.toLocal(),
      now.toLocal(),
    ),
  };
}

String _lastSeen(
  BuildContext context,
  AppLocalizations strings,
  DateTime at,
  DateTime now,
) {
  final material = MaterialLocalizations.of(context);
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(at));
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == today) {
    return strings.chatPeerLastSeenToday(time);
  }
  if (day == DateTime(today.year, today.month, today.day - 1)) {
    return strings.chatPeerLastSeenYesterday(time);
  }
  return strings.chatPeerLastSeenOn(material.formatMediumDate(at));
}
