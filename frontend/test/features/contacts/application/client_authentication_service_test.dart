import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/client_authentication_service.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/dio_contact_repository.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientAuthenticationService', () {
    test(
      'rejects malicious master-signature substitution and persists block',
      () async {
        final harness = _Harness()..crypto.rejectIdentity = true;

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(
          harness.local.trust?.state,
          ContactTrustState.identityUnavailable,
        );
        expect(harness.remote.claimCalls, 0);
      },
    );

    test('rejects an unsigned device before claiming prekeys', () async {
      final harness = _Harness();
      harness.remote.devices = [
        PeerPublicDevice(
          deviceId: _peerDeviceId,
          identityPublic: _bytes(64, 7),
          registrationId: 9,
          bundleVersion: null,
        ),
      ];

      final result = await harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: true,
      );

      expect(result, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.local.trust?.state, ContactTrustState.invalidDevice);
      expect(harness.remote.claimCalls, 0);
    });

    test('uses ETag cache and does not replay an unchanged log', () async {
      final harness = _Harness();

      final first = await harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: true,
      );
      harness.remote.notModified = true;
      final second = await harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: true,
      );

      expect(first, isA<Success<AuthenticatedPeer>>());
      expect(second, isA<Success<AuthenticatedPeer>>());
      expect(harness.remote.etags, [null, '"devices-v1"']);
      expect(harness.remote.logCalls, 1);
      expect(harness.local.records, hasLength(1));
    });

    test(
      'master-key change blocks and cannot reach sensitive key claims',
      () async {
        final harness = _Harness();
        harness.local.trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.verified,
          identity: harness.remote.identity,
          confirmedMasterPublic: harness.remote.identity.masterPublic,
          attestation: UserSigningAttestation(_bytes(64, 5)),
        );
        harness.remote.identity = _identity(master: 99);

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(harness.local.trust?.state, ContactTrustState.masterKeyChanged);
        expect(harness.remote.deviceCalls, 0);
        expect(harness.remote.claimCalls, 0);
        // The record holds the new identity and the tag issued for it, and,
        // blocked, sends that tag nowhere.
        expect(harness.local.trust?.identity?.masterPublic.first, 99);
        expect(harness.local.trust?.identityEtag, harness.remote.identityTag);
        await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );
        expect(harness.remote.identityEtags, [null, null]);
      },
    );

    test(
      'concurrent device-list change waits for its signed head extension',
      () async {
        final harness = _Harness();
        harness.local
          ..devices = [_device()]
          ..trust = ContactTrustRecord(
            userId: _peerUserId,
            state: ContactTrustState.verified,
            identity: harness.remote.identity,
            confirmedMasterPublic: harness.remote.identity.masterPublic,
            attestation: UserSigningAttestation(_bytes(64, 5)),
            etag: '"old"',
            logHeadSequence: 0,
            logHeadHash: _bytes(32, 11),
          );
        harness.remote.devices = [
          _device(),
          PeerPublicDevice(
            deviceId: '55555555-5555-4555-8555-555555555555',
            identityPublic: _bytes(64, 8),
            registrationId: 10,
            crossSignature: _bytes(64, 4),
            bundleVersion: 1,
          ),
        ];

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(
          (result as FailureResult<AuthenticatedPeer>).failure,
          isA<SecurityFailure>().having(
            (failure) => failure.kind,
            'kind',
            SecurityFailureKind.policyBlocked,
          ),
        );
        expect(harness.local.trust?.state, ContactTrustState.verified);
        expect(harness.remote.claimCalls, 0);
      },
    );

    test('malicious server rollback persists a global peer fork', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_device()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.verified,
          identity: harness.remote.identity,
          confirmedMasterPublic: harness.remote.identity.masterPublic,
          attestation: UserSigningAttestation(_bytes(64, 5)),
          etag: '"newer"',
          logHeadSequence: 1,
          logHeadHash: _bytes(32, 13),
        );

      final result = await harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: true,
      );

      expect(result, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.local.trust?.state, ContactTrustState.deviceLogFork);
      expect(harness.remote.logCalls, 0);
      expect(harness.remote.claimCalls, 0);
    });

    test(
      'non-extending predicted sequence is treated as equivocation',
      () async {
        final harness = _Harness();
        harness.local
          ..devices = [_device()]
          ..trust = ContactTrustRecord(
            userId: _peerUserId,
            state: ContactTrustState.verified,
            identity: harness.remote.identity,
            confirmedMasterPublic: harness.remote.identity.masterPublic,
            attestation: UserSigningAttestation(_bytes(64, 5)),
            etag: '"old"',
            logHeadSequence: 0,
            logHeadHash: _bytes(32, 11),
          );
        harness.remote
          ..advertisedHead = 1
          ..logHead = 1
          ..logRecords = [
            PeerDeviceLogRecord(sequence: 1, blob: _bytes(8, 14)),
          ];

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(harness.local.trust?.state, ContactTrustState.deviceLogFork);
        expect(harness.remote.claimCalls, 0);
      },
    );

    test(
      'verified monotonic prekey rotation waits for its device-log append',
      () async {
        final harness = _Harness();
        final originalTrust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.verified,
          identity: harness.remote.identity,
          confirmedMasterPublic: harness.remote.identity.masterPublic,
          attestation: UserSigningAttestation(_bytes(64, 5)),
          etag: '"old"',
          logHeadSequence: 0,
          logHeadHash: _bytes(32, 11),
        );
        harness.local
          ..devices = [_device()]
          ..trust = originalTrust;
        harness.remote.devices = [
          PeerPublicDevice(
            deviceId: _peerDeviceId,
            identityPublic: _bytes(64, 7),
            registrationId: 9,
            crossSignature: _bytes(64, 6),
            bundleVersion: 2,
          ),
        ];

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(
          (result as FailureResult<AuthenticatedPeer>).failure,
          const SecurityFailure(SecurityFailureKind.policyBlocked),
        );
        expect(harness.local.trust, same(originalTrust));
        expect(harness.remote.claimCalls, 0);
      },
    );

    test(
      'any persisted device-log fork blocks all sensitive refreshes',
      () async {
        final harness = _Harness()..local.anyFork = true;

        final result = await harness.service.refreshPeer(
          userId: _peerUserId,
          requirePrekeys: true,
        );

        expect(result, isA<FailureResult<AuthenticatedPeer>>());
        expect(harness.remote.identityCalls, 0);
      },
    );

    test('out-of-band confirmation consumes no one-time prekeys', () async {
      final harness = _Harness();

      final result = await harness.service.confirmOutOfBand(
        userId: _peerUserId,
        exactMasterPublic: harness.remote.identity.masterPublic,
      );

      expect(result, isA<Success<ContactTrustRecord>>());
      expect(harness.remote.claimCalls, 0);
    });

    test(
      'selective refresh claims only the explicitly requested live device',
      () async {
        final harness = _Harness();
        harness.remote.devices = [
          _device(),
          PeerPublicDevice(
            deviceId: '55555555-5555-4555-8555-555555555555',
            identityPublic: _bytes(64, 8),
            registrationId: 10,
            crossSignature: _bytes(64, 6),
            bundleVersion: 1,
          ),
        ];

        final result = await harness.service.refreshPeerForDevices(
          userId: _peerUserId,
          deviceIds: const [_peerDeviceId],
        );

        expect(result, isA<Success<AuthenticatedPeer>>());
        final peer = (result as Success<AuthenticatedPeer>).value;
        expect(peer.devices, hasLength(2));
        expect(peer.claimedBundles, hasLength(1));
        expect(peer.canPerformSensitiveActions, isFalse);
        expect(harness.remote.claimedDeviceIds, [
          const [_peerDeviceId],
        ]);
      },
    );

    test('accepts the first cross-signature a cached device gains', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_unsignedDevice()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.unverified,
          identity: _identity(),
          etag: '"old"',
        );

      final result = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(result, isA<Success<AuthenticatedPeer>>());
      expect(harness.local.trust?.state, ContactTrustState.unverified);
      expect(harness.local.devices.single.crossSignature, isNotNull);
      expect(harness.local.devices.single.bundleVersion, 1);
    });

    test('refuses a signature that does not move the version on', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_device()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.unverified,
          identity: _identity(),
          etag: '"old"',
        );
      harness.remote.devices = [
        PeerPublicDevice(
          deviceId: _peerDeviceId,
          identityPublic: _bytes(64, 7),
          registrationId: 9,
          crossSignature: _bytes(64, 6),
          bundleVersion: 3,
        ),
      ];

      final result = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(result, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.local.trust?.state, ContactTrustState.invalidDevice);
    });

    test('a blocked record is revalidated without its stored tags', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_unsignedDevice()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.invalidDevice,
          identity: _identity(),
          etag: '"stale"',
          identityEtag: harness.remote.identityTag,
        );

      final result = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(result, isA<Success<AuthenticatedPeer>>());
      expect(harness.remote.etags, [null]);
      expect(harness.remote.identityEtags, [null]);
    });

    test('a refused device list never becomes a cache validator', () async {
      final harness = _Harness();
      harness.remote.devices = [_unsignedDevice()];

      final first = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );
      harness.remote.devices = [_device()];
      final second = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(first, isA<FailureResult<AuthenticatedPeer>>());
      expect(second, isA<Success<AuthenticatedPeer>>());
      expect(harness.remote.etags, [null, null]);
    });

    test('own-device claims reject substituted own account identity', () async {
      final harness = _Harness()..remote.identity = _identity(master: 99);

      final result = await harness.service.refreshPeerForDevices(
        userId: _localUserId,
        deviceIds: const [_peerDeviceId],
      );

      expect(result, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.claimCalls, 0);
    });
  });

  group('the conditional identity read', () {
    test(
      'sends the tag stored beside the identity, and a 304 keeps both',
      () async {
        final harness = _Harness();
        await harness.service.resolveLiveDevices(userId: _peerUserId);
        expect(harness.local.trust?.identityEtag, harness.remote.identityTag);

        final second = await harness.service.resolveLiveDevices(
          userId: _peerUserId,
        );

        expect(second, isA<Success<AuthenticatedPeer>>());
        expect(harness.remote.identityEtags, [
          null,
          harness.remote.identityTag,
        ]);
        expect(harness.remote.identityNotModifiedAnswers, 1);
        expect(harness.local.trust?.identity?.version, 1);
        expect(harness.local.trust?.identityEtag, harness.remote.identityTag);
      },
    );

    test(
      'a 304 stands for the stored identity, which is checked again',
      () async {
        final harness = _Harness();
        await harness.service.resolveLiveDevices(userId: _peerUserId);
        harness.crypto.rejectIdentity = true;

        final refused = await harness.service.resolveLiveDevices(
          userId: _peerUserId,
        );

        expect(harness.remote.identityNotModifiedAnswers, 1);
        expect(refused, isA<FailureResult<AuthenticatedPeer>>());
        expect(
          harness.local.trust?.state,
          ContactTrustState.identityUnavailable,
        );
        // Refused, so the tag goes, and the next read is a full one.
        expect(harness.local.trust?.identityEtag, isNull);
      },
    );

    test('an identity that moved comes back whole with its new tag', () async {
      final harness = _Harness();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      final first = harness.remote.identityTag;
      harness.remote.identity = _identity(version: 2);

      await harness.service.resolveLiveDevices(userId: _peerUserId);

      expect(harness.remote.identityEtags, [null, first]);
      expect(harness.remote.identityNotModifiedAnswers, 0);
      expect(harness.local.trust?.identity?.version, 2);
      expect(harness.local.trust?.identityEtag, harness.remote.identityTag);
      expect(harness.local.trust?.identityEtag, isNot(first));
    });

    test('an identity never published is a 404 whatever tag is sent', () async {
      final harness = _Harness();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      final held = harness.local.trust?.identityEtag;
      harness.remote.unpublished.add(_peerUserId);

      final result = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      // The tag was sent, and the route answered for the missing row rather
      // than for the tag.
      expect(held, isNotNull);
      expect(harness.remote.identityEtags.last, held);
      expect(
        _failureOf(result),
        const BackendFailure(BackendFailureCode.notFound),
      );
      expect(harness.local.trust?.state, ContactTrustState.identityUnavailable);
      expect(harness.local.trust?.identityEtag, isNull);
      expect(harness.local.trust?.etag, isNull);
      expect(harness.local.trust?.peerStateEtag, isNull);

      // So once the identity is back, it is asked for whole.
      harness.remote.unpublished.clear();
      final recovered = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );
      expect(harness.remote.identityEtags.last, isNull);
      expect(recovered, isA<Success<AuthenticatedPeer>>());
    });

    test('a 304 to a read that sent no tag is refused', () async {
      // An identity is stored, but no tag beside it, as in every record
      // written before the identity read was conditional.
      final harness = _Harness()..remote.forceIdentityNotModified = true;
      harness.local
        ..devices = [_device()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.unverified,
          identity: _identity(),
          etag: '"devices-v1"',
          logHeadSequence: 0,
          logHeadHash: _bytes(32, 11),
        );

      final result = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(harness.remote.identityEtags, [null]);
      expect(
        _failureOf(result),
        const SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
      expect(harness.local.trust?.state, ContactTrustState.identityUnavailable);
    });
  });

  group('resolveLiveDevicesForUsers', () {
    test('one read answers every user, and no per-user read is made', () async {
      final harness = _Harness();

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId, _otherUserId],
      );

      final peers = _resolved(result);
      expect(peers.keys, [_peerUserId, _otherUserId]);
      expect(peers.values, everyElement(isA<Success<AuthenticatedPeer>>()));
      expect(
        harness.remote.peerStateQueries.single.map(
          (query) => (query.userId, query.etag),
        ),
        [(_peerUserId, null), (_otherUserId, null)],
      );
      expect(harness.remote.identityCalls, 0);
      expect(harness.remote.deviceCalls, 0);
      // Neither log had been read before, so each is read from its start.
      expect(harness.remote.logCalls, 2);
      for (final userId in const [_peerUserId, _otherUserId]) {
        expect(
          harness.local.trusts[userId]?.state,
          ContactTrustState.unverified,
        );
        expect(harness.local.trusts[userId]?.peerStateEtag, '"peers-v1"');
        expect(harness.local.trusts[userId]?.etag, isNull);
      }
    });

    test('an unchanged peer is verified from what is stored', () async {
      final harness = _Harness();
      await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );

      expect(harness.remote.peerStateQueries.last.single.etag, '"peers-v1"');
      expect(
        harness.remote.answered.last[_peerUserId],
        isA<PeerStateUnchanged>(),
      );
      final peer = _resolved(result)[_peerUserId];
      expect(peer, isA<Success<AuthenticatedPeer>>());
      // No body came back: the devices are the stored ones, the head is the
      // stored head, and the log is not read a second time.
      expect(
        (peer! as Success<AuthenticatedPeer>).value.devices.single.deviceId,
        _peerDeviceId,
      );
      expect(harness.remote.logCalls, 1);
      expect(harness.local.trust?.logHeadSequence, 0);
      expect(harness.local.trust?.peerStateEtag, '"peers-v1"');
    });

    test('an unchanged answer is checked like any other', () async {
      final harness = _Harness();
      await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );
      harness.crypto.rejectIdentity = true;

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );

      expect(
        harness.remote.answered.last[_peerUserId],
        isA<PeerStateUnchanged>(),
      );
      expect(_resolved(result)[_peerUserId], isA<FailureResult<Object?>>());
      expect(harness.local.trust?.state, ContactTrustState.identityUnavailable);
      // Refused, so its tag goes too, and the next read is a full one.
      expect(harness.local.trust?.peerStateEtag, isNull);
    });

    test(
      'a user left out of the answer is blocked as the identity 404 blocks it',
      () async {
        final harness = _Harness()..remote.absent.add(_otherUserId);

        final result = await harness.service.resolveLiveDevicesForUsers(
          userIds: const [_otherUserId, _peerUserId],
        );

        final peers = _resolved(result);
        expect(harness.remote.peerStateQueries.single, hasLength(2));
        expect(
          harness.remote.answered.single[_otherUserId],
          isA<PeerStateAbsent>(),
        );
        expect(
          _failureOf(peers[_otherUserId]),
          const BackendFailure(BackendFailureCode.notFound),
        );
        expect(
          harness.local.trusts[_otherUserId]?.state,
          ContactTrustState.identityUnavailable,
        );
        // Matched by id, so the user after the missing one is still verified.
        expect(peers[_peerUserId], isA<Success<AuthenticatedPeer>>());
      },
    );

    test('a user with no published identity is blocked the same way', () async {
      final harness = _Harness()..remote.unpublished.add(_peerUserId);

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );

      expect(
        _failureOf(_resolved(result)[_peerUserId]),
        const BackendFailure(BackendFailureCode.notFound),
      );
      expect(harness.local.trust?.state, ContactTrustState.identityUnavailable);
      expect(harness.remote.deviceCalls, 0);
    });

    test('each route is only ever sent its own tag', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_device()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.unverified,
          identity: _identity(),
          etag: '"devices-v0"',
          logHeadSequence: 0,
          logHeadHash: _bytes(32, 11),
        );

      // The device list's tag answers nothing the batched read is asked. The
      // answer carries two tags, its own and the identity read's inside its
      // identity, and each is stored on its own side.
      await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );
      expect(harness.local.trust?.etag, '"devices-v0"');
      expect(harness.local.trust?.peerStateEtag, '"peers-v1"');
      expect(harness.local.trust?.identityEtag, '"identity-1-1"');

      // Nothing moved, so each tag outlives a read by the other route, and
      // the identity is confirmed with a `304`.
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      expect(harness.local.trust?.etag, '"devices-v1"');
      expect(harness.local.trust?.peerStateEtag, '"peers-v1"');
      expect(harness.local.trust?.identityEtag, '"identity-1-1"');

      // The identity moves. The batched read stores it with its new tag, and
      // the device list's tag, which vouched for the state before it, is
      // dropped.
      harness.remote
        ..identity = _identity(version: 2)
        ..peerStateTag = '"peers-v2"';
      await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );
      expect(harness.local.trust?.identity?.version, 2);
      expect(harness.local.trust?.etag, isNull);
      expect(harness.local.trust?.peerStateEtag, '"peers-v2"');
      expect(harness.local.trust?.identityEtag, '"identity-1-2"');

      await harness.service.resolveLiveDevices(userId: _peerUserId);

      expect(harness.remote.etags, ['"devices-v0"', null]);
      expect(
        harness.remote.peerStateQueries.map((queries) => queries.single.etag),
        [null, '"peers-v1"'],
      );
      expect(harness.remote.identityEtags, [
        '"identity-1-1"',
        '"identity-1-2"',
      ]);
      expect(harness.remote.identityNotModifiedAnswers, 2);
      expect(harness.local.trust?.etag, '"devices-v1"');
      expect(harness.local.trust?.peerStateEtag, '"peers-v2"');
      expect(harness.local.trust?.identityEtag, '"identity-1-2"');
    });

    test('a refused record is read again without its tag', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_unsignedDevice()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.invalidDevice,
          identity: _identity(),
          peerStateEtag: '"peers-v1"',
        );

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId],
      );

      // Sent, the tag would have been answered `unchanged`, and the refused
      // list in storage would have been refused again.
      expect(harness.remote.peerStateQueries.single.single.etag, isNull);
      expect(_resolved(result)[_peerUserId], isA<Success<AuthenticatedPeer>>());
    });

    test('a fork found in one user withholds every user after it', () async {
      final harness = _Harness();
      harness.local
        ..devices = [_device()]
        ..trust = ContactTrustRecord(
          userId: _peerUserId,
          state: ContactTrustState.unverified,
          identity: _identity(),
          logHeadSequence: 1,
          logHeadHash: _bytes(32, 13),
        );

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId, _otherUserId],
      );

      final peers = _resolved(result);
      expect(harness.local.trust?.state, ContactTrustState.deviceLogFork);
      expect(peers[_peerUserId], isA<FailureResult<Object?>>());
      expect(
        _failureOf(peers[_otherUserId]),
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      );
      expect(harness.local.trusts[_otherUserId], isNull);
    });

    test('a substituted own identity is refused here too', () async {
      final harness = _Harness()..remote.identity = _identity(master: 99);

      final result = await harness.service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId, _localUserId],
      );

      expect(
        _failureOf(_resolved(result)[_localUserId]),
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    });

    test(
      'a recorded fork withholds everybody before anything is read',
      () async {
        final harness = _Harness()..local.anyFork = true;

        final result = await harness.service.resolveLiveDevicesForUsers(
          userIds: const [_peerUserId],
        );

        expect(
          (result as FailureResult<Object?>).failure,
          const SecurityFailure(SecurityFailureKind.policyBlocked),
        );
        expect(harness.remote.peerStateQueries, isEmpty);
      },
    );

    test('refuses an empty, repeated or malformed list', () async {
      final harness = _Harness();

      for (final userIds in [
        const <String>[],
        const [_peerUserId, _peerUserId],
        [_peerUserId, _peerUserId.toUpperCase()],
        const ['not-a-user'],
      ]) {
        final result = await harness.service.resolveLiveDevicesForUsers(
          userIds: userIds,
        );
        expect(
          (result as FailureResult<Object?>).failure,
          const ValidationFailure(ValidationFailureKind.invalidInput),
        );
      }
      expect(harness.remote.peerStateQueries, isEmpty);
    });
  });

  // These answers go through the application's own REST client and parsers,
  // so the device is the one the server's JSON makes. The parsers used to
  // refuse that JSON, and the read failed as a malformed answer before this
  // service could judge the device.
  group('an unsigned device in a server answer', () {
    test('blocks its peer on the per-user read', () async {
      final server = _Server()
        ..answers['GET /api/v1/users/$_peerUserId/identity'] = _identityJson
        ..answers['GET /api/v1/users/$_peerUserId/devices'] = {
          'devices': [_deviceJson, _unsignedDeviceJson],
          'etag': '"devices-v1"',
          'log_head_seq': 0,
        };
      final local = _Local();
      final service = ClientAuthenticationService(
        remote: server.repository(),
        local: local,
        crypto: _Crypto(),
      );

      final result = await service.resolveLiveDevices(userId: _peerUserId);

      expect(
        _failureOf(result),
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
      expect(local.trust?.state, ContactTrustState.invalidDevice);
      expect(local.devices, isEmpty);
      // Refused on the list, so neither the log nor a prekey is asked for.
      expect(server.requests, [
        'GET /api/v1/users/$_peerUserId/identity',
        'GET /api/v1/users/$_peerUserId/devices',
      ]);
    });

    test('blocks only its own peer on the batched read', () async {
      final server = _Server()
        ..answers['POST /api/v1/peers'] = {
          'peers': [
            {
              'user_id': _peerUserId,
              'etag': '"peers-v1"',
              'identity': _identityJson,
              'devices': [_deviceJson, _unsignedDeviceJson],
              'log_head_seq': 0,
            },
            {
              'user_id': _otherUserId,
              'etag': '"peers-v1"',
              'identity': _identityJson,
              'devices': [
                {..._deviceJson, 'device_id': _otherDeviceId},
              ],
              'log_head_seq': 0,
            },
          ],
        }
        ..answers['GET /api/v1/users/$_otherUserId/devicelog'] = {
          'records': [
            {'seq': 0, 'blob': base64Encode(Uint8List(256))},
          ],
          'has_more': false,
          'head_seq': 0,
        };
      final local = _Local();
      final service = ClientAuthenticationService(
        remote: server.repository(),
        local: local,
        crypto: _Crypto(),
      );

      final result = await service.resolveLiveDevicesForUsers(
        userIds: const [_peerUserId, _otherUserId],
      );

      // The answer is read, so the call itself succeeds.
      expect(result, isA<Success<Map<String, Result<AuthenticatedPeer>>>>());
      final peers = _resolved(result);
      expect(
        _failureOf(peers[_peerUserId]),
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
      expect(local.trust?.state, ContactTrustState.invalidDevice);
      // The other peer in the same answer is verified and stored.
      expect(peers[_otherUserId], isA<Success<AuthenticatedPeer>>());
      expect(local.trusts[_otherUserId]?.state, ContactTrustState.unverified);
      expect(server.requests, [
        'POST /api/v1/peers',
        'GET /api/v1/users/$_otherUserId/devicelog',
      ]);
    });
  });
}

const _peerUserId = '11111111-1111-4111-8111-111111111111';
const _otherUserId = '66666666-6666-4666-8666-666666666666';
const _peerDeviceId = '22222222-2222-4222-8222-222222222222';
const _localUserId = '33333333-3333-4333-8333-333333333333';
const _localDeviceId = '44444444-4444-4444-8444-444444444444';
const _otherDeviceId = '77777777-7777-4777-8777-777777777777';

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));

