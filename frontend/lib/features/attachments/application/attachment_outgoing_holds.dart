import 'dart:io';

/// The outgoing copies this process still holds, and whether a picker is
/// writing one now (ADR-089 D5, D8).
///
/// One for the process. A copy is held from the moment a pick hands it over,
/// through its preview step and its upload job, until the job's message
/// adopts it into the cache or the copy is deleted. A sweep keeps every copy
/// [live] names and deletes every other one in `outgoing/`.
///
/// A copy the picker is still writing has no path here yet, so a sweep must
/// not run while [pickOpen] is true: the copy it would delete is the one the
/// user is choosing.
final class AttachmentOutgoingHolds {
  final _held = <String, File>{};
  var _picksOpen = 0;

  /// Every copy held now.
  Iterable<File> get live => List.unmodifiable(_held.values);

  /// Whether a picker is open, writing a copy nothing holds yet.
  bool get pickOpen => _picksOpen > 0;

  void hold(File copy) => _held[copy.path] = copy;

  void release(File copy) => _held.remove(copy.path);

  void beginPick() => _picksOpen += 1;

  void endPick() {
    if (_picksOpen > 0) {
      _picksOpen -= 1;
    }
  }

  @override
  String toString() => 'AttachmentOutgoingHolds(<redacted>)';
}
