import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/group_production_gate.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/unsupported_group_mls.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PQ MLS production gate is a closed compile-time constant', () {
    expect(
      GroupProductionGate.releaseAssertion.productionTransportEnabled,
      isFalse,
    );
    final source = File(
      'lib/app/config/group_production_gate.dart',
    ).readAsStringSync();
    expect(source, contains('productionTransportEnabled: false'));
    expect(source, contains('assert('));
    expect(source, isNot(contains('bool.fromEnvironment')));
    expect(source, isNot(contains('String.fromEnvironment')));
    expect(
      File('lib/main_production.dart').readAsStringSync(),
      contains('GroupProductionGate.releaseAssertion'),
    );
  });

  test('only the beta artifact holds a beta MLS permit, and only where '
      'the core has been measured', () {
    // Production must never hold one on any ABI: it resolves the unsupported
    // adapter and its packaged native core does not even export the beta MLS
    // symbol. Development never holds one either - it composes the in-memory
    // preview through its own permit.
    for (final abi in const [
      GroupMlsFieldCell.arm64V8a,
      GroupMlsFieldCell.armeabiV7a,
      GroupMlsFieldCell.x8664,
    ]) {
      expect(
        GroupProductionGate.privateExperimentalPermit(
          AppEnvironment.production,
          abi,
        ),
        isNull,
      );
      expect(
        GroupProductionGate.privateExperimentalPermit(
          AppEnvironment.development,
          abi,
        ),
        isNull,
      );
    }
    // ADR-055 made the beta environment necessary and no longer sufficient;
    // ADR-056 made the remaining condition per-ABI. `arm64-v8a` was measured on
    // a Samsung SM-A566B on 2026-08-24 and holds a permit; the two ABIs with no
    // admissible record do not. `group_experimental_gate_test.dart` covers that
    // half in full.
    expect(
      GroupProductionGate.privateExperimentalPermit(
        AppEnvironment.beta,
        GroupMlsFieldCell.arm64V8a,
      ),
      isNotNull,
    );
    for (final abi in const [
      GroupMlsFieldCell.armeabiV7a,
      GroupMlsFieldCell.x8664,
    ]) {
      expect(
        GroupProductionGate.privateExperimentalPermit(AppEnvironment.beta, abi),
        isNull,
      );
    }

    final source = File(
      'lib/app/config/group_production_gate.dart',
    ).readAsStringSync();
    // The beta flavor is a release build, so the permit deliberately tests the
    // compiled environment and not kReleaseMode. Reintroducing a kReleaseMode
    // test here would close the private deployment's groups for the wrong
    // reason, which is the defect ADR-044 records; the evidence ledger closes
    // them for a stated one.
    expect(source, contains('environment == AppEnvironment.beta'));
    expect(source, contains('const GroupPrivateExperimentalPermit._()'));
    expect(
      source.split('privateExperimentalPermit').last,
      isNot(contains('kReleaseMode')),
    );
    expect(source, isNot(contains('bool.fromEnvironment')));
    expect(source, isNot(contains('String.fromEnvironment')));
  });

  test('group availability follows the permits, and two states close', () {
    GroupFeatureAvailability availabilityIn(
      AppEnvironment environment, {
      GroupMlsFieldCell abi = GroupMlsFieldCell.arm64V8a,
    }) {
      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(environment),
          runtimeAbiProvider.overrideWithValue(abi),
        ],
      );
      addTearDown(container.dispose);
      return container.read(groupFeatureAvailabilityProvider);
    }

    expect(
      availabilityIn(AppEnvironment.development),
      GroupFeatureAvailability.developmentPreview,
    );
    // ADR-056. The beta artifact gets the surface on the ABI that was measured
    // and is withheld it on the ABIs that were not - a different statement from
    // production's, and a different string.
    expect(
      availabilityIn(AppEnvironment.beta),
      GroupFeatureAvailability.privateExperimental,
    );
    expect(
      availabilityIn(AppEnvironment.beta, abi: GroupMlsFieldCell.armeabiV7a),
      GroupFeatureAvailability.privateExperimentalWithheld,
    );
    expect(
      availabilityIn(AppEnvironment.production),
      GroupFeatureAvailability.productionUnavailable,
    );

    expect(GroupFeatureAvailability.developmentPreview.isAvailable, isTrue);
    expect(GroupFeatureAvailability.privateExperimental.isAvailable, isTrue);
    expect(
      GroupFeatureAvailability.privateExperimentalWithheld.isAvailable,
      isFalse,
    );
    expect(GroupFeatureAvailability.productionUnavailable.isAvailable, isFalse);
  });

  test('one permit decides both the beta stack and its screens', () {
    // Before ADR-044 the screens gated on the development permit while the
    // crypto, KeyPackage maintenance and inbound coordinator gated on the raw
    // environment. The beta artifact therefore uploaded KeyPackages for groups
    // its own UI would never show. Both halves now read the same permit, and
    // the screens ask `isAvailable` rather than naming one availability value,
    // so adding a maturity tier cannot silently re-close them.
    final groupProviders = File(
      'lib/app/dependencies/group_providers.dart',
    ).readAsStringSync();
    final syncProviders = File(
      'lib/app/dependencies/sync_providers.dart',
    ).readAsStringSync();
    // The screens are nine files rather than one, and the two assertions below
    // have opposite polarity, so a single read of a single file would either
    // weaken the negative one to a ninth of its coverage or make the positive
    // one depend on which file was picked. The positive check runs over the
    // five gated pages, each of which must ask `isAvailable` for itself; the
    // negative one runs over all nine, because no group screen may name a
    // tier.
    const gated = [
      'lib/features/groups/presentation/add_group_members_page.dart',
      'lib/features/groups/presentation/create_group_page.dart',
      'lib/features/groups/presentation/edit_group_page.dart',
      'lib/features/groups/presentation/group_chat_page.dart',
      'lib/features/groups/presentation/group_info_page.dart',
    ];
    const ungated = [
      'lib/features/groups/presentation/group_callbacks.dart',
      'lib/features/groups/presentation/group_components.dart',
      'lib/features/groups/presentation/group_member_picker.dart',
      'lib/features/groups/presentation/group_production_gate_page.dart',
    ];

    for (final source in [groupProviders, syncProviders]) {
      expect(source, contains('GroupProductionGate.privateExperimentalPermit'));
      expect(
        source,
        isNot(contains('AppEnvironment.beta')),
        reason:
            'The beta boundary belongs to the permit, not to a comparison '
            'repeated across composition roots.',
      );
    }

    for (final path in gated) {
      final screen = File(path).readAsStringSync();
      expect(
        screen.contains('groupFeatureAvailabilityProvider).isAvailable'),
        isTrue,
        reason: '$path is a route destination and must ask for the permit',
      );
    }
    for (final path in [...gated, ...ungated]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('GroupFeatureAvailability.developmentPreview)')),
        reason:
            'A screen gating on one tier by name reopens the ADR-044 defect.',
      );
    }
  });

  test('production provider cannot install the development MLS fake', () {
    final container = ProviderContainer(
      overrides: [
        appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(groupFeatureAvailabilityProvider),
      GroupFeatureAvailability.productionUnavailable,
    );
    expect(
      container.read(groupMlsCryptoProvider),
      isA<UnsupportedGroupMlsCrypto>(),
    );
  });

  test(
    'production composes the unsupported adapter into the consumed port',
    () {
      // `groupUseCasesProvider` and the durable sync engine read the fully
      // composed provider, not the bare one asserted above.
      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(fullyComposedGroupMlsCryptoProvider.future),
        completion(isA<UnsupportedGroupMlsCrypto>()),
      );
    },
  );

  test('the unsupported adapter fails closed on every port method', () async {
    const crypto = UnsupportedGroupMlsCrypto();
    const ownerId = '11111111-1111-4111-8111-111111111111';
    const ownerDeviceId = '22222222-2222-4222-8222-222222222222';
    final empty = Uint8List(0);
    final owner = GroupMember(
      userId: ownerId,
      displayName: 'owner',
      role: GroupRole.owner,
      deviceIds: const [ownerDeviceId],
    );
    final state = GroupState(
      groupId: '00' * 32,
      metadata: const GroupMetadata(name: 'closed'),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
      members: [owner],
      controlRevision: 1,
      controlStateHash: '11' * 32,
      acceptedEpoch: 1,
    );

    final results = <Result<Object?>>[
      await crypto.probeIncomingTransport(empty),
      await crypto.prepareCreate(
        GroupCreationIntent(
          creatorUserId: ownerId,
          creatorDeviceId: ownerDeviceId,
          metadata: const GroupMetadata(name: 'closed'),
          members: [owner],
          createdMs: 0,
        ),
      ),
      await crypto.inspectIncomingWelcome(
        mlsObject: empty,
        localUserId: ownerId,
        localDeviceId: ownerDeviceId,
      ),
      await crypto.prepareControl(
        current: state,
        currentOpaqueMlsState: empty,
        operation: const LeaveGroupOperation(),
        actorUserId: ownerId,
        actorDeviceId: ownerDeviceId,
        createdMs: 0,
      ),
      await crypto.inspectIncomingControl(
        current: state,
        currentOpaqueMlsState: empty,
        mlsObject: empty,
        localUserId: ownerId,
        localDeviceId: ownerDeviceId,
      ),
      await crypto.prepareApplicationMessage(
        current: state,
        currentOpaqueMlsState: empty,
        senderUserId: ownerId,
        senderDeviceId: ownerDeviceId,
        text: 'closed',
        createdMs: 0,
      ),
      await crypto.inspectIncomingApplication(
        current: state,
        currentOpaqueMlsState: empty,
        mlsObject: empty,
        localUserId: ownerId,
        localDeviceId: ownerDeviceId,
      ),
      await crypto.generateKeyPackages(
        MlsKeyPackageGenerationRequest(
          opaqueDeviceState: Uint8List(64),
          migrationUnixDay: 0,
          localVerifiedBundleRequest: Uint8List(64),
          count: 1,
          kind: MlsKeyPackageKind.lastResort,
        ),
      ),
      await crypto.reconcileFork(
        current: state,
        currentOpaqueMlsState: empty,
        siblingCommits: const [],
        localUserId: ownerId,
        localDeviceId: ownerDeviceId,
      ),
    ];

    expect(results, hasLength(9));
    for (final result in results) {
      expect(
        result,
        isA<FailureResult<Object?>>().having(
          (value) => value.failure,
          'failure',
          const UnsupportedProtocolFailure(
            UnsupportedProtocolFailureKind.capability,
          ),
        ),
      );
    }
  });
}