PeerIdentityPublic _identity({int master = 1, int version = 1}) =>
    PeerIdentityPublic(
      masterPublic: _bytes(32, master),
      selfSigningPublic: _bytes(32, 2),
      userSigningPublic: _bytes(32, 3),
      masterSignature: _bytes(64, 4),
      version: version,
    );

Map<String, Result<AuthenticatedPeer>> _resolved(
  Result<Map<String, Result<AuthenticatedPeer>>> result,
) => (result as Success<Map<String, Result<AuthenticatedPeer>>>).value;

Failure _failureOf(Result<AuthenticatedPeer>? result) =>
    (result! as FailureResult<AuthenticatedPeer>).failure;

PeerPublicDevice _unsignedDevice() => PeerPublicDevice(
  deviceId: _peerDeviceId,
  identityPublic: _bytes(64, 7),
  registrationId: 9,
  bundleVersion: null,
);

PeerPublicDevice _device() => PeerPublicDevice(
  deviceId: _peerDeviceId,
  identityPublic: _bytes(64, 7),
  registrationId: 9,
  crossSignature: _bytes(64, 4),
  bundleVersion: 1,
);

ClaimedPrekeyBundle _bundle() => ClaimedPrekeyBundle(
  deviceId: _peerDeviceId,
  registrationId: 9,
  identityPublic: _bytes(64, 7),
  signedPrekeyId: 1,
  signedPrekeyPublic: _bytes(32, 8),
  signedPrekeySignature: _bytes(64, 9),
  crossSignature: _bytes(64, 4),
  bundleVersion: 1,
  pqSignedPrekeyId: 2,
  pqSignedPrekeyPublic: _bytes(1184, 10),
  pqSignedPrekeySignature: _bytes(64, 11),
);

