import 'dart:async';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';

/// The limits in force right now, read without waiting.
///
/// Every caller that measures something against a server limit is on a path
/// that cannot await a database read: a socket frame is validated as it
/// arrives, a response is decoded inside a `decode` callback, and a widget
/// builds synchronously. So the durable row is followed once, here, and read
/// from memory everywhere else.
///
/// [current] is never absent. Before the deployment has answered it is the last
/// stored answer, and before there is one it is [ServerConfig.fallback] — which
/// is what makes a limit unable to stop the application from starting offline.
abstract interface class ServerConfigSnapshot implements Port {
  ServerConfig get current;
}

/// One configuration that never moves.
///
/// What a test constructs, and what a short-lived owner uses when it has
/// already read the row and will not outlive it — a background delivery run,
/// for instance, which starts, drains and ends inside one set of limits.
final class FixedServerConfig implements ServerConfigSnapshot {
  const FixedServerConfig(this.current);

  /// This build's own constants: what a caller holds before anything has been
  /// read.
  const FixedServerConfig.fallback() : current = ServerConfig.fallback;

  @override
  final ServerConfig current;
}

/// The latest value a [Stream] of configurations has produced.
///
/// The stream is the durable row, so this exists to turn "the operator's
/// numbers, eventually" into "the numbers in force, now". A session that
/// started with no network is holding the fallback and picks the deployment's
/// answer up the moment it is stored, without anything being rebuilt: the
/// socket stays open and the engine keeps its in-flight state, because what
/// they hold is this object rather than the value inside it.
///
/// [close] stops following. It is not required for correctness — an unclosed
/// follower holds one subscription and one small object — but a composition
/// root that creates one owns it.
final class LatestServerConfig implements ServerConfigSnapshot {
  LatestServerConfig(Stream<ServerConfig> configurations)
    : _current = ServerConfig.fallback {
    _subscription = configurations.listen(
      (config) => _current = config,
      // A stream that fails leaves the last good answer in force. There is
      // nothing better to fall to, and refusing to answer would take down every
      // caller that only wanted a number the server is enforcing anyway.
      onError: (Object _) {},
    );
  }

  ServerConfig _current;
  late final StreamSubscription<ServerConfig> _subscription;

  @override
  ServerConfig get current => _current;

  Future<void> close() => _subscription.cancel();
}
