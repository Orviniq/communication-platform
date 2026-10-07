import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';

/// Keeps the contacts feature's full identity/device-log verification in front of
/// selective prekey claims without creating a cross-feature application import.
final class ContactSelectivePairwiseClaimAdapter
    implements PairwiseSelectiveClaimPort {
  const ContactSelectivePairwiseClaimAdapter({
    required this.delegate,
    required this.currentUserId,
  });

  final SelectivePeerPrekeyClaimPort delegate;
  final String currentUserId;

  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    final result = await delegate.refreshPeerForDevices(
      userId: userId,
      deviceIds: deviceIds,
    );
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peer = (result as Success<AuthenticatedPeer>).value;
    final identity = peer.trust.identity;
    if ((userId != currentUserId && !peer.trust.isSensitiveActionAllowed) ||
        identity == null ||
        peer.devices.any((device) => device.isUnsigned)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final verifiedDevices = {
      for (final device in peer.devices)
        device.deviceId: VerifiedPairwiseLiveDevice(
          userId: userId,
          device: device,
          selfSigningPublic: identity.selfSigningPublic,
        ),
    };
    final claims = <String, VerifiedPairwiseClaim>{};
    for (final bundle in peer.claimedBundles) {
      final device = verifiedDevices[bundle.deviceId];
      if (device == null) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      claims[bundle.deviceId] = VerifiedPairwiseClaim(
        device: device,
        bundle: bundle,
      );
    }
    if (claims.length != peer.claimedBundles.length ||
        peer.claimedBundles.any(
          (bundle) => !bundle.hasPostQuantumSignedPrekey,
        )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: [...verifiedDevices.values],
        claims: claims,
      ),
    );
  }
}

final class ContactPairwiseLiveDeviceResolverAdapter
    implements PairwiseLiveDeviceResolverPort {
  const ContactPairwiseLiveDeviceResolverAdapter({
    required this.delegate,
    required this.currentUserId,
  });

  final VerifiedLiveDeviceResolverPort delegate;
  final String currentUserId;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async =>
      _verified(userId, await delegate.resolveLiveDevices(userId: userId));

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async {
    final result = await delegate.resolveLiveDevicesForUsers(userIds: userIds);
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peers =
        (result as Success<Map<String, Result<AuthenticatedPeer>>>).value;
    final resolved = <String, List<VerifiedPairwiseLiveDevice>>{};
    for (final userId in userIds) {
      final peer = peers[userId];
      final verified = peer == null
          ? const Result<List<VerifiedPairwiseLiveDevice>>.failure(
              SecurityFailure(SecurityFailureKind.unauthenticatedInput),
            )
          : _verified(userId, peer);
      if (verified case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      resolved[userId] =
          (verified as Success<List<VerifiedPairwiseLiveDevice>>).value;
    }
    return Result.success(Map.unmodifiable(resolved));
  }

  Result<List<VerifiedPairwiseLiveDevice>> _verified(
    String userId,
    Result<AuthenticatedPeer> result,
  ) {
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peer = (result as Success<AuthenticatedPeer>).value;
    final identity = peer.trust.identity;
    if ((userId != currentUserId && !peer.trust.isSensitiveActionAllowed) ||
        identity == null ||
        peer.devices.any((device) => device.isUnsigned)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return Result.success(
      List.unmodifiable([
        for (final device in peer.devices)
          VerifiedPairwiseLiveDevice(
            userId: userId,
            device: device,
            selfSigningPublic: identity.selfSigningPublic,
          ),
      ]),
    );
  }
}