/// [_identity] as the server serves it, with the identity route's own tag.
final _identityJson = <String, Object?>{
  'master_pub': base64Encode(_bytes(32, 1)),
  'self_signing_pub': base64Encode(_bytes(32, 2)),
  'user_signing_pub': base64Encode(_bytes(32, 3)),
  'master_sig': base64Encode(_bytes(64, 4)),
  'version': 1,
  'etag': '"identity-v1"',
};

/// [_device] as the server lists it.
final _deviceJson = <String, Object?>{
  'device_id': _peerDeviceId,
  'ik_pub': base64Encode(_bytes(64, 7)),
  'registration_id': 9,
  'cross_sig': base64Encode(_bytes(64, 4)),
  'bundle_version': 1,
};

/// A device between its registration and its cross-signature, as the server
/// lists it: it stores 0 until the follow-up `PUT` names a version.
final _unsignedDeviceJson = <String, Object?>{
  'device_id': '55555555-5555-4555-8555-555555555555',
  'ik_pub': base64Encode(_bytes(64, 8)),
  'registration_id': 10,
  'cross_sig': null,
  'bundle_version': 0,
};

final class _Harness {
  _Harness() {
    remote = _Remote();
    local = _Local();
    crypto = _Crypto();
    service = ClientAuthenticationService(
      remote: remote,
      local: local,
      crypto: crypto,
    );
  }

