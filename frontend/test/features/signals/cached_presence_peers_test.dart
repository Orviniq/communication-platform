import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/infrastructure/cached_presence_peers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/support/signal_fakes.dart';
import 'support/peer_read_fakes.dart';

const _own = '00000000-0000-4000-8000-0000000000a1';

/// ADR-098 D7: one batched read for up to 64 accounts, each answer reused for
/// at most 10 s, and discarded at once when this phone changes its trust.
void main() {
  late FakeSignalClock clock;
  late FakePeerReads reads;
  late FakeContactTrust trust;
  late CachedPresencePeers peers;

  setUp(() {
    clock = FakeSignalClock();
    reads = FakePeerReads(deviceOf: (user) => _device(_index(user)));
    trust = FakeContactTrust();
    peers = cachedPeers(
      reads: reads,
      trust: trust,
      clock: clock,
      currentUserId: _own,
    );
  });

  tearDown(() {
    // A test that failed with a read held must not leave it waiting.
    reads
      ..hold = false
      ..release();
  });

  test('one read answers many accounts, is reused for 10 s, and is then '
      'served while it is read again', () async {
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

    // At 10 s the answer is stale: served at once, and read again behind.
    clock.advance(const Duration(seconds: 1));
    reads.hold = true;
    final stale = _Watched(peers.verifiedDevices(users));
    await pumpEventQueue();

    expect(stale.done, isTrue, reason: 'it did not wait for the read');
    expect(stale.value?[_user(1)], [_device(1)]);
    expect(reads.batches, hasLength(2), reason: 'one background read');
    expect(reads.held, hasLength(1));
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

  group('a stale answer is served while it is read again', () {
    test('T1: an answer of 11 s is served at once, the read runs in the '
        'background, and its answer is used without another', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(seconds: 11));
      reads.hold = true;

      final served = _Watched(peers.verifiedDevices({_user(1)}));
      await pumpEventQueue();

      expect(served.done, isTrue, reason: 'served while the read is pending');
      expect(served.value?[_user(1)], [_device(1)]);
      expect(reads.batches, hasLength(2), reason: 'the read started');
      expect(reads.held, hasLength(1), reason: 'and is still pending');

      reads.devices[_user(1)] = [_device(1), _device(2)];
      reads.release();
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 1));

      final next = await peers.verifiedDevices({_user(1)});

      expect(next[_user(1)], [_device(1), _device(2)], reason: 'the new one');
      expect(reads.batches, hasLength(2), reason: 'fresh: no read');
    });

    test('T2: an answer of 61 s waits for one read', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(seconds: 61));
      reads.hold = true;

      final answer = _Watched(peers.verifiedDevices({_user(1)}));
      await pumpEventQueue();

      expect(answer.done, isFalse, reason: 'expired: it waits');
      expect(reads.batches, hasLength(2));

      reads.release();
      await pumpEventQueue();

      expect(answer.done, isTrue);
      expect(answer.value?[_user(1)], [_device(1)]);
      expect(reads.batches, hasLength(2), reason: 'one read');
    });

    test('T3: concurrent calls share one read, cold and stale', () async {
      reads.hold = true;

      final cold = [
        for (var call = 0; call < 5; call += 1)
          _Watched(peers.verifiedDevices({_user(1)})),
      ];
      await pumpEventQueue();

      expect(reads.batches, hasLength(1), reason: 'one read for five calls');
      expect(cold.where((call) => call.done), isEmpty);

      reads.release();
      await pumpEventQueue();

      expect(cold.every((call) => call.done), isTrue);
      expect(
        cold.map((call) => call.value?[_user(1)]),
        everyElement([_device(1)]),
      );

      clock.advance(const Duration(seconds: 11));
      final stale = [
        for (var call = 0; call < 5; call += 1)
          _Watched(peers.verifiedDevices({_user(1)})),
      ];
      await pumpEventQueue();

      expect(stale.every((call) => call.done), isTrue, reason: 'served');
      expect(reads.batches, hasLength(2), reason: 'one background read');
      expect(reads.held, hasLength(1));
    });

    test('T4: a background read that failed keeps the stale answer, and the '
        'next waits 5 s', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(seconds: 11));
      reads.failing = true;

      expect(
        (await peers.verifiedDevices({_user(1)}))[_user(1)],
        [_device(1)],
        reason: 'stale, served',
      );
      await pumpEventQueue();
      expect(reads.batches, hasLength(2), reason: 'the refresh ran, failed');

      clock.advance(const Duration(seconds: 1));
      expect(
        (await peers.verifiedDevices({_user(1)}))[_user(1)],
        [_device(1)],
        reason: 'the stale answer stays',
      );
      await pumpEventQueue();
      expect(reads.batches, hasLength(2), reason: 'no refresh within 5 s');

      clock.advance(const Duration(seconds: 5));
      expect((await peers.verifiedDevices({_user(1)}))[_user(1)], [_device(1)]);
      await pumpEventQueue();
      expect(reads.batches, hasLength(3), reason: 'a refresh 6 s after');

      // 60 s after the read that answered: expired, so the call waits for
      // the read, which fails, and nobody is named.
      clock.advance(const Duration(seconds: 43));
      expect(await peers.verifiedDevices({_user(1)}), isEmpty);
      expect(reads.batches, hasLength(4));
    });

    test('T5: a change of trust drops a stale answer at once', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(seconds: 11));
      trust.states[_user(1)] = ContactTrustState.masterKeyChanged;
      reads.states[_user(1)] = ContactTrustState.masterKeyChanged;
      reads.hold = true;

      final answer = _Watched(peers.verifiedDevices({_user(1)}));
      await pumpEventQueue();

      expect(answer.done, isFalse, reason: 'not served: it waits for a read');

      reads.release();
      await pumpEventQueue();

      expect(answer.done, isTrue);
      expect(answer.value, isEmpty);
      expect(reads.batches, hasLength(2));
    });

    test('T6: a device a stale answer does not name waits for one read, '
        'and is named when that read names it', () async {
      await peers.verifiedDevices({_user(1)});
      final added = PresenceDevice(userId: _user(1), deviceId: _device(2));
      reads.devices[_user(1)] = [_device(1), _device(2)];

      // Fresh, the answer is all there is: no read for a device it lacks.
      clock.advance(const Duration(seconds: 5));
      expect(
        (await peers.verifiedDevices({_user(1)}, including: {added}))[_user(1)],
        [_device(1)],
      );
      expect(reads.batches, hasLength(1));

      clock.advance(const Duration(seconds: 6));
      reads.hold = true;
      final answer = _Watched(
        peers.verifiedDevices({_user(1)}, including: {added}),
      );
      await pumpEventQueue();

      expect(answer.done, isFalse, reason: 'unknown device: it waits');
      expect(reads.batches, hasLength(2));

      reads.release();
      await pumpEventQueue();

      expect(answer.value?[_user(1)], [_device(1), _device(2)]);
      expect(reads.batches, hasLength(2), reason: 'one read');
    });

    test('T7: peek answers from any age, never reads, and knows nothing of an '
        'account never read', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(minutes: 5));

      expect(await peers.peek(_user(1)), [_device(1)]);
      expect(await peers.peek(_user(2)), isNull);
      expect(reads.batches, hasLength(1), reason: 'no read');

      trust.states[_user(1)] = ContactTrustState.masterKeyChanged;
      expect(
        await peers.peek(_user(1)),
        isNull,
        reason: 'a change of trust drops it',
      );
      expect(reads.batches, hasLength(1));
    });

    test('peek knows nothing of an account the last answer refused', () async {
      reads.states[_user(1)] = ContactTrustState.unverified;
      await peers.verifiedDevices({_user(1)});

      expect(await peers.peek(_user(1)), isNull);
    });
  });

  group('the seal, under the router lock, never reads', () {
    test('it is served a stale answer and refused an expired one', () async {
      await peers.verifiedDevices({_user(1)});
      clock.advance(const Duration(seconds: 59));

      final stale = await peers.resolveVerifiedLiveDevices(_user(1));
      expect((stale as Success).value, hasLength(1));

      clock.advance(const Duration(seconds: 1));
      final expired = await peers.resolveVerifiedLiveDevices(_user(1));
      expect(expired, isA<FailureResult<Object?>>());

      expect(
        await peers.resolveVerifiedLiveDevices(_user(2)),
        isA<FailureResult<Object?>>(),
      );
      expect(reads.batches, hasLength(1), reason: 'no read, ever');
    });
  });
}

/// A call whose answer the test looks at without awaiting it.
final class _Watched<T> {
  _Watched(Future<T> future) {
    unawaited(
      future.then((value) {
        this.value = value;
        done = true;
      }),
    );
  }

  var done = false;
  T? value;
}

int _index(String userId) => int.parse(userId.substring(24), radix: 16) - 0x100;

String _user(int index) =>
    '00000000-0000-4000-8000-${(0x100 + index).toRadixString(16).padLeft(12, '0')}';

String _device(int index) =>
    '00000000-0000-4000-8000-${(0x900 + index).toRadixString(16).padLeft(12, '0')}';
