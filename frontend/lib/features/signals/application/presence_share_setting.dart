import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';

/// "Show my online status" for this process: the stored choice, read once,
/// and every change after it (ADR-098 D9).
///
/// On by default. Off, this phone sends no `watch`, `here`, `typing` or
/// `gone` (one `gone` at the moment it is turned off aside), and shows nobody's
/// online state, last seen or typing.
final class PresenceShareSetting {
  PresenceShareSetting(this.store);

  final PresenceSharePort store;

  bool? _current;
  Future<bool>? _reading;
  final _changes = StreamController<bool>.broadcast();

  /// The choice now: the stored one until [set] changes it.
  Future<bool> read() async {
    final current = _current;
    if (current != null) {
      return current;
    }
    final stored = await (_reading ??= store.readSharing());
    return _current ??= stored;
  }

  /// Every change [set] makes, after it is made.
  Stream<bool> get changes => _changes.stream;

  /// The choice now, then every change.
  Stream<bool> watch() async* {
    yield await read();
    yield* changes;
  }

  /// Stores [sharing] and applies it. Off is applied even when it cannot be
  /// stored, so that nothing more leaves while this process lives, and the
  /// failure is answered for the screen to report; on is applied only once
  /// stored.
  Future<Result<void>> set({required bool sharing}) async {
    final previous = await read();
    final written = await store.writeSharing(sharing: sharing);
    if (written is FailureResult<void> && sharing) {
      return written;
    }
    _current = sharing;
    if (previous != sharing && !_changes.isClosed) {
      _changes.add(sharing);
    }
    return written;
  }

  Future<void> dispose() => _changes.close();
}
