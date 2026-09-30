/// Narrow core marker for an already authenticated voice-room commit that must
/// be persisted in the same transaction as its pairwise receive state.
///
/// The synchronization domain deliberately knows no voice-room types, exactly
/// as it knows no group types (`group_sync_model.dart`). The infrastructure
/// composition layer validates the concrete implementation before dispatching
/// to the room repository.
abstract interface class RoomSyncReceiveCommit {
  String get opaqueEventId;

  String get senderUserId;

  String get senderDeviceId;
}
