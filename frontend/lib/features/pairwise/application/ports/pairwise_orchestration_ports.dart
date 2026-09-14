import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';

final class VerifiedPairwiseClaims {
  VerifiedPairwiseClaims({
    required List<VerifiedPairwiseLiveDevice> liveDevices,
    required Map<String, VerifiedPairwiseClaim> claims,
  }) : liveDevices = List.unmodifiable(liveDevices),
       claims = Map.unmodifiable(claims);

  final List<VerifiedPairwiseLiveDevice> liveDevices;
  final Map<String, VerifiedPairwiseClaim> claims;
}

/// Device projection authenticated by the account identity and device log.
final class VerifiedPairwiseLiveDevice {
  VerifiedPairwiseLiveDevice({
    required this.userId,
    required this.device,
    required Uint8List selfSigningPublic,
  }) : selfSigningPublic = Uint8List.fromList(selfSigningPublic) {
    if (userId.isEmpty || this.selfSigningPublic.length != 32) {
      throw const FormatException('invalid verified pairwise device');
    }
  }

  final String userId;
  final PeerPublicDevice device;
  final Uint8List selfSigningPublic;

  String get deviceId => device.deviceId;
}

final class VerifiedPairwiseClaim {
  const VerifiedPairwiseClaim({required this.device, required this.bundle});

  final VerifiedPairwiseLiveDevice device;
  final ClaimedPrekeyBundle bundle;
}

/// Resolves the complete current live-device set without consuming prekeys.
/// Implementations must bind own-account results to the completed local identity.
abstract interface class PairwiseLiveDeviceResolverPort implements Port {
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  );
}

/// Names who an owed send is for, from the event it carries.
abstract interface class PairwiseSendAudiencePort implements Port {
  /// Null when the event's conversation names its own recipient. Otherwise
  /// every other user the event is for right now: an empty set is a group
  /// this device's account is the only active member of.
  Future<Result<Set<String>?>> resolveAudience({
    required String eventId,
    required String currentUserId,
  });
}

/// Authenticates the full live-device set but consumes keys only for [deviceIds].
abstract interface class PairwiseSelectiveClaimPort implements Port {
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  });
}

/// Typed orchestration facade over the reviewed native pairwise operation mux.
///
/// Implementations select initiate/repair replacement only when [claimedBundle] is
/// present. Dart never constructs cryptographic material itself.
abstract interface class PairwiseOutboundPreparationPort implements Port {
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  });
}
