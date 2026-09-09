/// What one account has already uploaded today, and what is therefore left.
///
/// The server counts uploaded bytes per UTC day and refuses past
/// `attachment_daily_bytes` with `413 quota_exceeded`. It keeps no lifetime
/// total, so nothing accumulates across days; and deleting an attachment gives
/// nothing back, because the day's counter records what was sent rather than
/// what is still stored.
///
/// The client keeps its own copy of the count because the server publishes the
/// ceiling and never the balance. It is therefore a *lower* bound on what has
/// been spent — an upload from this account's other device is missing from it —
/// which is the safe direction: this client may believe it has room the server
/// has already given away, and will then be refused exactly as it is today,
/// but it will never withhold room the server would have granted.
final class AttachmentDailyAllowance {
  const AttachmentDailyAllowance({required this.day, required this.spentBytes})
    : assert(spentBytes >= 0, 'a day cannot have spent less than nothing');

  /// A day on which nothing has been uploaded.
  factory AttachmentDailyAllowance.empty(DateTime now) =>
      AttachmentDailyAllowance(day: utcDayOf(now), spentBytes: 0);

  /// The UTC day this count belongs to, at midnight.
  ///
  /// UTC because that is the day the server counts in. A client counting in
  /// local time would reset hours early or late and would believe it had room
  /// on the wrong side of the boundary.
  final DateTime day;

  /// Bytes this device has uploaded on [day], counted as the bucket sizes the
  /// server received rather than the plaintext lengths behind them.
  final int spentBytes;

  /// What is left of [dailyBytes] once [now] is taken into account.
  ///
  /// A count from an earlier day is spent, not carried: the server's counter
  /// has already reset, so the whole allowance is available again.
  int remaining({required int dailyBytes, required DateTime now}) {
    if (utcDayOf(now) != day) {
      return dailyBytes;
    }
    final left = dailyBytes - spentBytes;
    return left > 0 ? left : 0;
  }

  /// This count with [bytes] added, rolling over when [now] is a later day.
  AttachmentDailyAllowance spend({required int bytes, required DateTime now}) {
    final today = utcDayOf(now);
    return AttachmentDailyAllowance(
      day: today,
      spentBytes: today == day ? spentBytes + bytes : bytes,
    );
  }
}

/// Midnight UTC on the day containing [moment].
DateTime utcDayOf(DateTime moment) {
  final utc = moment.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}
