/// What this phone can say about one peer's online status (ADR-098 D4, D8).
///
/// It is a lower bound: a peer online while this phone was not watching, a
/// peer this user has not verified and a peer whose own status is off all
/// read as [PeerStatusNone] or as an older [PeerStatusLastSeen].
sealed class PeerStatus {
  const PeerStatus();
}

/// Nothing to show: never seen online, or "Show my online status" is off on
/// this phone (D9).
final class PeerStatusNone extends PeerStatus {
  const PeerStatusNone();

  @override
  bool operator ==(Object other) => other is PeerStatusNone;

  @override
  int get hashCode => (PeerStatusNone).hashCode;

  @override
  String toString() => 'PeerStatusNone()';
}

/// One of the peer's devices sent an accepted presence frame in the last 40 s.
final class PeerStatusOnline extends PeerStatus {
  const PeerStatusOnline();

  @override
  bool operator ==(Object other) => other is PeerStatusOnline;

  @override
  int get hashCode => (PeerStatusOnline).hashCode;

  @override
  String toString() => 'PeerStatusOnline()';
}

/// The newest last seen over the peer's devices, by this phone's own clock.
final class PeerStatusLastSeen extends PeerStatus {
  const PeerStatusLastSeen(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is PeerStatusLastSeen && other.at.isAtSameMomentAs(at);

  @override
  int get hashCode => at.millisecondsSinceEpoch.hashCode;

  @override
  String toString() => 'PeerStatusLastSeen(<redacted>)';
}
