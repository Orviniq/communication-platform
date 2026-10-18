import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _ownUser = '00000000-0000-4000-8000-0000000000a1';
const _peerUser = '00000000-0000-4000-8000-0000000000b1';
const _peerDevice = '00000000-0000-4000-8000-0000000000b2';

/// The inbound path's question (ADR-093 D12): only a refresh that succeeds in
/// the trust state `unverified` answers "unverified". Every other outcome is
/// the answer the send path gets, unchanged.
void main() {
  late _Peers peers;
  late ContactPairwiseLiveDeviceResolverAdapter adapter;

  setUp(() {
    peers = _Peers();
    adapter = ContactPairwiseLiveDeviceResolverAdapter(
      delegate: peers,
      currentUserId: _ownUser,
    );
  });

  test(
    'an unverified peer answers unverified with its public devices',
    () async {
      peers.answer = Result.success(_peer(ContactTrustState.unverified));

      final result = await adapter.resolveInboundSender(_peerUser);

      final resolution =
          (result as Success<InboundSenderResolution>).value
              as UnverifiedInboundSender;
      expect(resolution.userId, _peerUser);
      expect(resolution.devices.single.deviceId, _peerDevice);
    },
  );

  test('a verified peer answers verified', () async {
    peers.answer = Result.success(_peer(ContactTrustState.verified));

    final result = await adapter.resolveInboundSender(_peerUser);

    final resolution =
        (result as Success<InboundSenderResolution>).value
            as VerifiedInboundSender;
    expect(resolution.devices.single.deviceId, _peerDevice);
    expect(resolution.devices.single.userId, _peerUser);
  });

  test('this account answers verified, whatever its stored state', () async {
    peers.answer = Result.success(
      _peer(ContactTrustState.unverified, userId: _ownUser),
    );

    final result = await adapter.resolveInboundSender(_ownUser);

    expect(
      (result as Success<InboundSenderResolution>).value,
      isA<VerifiedInboundSender>(),
    );
  });

  test('a refresh that failed keeps its failure', () async {
    // A changed master key and a fork are `policyBlocked` from the refresh,
    // an invalid device is `unauthenticatedInput`, and an identity that could
    // not be read is that read's failure.
    for (final failure in const <Failure>[
      SecurityFailure(SecurityFailureKind.policyBlocked),
      SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      TransportFailure(TransportFailureKind.offline),
    ]) {
      peers.answer = Result.failure(failure);

      final result = await adapter.resolveInboundSender(_peerUser);

      expect(result, isA<FailureResult<InboundSenderResolution>>());
      expect((result as FailureResult).failure, failure);
    }
  });

  test(
    'an unverified peer with no identity or an unsigned device is refused',
    () async {
      for (final peer in [
        _peer(ContactTrustState.unverified, identity: false),
        _peer(ContactTrustState.unverified, signed: false),
      ]) {
        peers.answer = Result.success(peer);

        final result = await adapter.resolveInboundSender(_peerUser);

        expect(
          (result as FailureResult).failure,
          const SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
    },
  );

  test(
    'a stored state other than verified or unverified answers no hold',
    () async {
      for (final state in [
        ContactTrustState.masterKeyChanged,
        ContactTrustState.invalidDevice,
        ContactTrustState.deviceLogFork,
        ContactTrustState.identityUnavailable,
      ]) {
        peers.answer = Result.success(_peer(state));

        final result = await adapter.resolveInboundSender(_peerUser);

        expect(
          (result as FailureResult).failure,
          const SecurityFailure(SecurityFailureKind.policyBlocked),
          reason: '$state',
        );
      }
    },
  );

  test('every send still refuses an unverified peer', () async {
    peers.answer = Result.success(_peer(ContactTrustState.unverified));

    final result = await adapter.resolveVerifiedLiveDevices(_peerUser);

    expect(
      (result as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  });
}

AuthenticatedPeer _peer(
  ContactTrustState state, {
  String userId = _peerUser,
  bool identity = true,
  bool signed = true,
}) => AuthenticatedPeer(
  trust: ContactTrustRecord(
    userId: userId,
    state: state,
    identity: identity
        ? PeerIdentityPublic(
            masterPublic: _bytes(32, 1),
            selfSigningPublic: _bytes(32, 2),
            userSigningPublic: _bytes(32, 3),
            masterSignature: _bytes(64, 4),
            version: 1,
          )
        : null,
  ),
  devices: [
    PeerPublicDevice(
      deviceId: _peerDevice,
      identityPublic: _bytes(64, 5),
      registrationId: 7,
      bundleVersion: signed ? 1 : null,
      crossSignature: signed ? _bytes(64, 6) : null,
    ),
  ],
  claimedBundles: const [],
);

final class _Peers implements VerifiedLiveDeviceResolverPort {
  Result<AuthenticatedPeer> answer = const Result.failure(
    SecurityFailure(SecurityFailureKind.unauthenticatedInput),
  );

  @override
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  }) async => answer;

  @override
  Future<Result<Map<String, Result<AuthenticatedPeer>>>>
  resolveLiveDevicesForUsers({required List<String> userIds}) async =>
      Result.success({for (final userId in userIds) userId: answer});
}

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker));
