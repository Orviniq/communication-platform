import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';

/// Infrastructure-only bridge from the authenticated pairwise device view to
/// the smaller view groups need: who a device belongs to, and the key its
/// group control events are checked against.
final class PairwiseGroupLiveDeviceAdapter
    implements GroupLiveDeviceResolverPort {
  const PairwiseGroupLiveDeviceAdapter(this.delegate);

  final PairwiseLiveDeviceResolverPort delegate;

  @override
  Future<Result<List<GroupAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId) async {
    final result = await delegate.resolveVerifiedLiveDevices(userId);
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    try {
      return Result.success(
        List.unmodifiable([
          for (final device
              in (result as Success<List<VerifiedPairwiseLiveDevice>>).value)
            GroupAuthenticatedLiveDevice(
              userId: device.userId,
              deviceId: device.deviceId,
              // `ik_pub` is the Ed25519 device signing key followed by the
              // X25519 identity key (`backend/CLIENT_CONTRACT.md` §A). The
              // resolver has already refused any device it could not chain to
              // the account identity through the signed device log.
              signingPublic: Uint8List.sublistView(
                device.device.identityPublic,
                0,
                32,
              ),
            ),
        ]),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }
}
