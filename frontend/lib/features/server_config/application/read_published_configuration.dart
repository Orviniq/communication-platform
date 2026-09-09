import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';

/// What one read left behind: the limits now in force, and whether they are the
/// deployment's own and durable.
///
/// [stored] is false both when the route did not answer and when the answer
/// could not be written, because the two have the same consequence — the next
/// start begins on the previous answer again.
typedef PublishedConfigurationRead = ({ServerConfig config, bool stored});

/// Reads the operator's limits once, at the start of a full-scope session, and
/// keeps them.
///
/// The values change only when the operator edits the environment file and
/// restarts, and the route counts against the `accounts` rate limit like every
/// other route on that scope, so this runs on startup rather than on a timer.
///
/// Nothing waits for it. The stored answer, or [ServerConfig.fallback] when
/// there is none, is already in force before the call is made, and a client
/// that could not reach the server keeps using it — which is what lets the
/// application start with no network at all. A failed read therefore changes
/// nothing: the numbers it would have brought are enforced by the server in any
/// case, so a client holding stale ones learns the same limits from a `413`, a
/// `409` or a `400 bad_bucket`.
final class ReadPublishedConfiguration {
  const ReadPublishedConfiguration({required this.remote, required this.store});

  final ServerConfigReadPort remote;
  final ServerConfigStore store;

  /// Fetches, stores what arrives, and answers the configuration in force
  /// afterwards — the published one on success, and the one already held on any
  /// failure.
  Future<PublishedConfigurationRead> refresh() async {
    final fetched = await remote.fetchPublishedConfig();
    switch (fetched) {
      case Success(value: final published):
        final written = await store.write(published);
        return (config: published, stored: written is Success<void>);
      case FailureResult():
        return (config: await store.read(), stored: false);
    }
  }
}
