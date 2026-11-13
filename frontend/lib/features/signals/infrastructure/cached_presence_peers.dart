import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';

/// Presence's peer reads (ADR-098 D7): one `POST /api/v1/peers` for up to
/// [batchSize] accounts, each answer kept and served from the cache, so that
/// a frame does not wait for the network.
///
/// One per-account identity read and device-list read on every presence seal
/// would cost a 32-member group most of the `accounts` scope in its first open
/// minute. The answer is the same verified resolution the durable path makes,
/// judged by the same checks; what is saved is round trips.
///
/// **How old an answer may be.** One younger than [maximumAge] is fresh and
/// served as it is. One younger than [staleAge] is stale: served at once, and
/// its account read again in the background, by one read at a time. Only an
/// account with no answer, or with one of [staleAge] or more, waits for a
/// read, and every call that wants the same account meanwhile shares that
/// read. So an open chat still reads each account at most once in
/// [maximumAge], and only the first read of an account holds a frame back.
///
/// **What is not served stale.** An answer that refused the account (not
/// verified, blocked) is read again after [maximumAge]. A read that failed for
/// the whole batch is kept for nobody; when it was a background read, the
/// stale answer stays and no other background read of that account starts
/// for [refreshPause]. A device that a stale answer does not name is not known
/// yet: the caller that asks for it waits for one read of its account.
///
/// **Trust.** Each answer is tagged with this phone's trust in the account as
/// the read began. Any change this phone records to that trust drops the
/// answer at once, stale or not, and no call joins a read that began under
/// another trust.
///
/// It is the presence seal's live-device resolver too, so a seal reuses the
/// answer its targets were chosen from. A seal runs under the router lock, so
/// that resolver never reads: the channel read every target before it took
/// the lock, and an account with no answer young enough is refused. The
/// goodbye seals through [goodbyeResolver] instead, which serves the last
/// answer that verified the account, however old (ADR-101 G2). Voice and the
/// durable path resolve on every send, as before.
final class CachedPresencePeers
    implements PresencePeersPort, PairwiseLiveDeviceResolverPort {
  CachedPresencePeers({
    required this.delegate,
    required this.verifier,
    required this.trust,
    required this.clock,
  });

  static const maximumAge = Duration(seconds: 10);
  static const staleAge = Duration(seconds: 60);
  static const refreshPause = Duration(seconds: 5);
  static const batchSize = 64;

  final VerifiedLiveDeviceResolverPort delegate;
  final ContactPairwiseLiveDeviceResolverAdapter verifier;
  final ContactLocalPort trust;
  final TimeSource clock;

  final _answers = <String, _Answer>{};

  /// The one read in flight for each account.
  final _reads = <String, _Read>{};

  /// When a read of each account last failed for its whole batch.
  final _failedAt = <String, DateTime>{};

  /// The goodbye's live-device resolver (ADR-101 G2): [peek], as the seal
  /// asks it. It serves the last answer that verified each account, however
  /// old, and never reads: the `gone` must leave before the socket closes. An
  /// account with no such answer, or whose trust changed since, is refused as
  /// unverified.
  late final PairwiseLiveDeviceResolverPort goodbyeResolver = _HeldAnswers(
    this,
  );

  @override
  Future<Map<String, List<String>>> verifiedDevices(
    Set<String> userIds, {
    Set<PresenceDevice> including = const {},
  }) async {
    final required = <String, Set<String>>{};
    for (final device in including) {
      (required[device.userId.toLowerCase()] ??= {}).add(device.key);
    }
    final resolved = await _resolve(userIds, including: required);
    return {
      for (final MapEntry(:key, :value) in resolved.entries)
        if (value case Success(value: final devices)) key: _ids(devices),
    };
  }

  @override
  Future<List<String>?> peek(String userId) async {
    final answer = await _current(userId.toLowerCase(), clock.now());
    return switch (answer?.result) {
      Success(value: final devices) => _ids(devices),
      _ => null,
    };
  }

  /// The seal's question, asked under the router lock: the answer this cache
  /// holds, and never a read. A fresh answer, or a stale one that verified the
  /// account, is served; anything else is refused as unverified.
  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    final user = userId.toLowerCase();
    final now = clock.now();
    final answer = await _current(user, now);
    if (answer == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final age = now.difference(answer.at);
    final served = age < maximumAge || (answer.verified && age < staleAge);
    return served
        ? answer.result
        : const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
  }

  /// [resolveVerifiedLiveDevices] for each of [userIds], which presence never
  /// asks: it too only reads the cache.
  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async {
    final devices = <String, List<VerifiedPairwiseLiveDevice>>{};
    for (final user in userIds) {
      final result = await resolveVerifiedLiveDevices(user);
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      devices[user] =
          (result as Success<List<VerifiedPairwiseLiveDevice>>).value;
    }
    return Result.success(Map.unmodifiable(devices));
  }

  /// The inbound path's question, which presence never asks.
  @override
  Future<Result<InboundSenderResolution>> resolveInboundSender(String userId) =>
      verifier.resolveInboundSender(userId);

  Future<Map<String, Result<List<VerifiedPairwiseLiveDevice>>>> _resolve(
    Set<String> userIds, {
    Map<String, Set<String>> including = const {},
  }) async {
    final now = clock.now();
    final answers = <String, Result<List<VerifiedPairwiseLiveDevice>>>{};
    final waits = <String, Future<_ReadAnswers>>{};
    final wanted = <String, ContactTrustState?>{};
    final refresh = <String, ContactTrustState?>{};
    for (final user in {for (final id in userIds) id.toLowerCase()}) {
      final trustState = await _trustState(user);
      final cached = await _current(user, now, trustState: trustState);
      if (cached != null) {
        final age = now.difference(cached.at);
        if (age < maximumAge) {
          // Fresh: what it names is all there is, for 10 s.
          answers[user] = cached.result;
          continue;
        }
        if (cached.verified && age < staleAge) {
          final names = cached.names(including[user] ?? const {});
          final mayRead = _mayRead(user, now);
          if (names || !mayRead) {
            answers[user] = cached.result;
            if (mayRead && !_reads.containsKey(user)) {
              refresh[user] = trustState;
            }
            continue;
          }
          // A device the stale answer does not name: one read decides.
        }
      }
      final pending = _reads[user];
      if (pending != null && pending.trustStates[user] == trustState) {
        waits[user] = pending.answers;
      } else {
        wanted[user] = trustState;
      }
    }
    for (final batch in _batches(wanted)) {
      final read = _read(batch);
      for (final user in batch.keys) {
        waits[user] = read;
      }
    }
    for (final batch in _batches(refresh)) {
      // Nobody waits for it, and a failure is recorded where it happened.
      unawaited(_read(batch).then<void>((_) {}, onError: (Object _) {}));
    }
    for (final MapEntry(key: user, value: read) in waits.entries) {
      answers[user] =
          (await read)[user] ??
          const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
    }
    return answers;
  }

  /// Starts one read of [batch], each account with the trust it began under,
  /// and keeps what it says.
  Future<_ReadAnswers> _read(Map<String, ContactTrustState?> batch) {
    final users = batch.keys.toList();
    final at = clock.now();
    final completer = Completer<_ReadAnswers>();
    final read = _Read(completer.future, batch);
    for (final user in users) {
      _reads[user] = read;
    }
    unawaited(
      _readBatch(users, at, read).then(
        completer.complete,
        onError: (Object error, StackTrace stack) {
          for (final user in users) {
            _failedAt[user] = clock.now();
          }
          completer.completeError(error, stack);
        },
      ),
    );
    return completer.future.whenComplete(() {
      for (final user in users) {
        if (identical(_reads[user], read)) {
          _reads.remove(user);
        }
      }
    });
  }

  Future<_ReadAnswers> _readBatch(
    List<String> users,
    DateTime at,
    _Read read,
  ) async {
    final result = await delegate.resolveLiveDevicesForUsers(userIds: users);
    if (result case FailureResult(failure: final failure)) {
      // The read itself failed and said nothing about anybody: kept for
      // nobody, and a stale answer stays as it was.
      final failedAt = clock.now();
      for (final user in users) {
        _failedAt[user] = failedAt;
      }
      return {for (final user in users) user: Result.failure(failure)};
    }
    final peers =
        (result as Success<Map<String, Result<AuthenticatedPeer>>>).value;
    final answers = <String, Result<List<VerifiedPairwiseLiveDevice>>>{};
    for (final user in users) {
      final verified = verifier.verifiedFrom(
        user,
        peers[user] ??
            const Result.failure(
              SecurityFailure(SecurityFailureKind.unauthenticatedInput),
            ),
      );
      answers[user] = verified;
      _failedAt.remove(user);
      // A later read of the account, begun under another trust, wins.
      if (identical(_reads[user], read)) {
        _answers[user] = _Answer(
          at: at,
          trustState: read.trustStates[user],
          result: verified,
        );
      }
    }
    return answers;
  }

  /// The answer kept for [user], or null when there is none, when the clock
  /// went back past it, or when this phone's trust changed since its read
  /// began, which drops it.
  Future<_Answer?> _current(
    String user,
    DateTime now, {
    ContactTrustState? trustState,
  }) async {
    final cached = _answers[user];
    if (cached == null) {
      return null;
    }
    final current = trustState ?? await _trustState(user);
    if (now.isBefore(cached.at) || current != cached.trustState) {
      _answers.remove(user);
      return null;
    }
    return cached;
  }

  /// Whether an account whose stale answer is served may be read now: not
  /// within [refreshPause] of a read of it that failed.
  bool _mayRead(String user, DateTime now) {
    final failed = _failedAt[user];
    return failed == null || now.difference(failed) >= refreshPause;
  }

  Iterable<Map<String, ContactTrustState?>> _batches(
    Map<String, ContactTrustState?> users,
  ) sync* {
    final entries = users.entries.toList();
    for (var start = 0; start < entries.length; start += batchSize) {
      yield Map.fromEntries(
        entries.sublist(
          start,
          start + batchSize > entries.length
              ? entries.length
              : start + batchSize,
        ),
      );
    }
  }

  Future<ContactTrustState?> _trustState(String userId) async =>
      switch (await trust.readTrust(userId)) {
        Success(:final value) => value?.state,
        FailureResult() => null,
      };

  static List<String> _ids(List<VerifiedPairwiseLiveDevice> devices) => [
    for (final device in devices) device.deviceId.toLowerCase(),
  ];
}

