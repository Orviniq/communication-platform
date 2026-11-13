import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/signals/infrastructure/cached_presence_peers.dart';

/// The batched peer read, `POST /api/v1/peers`: every account verified with
/// the signed devices [devices] names for it, or the one [deviceOf] gives,
/// unless [states] says otherwise.
final class FakePeerReads implements VerifiedLiveDeviceResolverPort {
  FakePeerReads({this.deviceOf, this.clock});

  final String Function(String userId)? deviceOf;

  /// Where [readAt] takes its times from, when the test wants them.
  final TimeSource? clock;
  final devices = <String, List<String>>{};
  final states = <String, ContactTrustState>{};

  /// Every read, in the order it started: the accounts it asked for.
  final batches = <List<String>>[];

  /// When each of [batches] started, on [clock].
  final readAt = <DateTime>[];

  /// Whether a read fails for the whole batch, as it is answered.
  var failing = false;

  /// While true, each read waits until [release] lets it answer.
  var hold = false;
  final held = <Completer<void>>[];

  /// Answers every read held so far.
  void release() {
    final waiting = List.of(held);
    held.clear();
    for (final read in waiting) {
      read.complete();
    }
  }

  AuthenticatedPeer _peer(String userId) => AuthenticatedPeer(
    trust: ContactTrustRecord(
      userId: userId,
      state: states[userId] ?? ContactTrustState.verified,
      identity: PeerIdentityPublic(
        masterPublic: _bytes(32, 1),
        selfSigningPublic: _bytes(32, 2),
        userSigningPublic: _bytes(32, 3),
        masterSignature: _bytes(64, 4),
        version: 1,
      ),
    ),
    devices: [
      for (final deviceId
          in devices[userId] ??
              [if (deviceOf case final device?) device(userId)])
        PeerPublicDevice(
          deviceId: deviceId,
          identityPublic: _bytes(64, 5),
          registrationId: 7,
          bundleVersion: 1,
          crossSignature: _bytes(64, 6),
        ),
    ],
    claimedBundles: const [],
  );

  @override
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  }) async => Result.success(_peer(userId));

  @override
  Future<Result<Map<String, Result<AuthenticatedPeer>>>>
  resolveLiveDevicesForUsers({required List<String> userIds}) async {
    batches.add(List.of(userIds));
    if (clock case final clock?) {
      readAt.add(clock.now());
    }
    if (hold) {
      final read = Completer<void>();
      held.add(read);
      await read.future;
    }
    if (failing) {
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    }
    return Result.success({
      for (final userId in userIds) userId: Result.success(_peer(userId)),
    });
  }
}

/// The trust this phone stores, which is all the cache reads of it.
final class FakeContactTrust implements ContactLocalPort {
  final states = <String, ContactTrustState>{};

  @override
  Future<Result<ContactTrustRecord?>> readTrust(String userId) async =>
      Result.success(
        ContactTrustRecord(
          userId: userId,
          state: states[userId] ?? ContactTrustState.verified,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The production peer cache over [reads] and [trust], on [clock].
CachedPresencePeers cachedPeers({
  required FakePeerReads reads,
  required FakeContactTrust trust,
  required TimeSource clock,
  required String currentUserId,
}) => CachedPresencePeers(
  delegate: reads,
  verifier: ContactPairwiseLiveDeviceResolverAdapter(
    delegate: reads,
    currentUserId: currentUserId,
  ),
  trust: trust,
  clock: clock,
);

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker));