  late final _Remote remote;
  late final _Local local;
  late final _Crypto crypto;
  late final ClientAuthenticationService service;
}

final class _Remote implements PeerIdentityRemotePort {
  PeerIdentityPublic identity = _identity();
  List<PeerPublicDevice> devices = [_device()];

  /// The batched read's tag over the state above. A request carrying it is
  /// answered `unchanged`.
  var peerStateTag = '"peers-v1"';

  /// Users the batched read leaves out, as it does an unknown, inactive or
  /// deactivated account.
  final absent = <String>{};

  /// Users with no published identity: `identity: null` in the batched read,
  /// and `404 not_found` from the identity read whatever tag it carries.
  final unpublished = <String>{};
  final peerStateQueries = <List<PeerStateQuery>>[];
  final answered = <Map<String, PeerStateRead>>[];
  var notModified = false;

  /// Answers `304` to every identity read, whatever it carried.
  var forceIdentityNotModified = false;
  var identityCalls = 0;
  var identityNotModifiedAnswers = 0;

  /// The tag each identity read carried, in order.
  final identityEtags = <String?>[];
  var deviceCalls = 0;
  var claimCalls = 0;
  final claimedDeviceIds = <List<String>>[];
  var logCalls = 0;
  var advertisedHead = 0;
  var logHead = 0;
  List<PeerDeviceLogRecord> logRecords = [
    PeerDeviceLogRecord(sequence: 0, blob: _bytes(8, 12)),
  ];
  final etags = <String?>[];

