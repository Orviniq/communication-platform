abstract interface class SocketConnection {
  Stream<Object?> get messages;

  int? get closeCode;

  void add(Object message);

  Future<void> close([int? code]);
}

abstract interface class SocketConnector {
  /// [keepAlive], when supplied, is how often this connection proves it is
  /// still alive.
  ///
  /// It exists for one case and is null everywhere else: a connection held
  /// while nobody is looking at the application. A TCP connection dropped by a
  /// carrier's NAT or by a network that went away is not closed, it is simply
  /// never heard from again, so a socket with no keepalive can be dead for
  /// hours while the application believes it is connected — which is exactly
  /// the state a permanent "kept open" notice must never be displayed over. A
  /// foreground connection needs none of this, because the user is there and a
  /// dead socket is repaired by the next thing they do.
  Future<SocketConnection> connect({
    required Uri uri,
    required String accessToken,
    required Duration timeout,
    Duration? keepAlive,
  });
}
