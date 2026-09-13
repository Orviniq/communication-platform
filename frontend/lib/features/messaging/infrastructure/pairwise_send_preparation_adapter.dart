import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';

/// Runs the fan-out an echoed send owes, on the delivery cycle's thread.
///
/// Everything here used to happen between the user pressing send and their own
/// message appearing: two authenticated device lookups over HTTPS, a prekey
/// claim when a session had to be started, and one ratchet step per recipient
/// device. None of it is faster now — it simply no longer happens while
/// somebody is waiting for a bubble to appear.
///
/// What it no longer does is anything after that. This returns the moment the
/// send's own ciphertext is durable, so the outbox pass that follows carries it
/// to the wire without a second fan-out in front of it.
final class PairwiseSendPreparationAdapter implements SendPreparationPort {
  const PairwiseSendPreparationAdapter(
    this.coordinator, {
    this.audience,
    this.onPreparedForPeer,
  });

  final PairwiseFanoutCoordinator coordinator;

  /// Names the members of a group the event was written into. A direct or
  /// saved conversation resolves to nobody beyond its own peer.
  final PairwiseSendAudiencePort? audience;

  /// Records that this peer is now owed device-log gossip.
  ///
  /// It used to be `Future<void> Function(String)`, and it used to be awaited
  /// here — which meant a whole second fan-out, with its own device lookups and
  /// its own ratchet steps, ran between a sealed envelope and its `POST`.
  /// Gossip is owed to a peer, not to this message, and ADR-060's rule is that
  /// a delivery cycle sends the user's message before it does anything on
  /// anybody else's behalf.
  ///
  /// The return type is the guarantee. There is no future to await, no result
  /// to inspect and no path from a gossip failure back to a preparation whose
  /// ciphertext is already durable, so what a swallowed `try`/`catch` and a
  /// comment used to promise is now a property of the signature.
  final void Function(String peerUserId)? onPreparedForPeer;

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async {
    Set<String>? audienceUserIds;
    final resolver = audience;
    if (resolver != null) {
      final resolved = await resolver.resolveAudience(
        eventId: preparation.eventId,
        currentUserId: preparation.localUserId,
      );
      if (resolved case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      audienceUserIds = (resolved as Success<Set<String>?>).value;
    }
    final prepared = await coordinator.prepareOwedSend(
      OwedSendPreparation(
        operationId: preparation.operationId,
        eventId: preparation.eventId,
        currentUserId: preparation.localUserId,
        currentDeviceId: preparation.localDeviceId,
        peerUserId: preparation.peerUserId,
        audienceUserIds: audienceUserIds,
      ),
    );
    if (prepared case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if (audienceUserIds == null) {
      onPreparedForPeer?.call(preparation.peerUserId);
    }
    return const Result.success(null);
  }
}