  /// The identity read's tag, which moves with the key bytes and the version
  /// and with nothing else.
  String get identityTag =>
      '"identity-${identity.masterPublic.first}-${identity.version}"';

  @override
  Future<Result<PeerIdentityRefresh>> fetchIdentity({
    required String userId,
    String? etag,
  }) async {
    identityCalls += 1;
    identityEtags.add(etag);
    // There is no tag for a row that does not exist.
    if (unpublished.contains(userId)) {
      return const Result.failure(BackendFailure(BackendFailureCode.notFound));
    }
    if (forceIdentityNotModified || etag == identityTag) {
      identityNotModifiedAnswers += 1;
      return const Result.success(PeerIdentityNotModified());
    }
    return Result.success(
      PeerIdentityUpdated(identity: identity, etag: identityTag),
    );
  }

  @override
  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  }) async {
    deviceCalls += 1;
    etags.add(etag);
    if (notModified) return const Result.success(PeerDevicesNotModified());
    return Result.success(
      PeerDevicesUpdated(
        devices: devices,
        etag: '"devices-v1"',
        logHeadSequence: advertisedHead,
      ),
    );
  }

  @override
  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  }) async {
    claimCalls += 1;
    claimedDeviceIds.add(List.unmodifiable(deviceIds));
    return Result.success([_bundle()]);
  }

  @override
  Future<Result<PeerDeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) async {
    logCalls += 1;
    return Result.success(
      PeerDeviceLogPage(
        records: logRecords,
        hasMore: false,
        headSequence: logHead,
      ),
    );
  }

  @override
  Future<Result<Map<String, PeerStateRead>>> fetchPeerStates(
    List<PeerStateQuery> peers,
  ) async {
    peerStateQueries.add(List.unmodifiable(peers));
    final reads = <String, PeerStateRead>{
      for (final peer in peers)
        peer.userId: absent.contains(peer.userId)
            ? const PeerStateAbsent()
            : peer.etag == peerStateTag
            ? PeerStateUnchanged(etag: peerStateTag)
            : PeerStateUpdated(
                identity: unpublished.contains(peer.userId) ? null : identity,
                identityEtag: unpublished.contains(peer.userId)
                    ? null
                    : identityTag,
                devices: devices,
                logHeadSequence: advertisedHead,
                etag: peerStateTag,
              ),
    };
    answered.add(reads);
    return Result.success(reads);
  }
}

