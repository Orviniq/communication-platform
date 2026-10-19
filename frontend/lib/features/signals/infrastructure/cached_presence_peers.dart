import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';

/// Presence's peer reads (ADR-098 D7): one `POST /api/v1/peers` for up to
/// [batchSize] accounts, each answer reused for at most [maximumAge].
///
/// One per-account identity read and device-list read on every presence seal
/// would cost a 32-member group most of the `accounts` scope in its first open
/// minute. The answer is the same verified resolution the durable path makes,
/// judged by the same checks; what is saved is round trips. Any change this
/// phone records to an account's trust discards that account's answer at
/// once, because each hit is checked against the trust state it was read
/// with.
///
/// It is the presence seal's live-device resolver too, so a seal reuses the
/// answer its targets were chosen from. Voice and the durable path resolve on
/// every send, as before.
final class CachedPresencePeers
    implements PresencePeersPort, PairwiseLiveDeviceResolverPort {
  CachedPresencePeers({
    required this.delegate,
    required this.verifier,
    required this.trust,
    required this.clock,
  });

  static const maximumAge = Duration(seconds: 10);
  static const batchSize = 64;

  final VerifiedLiveDeviceResolverPort delegate;
  final ContactPairwiseLiveDeviceResolverAdapter verifier;
  final ContactLocalPort trust;
  final TimeSource clock;

  final _answers = <String, _Answer>{};

  @override
  Future<Map<String, List<String>>> verifiedDevices(Set<String> userIds) async {
    final resolved = await _resolve(userIds);
    return {
      for (final MapEntry(:key, :value) in resolved.entries)
        if (value case Success(value: final devices))
          key: [for (final device in devices) device.deviceId.toLowerCase()],
    };
  }

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    final user = userId.toLowerCase();
    return (await _resolve({user}))[user] ??
        const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
  }

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async {
    final resolved = await _resolve({
      for (final user in userIds) user.toLowerCase(),
    });
    final devices = <String, List<VerifiedPairwiseLiveDevice>>{};
    for (final user in userIds) {
      final result =
          resolved[user.toLowerCase()] ??
          const Result<List<VerifiedPairwiseLiveDevice>>.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
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
    Set<String> userIds,
  ) async {
    final now = clock.now();
    final answers = <String, Result<List<VerifiedPairwiseLiveDevice>>>{};
    final stale = <String>[];
    for (final user in {for (final id in userIds) id.toLowerCase()}) {
      final cached = _answers[user];
      if (cached != null &&
          now.difference(cached.at) < maximumAge &&
          !now.isBefore(cached.at) &&
          await _trustState(user) == cached.trustState) {
        answers[user] = cached.result;
      } else {
        _answers.remove(user);
        stale.add(user);
      }
    }
    for (var start = 0; start < stale.length; start += batchSize) {
      final batch = stale.sublist(
        start,
        start + batchSize > stale.length ? stale.length : start + batchSize,
      );
      final read = await delegate.resolveLiveDevicesForUsers(userIds: batch);
      if (read case FailureResult(failure: final failure)) {
        // The read itself failed and said nothing about anybody: kept for
        // nobody, so the next seal reads again.
        for (final user in batch) {
          answers[user] = Result.failure(failure);
        }
        continue;
      }
      final peers =
          (read as Success<Map<String, Result<AuthenticatedPeer>>>).value;
      for (final user in batch) {
        final result = verifier.verifiedFrom(
          user,
          peers[user] ??
              const Result.failure(
                SecurityFailure(SecurityFailureKind.unauthenticatedInput),
              ),
        );
        answers[user] = result;
        _answers[user] = _Answer(
          at: now,
          trustState: await _trustState(user),
          result: result,
        );
      }
    }
    return answers;
  }

  Future<ContactTrustState?> _trustState(String userId) async =>
      switch (await trust.readTrust(userId)) {
        Success(:final value) => value?.state,
        FailureResult() => null,
      };
}

final class _Answer {
  const _Answer({
    required this.at,
    required this.trustState,
    required this.result,
  });

  final DateTime at;
  final ContactTrustState? trustState;
  final Result<List<VerifiedPairwiseLiveDevice>> result;
}
