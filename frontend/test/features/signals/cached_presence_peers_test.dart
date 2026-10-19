import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/signals/infrastructure/cached_presence_peers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/support/signal_fakes.dart';

const _own = '00000000-0000-4000-8000-0000000000a1';

/// ADR-098 D7: one batched read for up to 64 accounts, each answer reused for
/// at most 10 s, and discarded at once when this phone changes its trust.
void main() {
  late FakeSignalClock clock;
  late _Reads reads;
  late _Trust trust;
  late CachedPresencePeers peers;

  setUp(() {
    clock = FakeSignalClock();
    reads = _Reads();
    trust = _Trust();
    peers = CachedPresencePeers(
      delegate: reads,
      verifier: ContactPairwiseLiveDeviceResolverAdapter(
        delegate: reads,
        currentUserId: _own,
      ),
      trust: trust,
      clock: clock,
    );
  });

  test('one read answers many accounts, and is reused for 10 s', () async {
    final users = {for (var index = 1; index <= 3; index += 1) _user(index)};

    final first = await peers.verifiedDevices(users);
    clock.advance(const Duration(seconds: 9));
    await peers.verifiedDevices(users);
    final sealed = await peers.resolveVerifiedLiveDevices(_user(1));

    expect(reads.batches, [users.toList()]);
    expect(first[_user(1)], [_device(1)]);
    expect(
      (sealed as Success).value,
      hasLength(1),
      reason: 'the seal reuses the answer its targets came from',
    );

    clock.advance(const Duration(seconds: 1));
    await peers.verifiedDevices(users);
    expect(reads.batches, hasLength(2));
  });

  test('at most 64 accounts in one read', () async {
    await peers.verifiedDevices({
      for (var index = 1; index <= 65; index += 1) _user(index),
    });

    expect(reads.batches.map((batch) => batch.length), [64, 1]);
  });

  test('an unverified account and a blocked identity name no device', () async {
    reads.states[_user(2)] = ContactTrustState.unverified;
    reads.states[_user(3)] = ContactTrustState.masterKeyChanged;

    final answer = await peers.verifiedDevices({_user(1), _user(2), _user(3)});

    expect(answer.keys, [_user(1)]);
  });

  test('a change of trust discards that account\'s answer at once', () async {
    await peers.verifiedDevices({_user(1), _user(2)});
    trust.states[_user(2)] = ContactTrustState.masterKeyChanged;
    reads.states[_user(2)] = ContactTrustState.masterKeyChanged;

    final answer = await peers.verifiedDevices({_user(1), _user(2)});

    expect(answer.keys, [_user(1)]);
    expect(reads.batches.last, [_user(2)], reason: 'only it is read again');
  });

  test('a read that failed is kept for nobody', () async {
    reads.failing = true;
    expect(await peers.verifiedDevices({_user(1)}), isEmpty);

    reads.failing = false;
    expect(await peers.verifiedDevices({_user(1)}), hasLength(1));
    expect(reads.batches, hasLength(2));
  });
}

String _user(int index) =>
    '00000000-0000-4000-8000-${(0x100 + index).toRadixString(16).padLeft(12, '0')}';

String _device(int index) =>
    '00000000-0000-4000-8000-${(0x900 + index).toRadixString(16).padLeft(12, '0')}';

/// The batched peer read: every account verified with one signed device,
/// unless [states] says otherwise.
final class _Reads implements VerifiedLiveDeviceResolverPort {
  final batches = <List<String>>[];
  final states = <String, ContactTrustState>{};
  var failing = false;

  AuthenticatedPeer _peer(String userId) {
    final index = int.parse(userId.substring(24), radix: 16) - 0x100;
    return AuthenticatedPeer(
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
        PeerPublicDevice(
          deviceId: _device(index),
          identityPublic: _bytes(64, 5),
          registrationId: 7,
          bundleVersion: 1,
          crossSignature: _bytes(64, 6),
        ),
      ],
      claimedBundles: const [],
    );
  }

  @override
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  }) async => Result.success(_peer(userId));

  @override
  Future<Result<Map<String, Result<AuthenticatedPeer>>>>
  resolveLiveDevicesForUsers({required List<String> userIds}) async {
    batches.add(List.of(userIds));
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
final class _Trust implements ContactLocalPort {
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

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker));