final class _Local implements ContactLocalPort {
  final trusts = <String, ContactTrustRecord>{};
  final storedDevices = <String, List<PeerPublicDevice>>{};
  final records = <VerifiedDeviceLogRecord>[];
  var anyFork = false;

  /// The peer's record and devices, which every single-user test is about.
  ContactTrustRecord? get trust => trusts[_peerUserId];
  set trust(ContactTrustRecord? value) =>
      value == null ? trusts.remove(_peerUserId) : trusts[_peerUserId] = value;

  List<PeerPublicDevice> get devices => storedDevices[_peerUserId] ?? const [];
  set devices(List<PeerPublicDevice> value) =>
      storedDevices[_peerUserId] = value;

  @override
  Future<Result<bool>> hasAnyDeviceLogFork() async => Result.success(
    anyFork ||
        trusts.values.any(
          (trust) => trust.state == ContactTrustState.deviceLogFork,
        ),
  );

  @override
  Future<Result<ContactTrustRecord?>> readTrust(String userId) async =>
      Result.success(trusts[userId]);

  @override
  Future<Result<void>> writeTrust(ContactTrustRecord trust) async {
    trusts[trust.userId] = trust;
    return const Result.success(null);
  }

  @override
  Future<Result<List<PeerPublicDevice>>> readDevices(String userId) async =>
      Result.success(storedDevices[userId] ?? const []);

