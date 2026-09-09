import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';

/// Where the published limits are read from: `GET /api/v1/config`, once, after
/// the client reaches full scope.
///
/// The route takes a full-scope token and counts against the `accounts` rate
/// limit like every other route on that scope, so it is polled on startup and
/// never on a timer. It touches no row and answers while the database is
/// refusing, which is why a failure here is never a reason to stop: the caller
/// keeps whatever it already stored.
abstract interface class ServerConfigReadPort implements Port {
  Future<Result<ServerConfig>> fetchPublishedConfig();
}

/// Where the answer is kept between starts.
///
/// It is durable rather than held in memory because the client must start when
/// it is offline, and because the numbers are the operator's rather than this
/// process's. [read] therefore never fails: an installation that has stored
/// nothing, and one whose row this build cannot parse, both read as
/// [ServerConfig.fallback] — a limit is not a reason the application will not
/// start.
abstract interface class ServerConfigStore implements RepositoryPort {
  /// The stored answer, or [ServerConfig.fallback] when there is none.
  Future<ServerConfig> read();

  /// The same value, and every later one, so that a session which started
  /// offline picks up the answer the moment it arrives.
  Stream<ServerConfig> watch();

  Future<Result<void>> write(ServerConfig config);
}
