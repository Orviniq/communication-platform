import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';

/// The pairwise volatile seal, as presence asks for it.
final class PairwisePresenceSeal implements PresenceSealPort {
  const PairwisePresenceSeal({
    required this.sealer,
    required this.currentUserId,
    required this.currentDeviceId,
  });

  final PairwiseVolatileSealer sealer;
  final String currentUserId;
  final String currentDeviceId;

  @override
  Future<Result<List<PresenceSealOutcome>>> seal({
    required Uint8List payload,
    required List<PresenceDevice> targets,
    required Set<int> allowedLengths,
  }) async {
    final sealed = await sealer.seal(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      targets: [
        for (final target in targets)
          PairwiseLiveDevice(userId: target.userId, deviceId: target.deviceId),
      ],
      payload: payload,
      allowedLengths: allowedLengths,
    );
    if (sealed case FailureResult(:final failure)) {
      return Result.failure(failure);
    }
    final outcomes =
        (sealed as Success<List<PairwiseVolatileSealOutcome>>).value;
    // The sealer answers each target in the order it was asked.
    if (outcomes.length != targets.length) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    return Result.success([
      for (var index = 0; index < outcomes.length; index += 1)
        switch (outcomes[index]) {
          PairwiseVolatileSealed(:final frame) => PresenceSealed(
            targets[index],
            frame,
          ),
          PairwiseVolatileRefused(:final reason) => PresenceSealRefused(
            targets[index],
            _refusal(reason),
          ),
        },
    ]);
  }

  static PresenceSealRefusal _refusal(PairwiseVolatileRefusal reason) =>
      switch (reason) {
        PairwiseVolatileRefusal.notLive => PresenceSealRefusal.notLive,
        PairwiseVolatileRefusal.identityBlocked =>
          PresenceSealRefusal.identityBlocked,
        PairwiseVolatileRefusal.unverified => PresenceSealRefusal.unverified,
        PairwiseVolatileRefusal.noSession => PresenceSealRefusal.noSession,
        PairwiseVolatileRefusal.sessionUnderRepair =>
          PresenceSealRefusal.sessionUnderRepair,
        PairwiseVolatileRefusal.offBucket => PresenceSealRefusal.offBucket,
        PairwiseVolatileRefusal.sealFailed => PresenceSealRefusal.sealFailed,
      };
}

/// The conversations this phone holds, read from local storage: a direct
/// conversation's row names its peer, and a group is the one the screens see,
/// held only while it is active.
final class DriftPresenceConversations implements PresenceConversationsPort {
  const DriftPresenceConversations({
    required this.database,
    required this.groups,
  });

  final LocalDatabase database;
  final GroupRepositoryPort groups;

  @override
  Future<PresenceConversation?> read(String conversationId) async {
    if (!_conversationId.hasMatch(conversationId)) {
      return null;
    }
    final Conversation? row;
    try {
      row =
          await (database.select(database.conversations)
                ..where((row) => row.conversationId.equals(conversationId)))
              .getSingleOrNull();
    } on Object {
      return null;
    }
    if (row == null) {
      return null;
    }
    final kind = ConversationKind.values[row.kind];
    switch (kind) {
      case ConversationKind.direct:
        final peer = row.peerUserId;
        return peer == null
            ? null
            : PresenceDirectConversation(conversationId, peer);
      case ConversationKind.group:
        final read = await groups.readGroup(conversationId);
        if (read case Success(
          value: final group?,
        ) when group.lifecycle == GroupLifecycle.active) {
          return PresenceGroupConversation(
            conversationId,
            group.activeMembers.map((member) => member.userId),
          );
        }
        return null;
      case ConversationKind.saved:
        return null;
    }
  }
}

/// The typing presence shows, in the conversation state the chat headers
/// read.
final class VolatileStateTypingSink implements PresenceTypingSinkPort {
  const VolatileStateTypingSink(this.state);

  final VolatileConversationStatePort state;

  @override
  void showTyping({
    required String conversationId,
    required String userId,
    required String deviceId,
    required bool active,
    required DateTime expiresAt,
    required DateTime authenticatedAt,
  }) => state.applyTyping(
    conversationId: conversationId,
    userId: userId,
    deviceId: deviceId,
    isTyping: active,
    expiresAt: expiresAt,
    authenticatedAt: authenticatedAt,
  );

  @override
  void clearAll() => state.clearDisconnected();
}

/// The probe ledger in memory, for as long as the process lives. Schema 26
/// keeps the same entries durably (ADR-098 D8).
final class MemoryPresenceLedger implements PresenceLedgerPort {
  final _entries = <String, PresenceLedgerEntry>{};

  @override
  Future<Result<PresenceLedgerEntry?>> read({
    required String userId,
    required String deviceId,
  }) async => Result.success(_entries[_key(userId, deviceId)]);

  @override
  Future<Result<void>> write(PresenceLedgerEntry entry) async {
    _entries[_key(entry.userId, entry.deviceId)] = entry;
    return const Result.success(null);
  }

  static String _key(String userId, String deviceId) =>
      '${userId.toLowerCase()}|${deviceId.toLowerCase()}';
}

/// Dart timers.
final class TimerPresenceTimers implements PresenceTimerPort {
  const TimerPresenceTimers();

  @override
  PresenceTimer start(Duration delay, void Function() callback) =>
      _DartTimer(Timer(delay.isNegative ? Duration.zero : delay, callback));
}

final class _DartTimer implements PresenceTimer {
  const _DartTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final RegExp _conversationId = RegExp(r'^[0-9a-f]{64}$');