  @override
  Future<Result<void>> replaceDevices(
    String userId,
    List<PeerPublicDevice> devices,
  ) async {
    storedDevices[userId] = devices;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> appendVerifiedLogRecords(
    String userId,
    List<VerifiedDeviceLogRecord> records,
  ) async {
    this.records.addAll(records);
    return const Result.success(null);
  }

  @override
  Future<Result<LocalAccountIdentity>> readLocalIdentity() async =>
      Result.success(
        LocalAccountIdentity(
          userId: _localUserId,
          deviceId: _localDeviceId,
          username: 'local',
          identityPackage: IdentityKeyPackage.fromNative(_identityPackage()),
        ),
      );

  @override
  Future<Result<void>> replaceDirectory(List<DirectoryUser> users) async =>
      const Result.success(null);

  @override
  Stream<ContactProjection?> watchContact(String userId) =>
      const Stream.empty();

  @override
  Stream<List<ContactProjection>> watchContacts({required String ownUserId}) =>
      const Stream.empty();

  @override
  Future<Result<void>> writeProfile(
    String userId,
    ProfileCiphertext ciphertext,
    AuthenticatedProfile? authenticated,
  ) async => const Result.success(null);
}

final class _Crypto implements IdentityCryptoPort {
  var rejectIdentity = false;