typedef _ReadAnswers = Map<String, Result<List<VerifiedPairwiseLiveDevice>>>;

/// The answers [cache] holds, as the goodbye's seal reads them.
final class _HeldAnswers implements PairwiseLiveDeviceResolverPort {
  const _HeldAnswers(this.cache);

  final CachedPresencePeers cache;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    final answer = await cache._current(
      userId.toLowerCase(),
      cache.clock.now(),
    );
    return answer != null && answer.verified
        ? answer.result
        : const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
  }

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async {
    final devices = <String, List<VerifiedPairwiseLiveDevice>>{};
    for (final user in userIds) {
      final result = await resolveVerifiedLiveDevices(user);
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      devices[user] =
          (result as Success<List<VerifiedPairwiseLiveDevice>>).value;
    }
    return Result.success(Map.unmodifiable(devices));
  }

  /// The inbound path's question, which the goodbye never asks.
  @override
  Future<Result<InboundSenderResolution>> resolveInboundSender(String userId) =>
      cache.verifier.resolveInboundSender(userId);
}

/// One read in flight, shared by every call that wants an account of it
/// under the trust that account's read began with.
final class _Read {
  const _Read(this.answers, this.trustStates);

  final Future<_ReadAnswers> answers;
  final Map<String, ContactTrustState?> trustStates;
}

final class _Answer {
  const _Answer({
    required this.at,
    required this.trustState,
    required this.result,
  });

  /// When the read that gave it began.
  final DateTime at;
  final ContactTrustState? trustState;
  final Result<List<VerifiedPairwiseLiveDevice>> result;

  bool get verified => result is Success<List<VerifiedPairwiseLiveDevice>>;

  /// Whether this answer names every device of [devices], keys in lower case.
  bool names(Set<String> devices) {
    if (devices.isEmpty) {
      return true;
    }
    final result = this.result;
    if (result is! Success<List<VerifiedPairwiseLiveDevice>>) {
      return false;
    }
    final named = {
      for (final device in result.value) device.deviceId.toLowerCase(),
    };
    return named.containsAll(devices);
  }
}
