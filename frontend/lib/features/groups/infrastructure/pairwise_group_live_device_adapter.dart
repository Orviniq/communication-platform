import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';

/// Infrastructure-only bridge from the authenticated pairwise device view to
/// the smaller group admission view.
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
              userId: device.userId.toLowerCase(),
              deviceId: device.deviceId.toLowerCase(),
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