  @override
  Future<Result<void>> verifyIdentity({
    required Uint8List userId,
    required PeerIdentityPublic identity,
  }) async => rejectIdentity
      ? const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        )
      : const Result.success(null);

  @override
  Future<Result<void>> verifyClaimedBundle({
    required Uint8List userId,
    required Uint8List deviceId,
    required Uint8List selfSigningPublic,
    required ClaimedPrekeyBundle bundle,
  }) async => const Result.success(null);

  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) async => Result.success(
    PeerDeviceLogInspection(
      sequence: 0,
      previousHash: Uint8List(32),
      recordHash: _bytes(32, 11),
      liveDeviceSetHash: _bytes(32, 12),
      identityVersion: 1,
    ),
  );

  @override
  Future<Result<UserSigningAttestation>> attestPeerMaster({
    required IdentityKeyPackage localIdentity,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) async => Result.success(UserSigningAttestation(_bytes(64, 5)));

  @override
  Future<Result<void>> verifyUserAttestation({
    required Uint8List signerUserId,
    required Uint8List signerUserSigningPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
    required UserSigningAttestation attestation,
  }) async => const Result.success(null);

  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint({
    required Uint8List localUserId,
    required Uint8List localMasterPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) async => Result.success(SafetyFingerprint(_bytes(32, 42)));
}

/// The server, as far as these reads reach it: each route answers the JSON it
/// was given, and anything else is a `404`.
final class _Server implements HttpClientAdapter {
  final answers = <String, Object?>{};
  final requests = <String>[];

  PeerIdentityRemotePort repository() {
    final client = DioRestClient(
      serverOrigin: Uri.parse('https://chat.example.test'),
      dio: Dio()..httpClientAdapter = this,
    )..bindTokenCoordinator(const _TokenCoordinator());
    return DioContactRepository(client, const FixedServerConfig.fallback());
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final route = '${options.method} ${options.path}';
    requests.add(route);
    final answered = answers.containsKey(route);
    return ResponseBody.fromString(
      jsonEncode(
        answered
            ? answers[route]
            : {'code': 'not_found', 'detail': 'Not found.'},
      ),
      answered ? 200 : 404,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _TokenCoordinator implements AccessTokenCoordinator {
  const _TokenCoordinator();

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(
        AccessToken(
          value: 'access-token',
          expiresAt: DateTime.utc(2100),
          scope: SessionScope.full,
        ),
      );

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken) =>
      accessToken(forceRefresh: true);
}

Uint8List _identityPackage() {
  final recovery = Uint8List(0);
  final backup = Uint8List(0);
  final bytes = BytesBuilder(copy: false)
    ..add('CPIDV001'.codeUnits)
    ..addByte(0)
    ..add(_bytes(16, 3))
    ..add(_bytes(32, 1))
    ..add(_bytes(32, 2))
    ..add(_bytes(32, 3))
    ..add(_bytes(64, 4))
    ..add([0, recovery.length])
    ..add([0, 0, 0, backup.length])
    ..add(_bytes(96, 5))
    ..add(recovery)
    ..add(backup);
  return bytes.toBytes();
}
