import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';

/// The two writes a `signal` frame makes, beside the durable store's.
///
/// A volatile seal advances ratchet state exactly as a durable send does and
/// writes no outbox row. A volatile open advances it exactly as a durable
/// receive does and writes no inbox row, no opened payload and no application
/// event. Both run under the same transaction, the same compare-and-set on
/// every revision and the same skipped-key bounds as the durable path, because
/// they move the same sessions.
abstract interface class PairwiseVolatileStore implements RepositoryPort {
  /// Commits every target's next state in one transaction, or none of them.
  ///
  /// A volatile seal only ever advances a ready primary session: it never
  /// starts one and never answers a repair, so a transition that would create
  /// a session is refused as input.
  Future<Result<void>> commitVolatileSeal(PairwiseVolatileSealCommit commit);

  /// Commits what opening one frame changed. A replay marker already held is
  /// an integrity failure.
  Future<Result<void>> commitVolatileOpen(PairwiseVolatileOpenCommit commit);
}
