import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_opener.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// The pairwise volatile seal, as the signalling transport asks for it.
final class PairwiseVoiceSignalSeal implements VoiceSignalSealPort {
  const PairwiseVoiceSignalSeal({
    required this.sealer,
    required this.currentUserId,
    required this.currentDeviceId,
  });

  final PairwiseVolatileSealer sealer;
  final String currentUserId;
  final String currentDeviceId;

  @override
  Future<Result<List<VoiceSealOutcome>>> seal({
    required Uint8List payload,
    required List<VoiceSignalTarget> targets,
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
          PairwiseVolatileSealed(:final frame) => VoiceSealed(
            targets[index],
            frame,
          ),
          PairwiseVolatileRefused(:final reason) => VoiceSealRefused(
            targets[index],
            _refusal(reason),
          ),
        },
    ]);
  }

  static VoiceSignalRefusal _refusal(PairwiseVolatileRefusal reason) =>
      switch (reason) {
        PairwiseVolatileRefusal.notLive => VoiceSignalRefusal.notLive,
        PairwiseVolatileRefusal.identityBlocked =>
          VoiceSignalRefusal.identityBlocked,
        PairwiseVolatileRefusal.unverified => VoiceSignalRefusal.unverified,
        PairwiseVolatileRefusal.noSession => VoiceSignalRefusal.noSession,
        PairwiseVolatileRefusal.sessionUnderRepair =>
          VoiceSignalRefusal.sessionUnderRepair,
        PairwiseVolatileRefusal.offBucket => VoiceSignalRefusal.offBucket,
        PairwiseVolatileRefusal.sealFailed => VoiceSignalRefusal.sealFailed,
      };
}

/// The pairwise volatile open, as the signalling transport asks for it.
final class PairwiseVoiceSignalOpen implements VoiceSignalOpenPort {
  const PairwiseVoiceSignalOpen(this.opener);

  final PairwiseVolatileOpener opener;

  @override
  Future<Result<VoiceSignalOpening>> open(Uint8List frame) async =>
      switch (await opener.open(frame)) {
        FailureResult(:final failure) => Result.failure(failure),
        Success(:final value) => Result.success(_PairwiseOpening(value)),
      };
}

final class _PairwiseOpening implements VoiceSignalOpening {
  const _PairwiseOpening(this._opening);

  final PairwiseVolatileOpening _opening;

  @override
  String get senderUserId => _opening.senderUserId;

  @override
  String get senderDeviceId => _opening.senderDeviceId;

  @override
  Uint8List get payload => _opening.payload;

  @override
  Future<Result<void>> commit() => _opening.commit();

  @override
  String toString() => 'VoiceSignalOpening(<redacted>)';
}
