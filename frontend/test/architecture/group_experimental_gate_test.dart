import 'dart:convert';
import 'dart:io';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/group_production_gate.dart';
import 'package:communication_platform/app/config/runtime_abi_native.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/features/groups/infrastructure/unsupported_group_mls.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-055 withheld the closed-beta group surface until the packaged native
/// core had been observed running on hardware. ADR-056 measured `arm64-v8a` on
/// a Samsung SM-A566B and opened that ABI — and only that ABI.
///
/// These assertions cover the three things that have to stay true together: the
/// ledger says exactly what was run and nothing more; an ABI without an
/// admissible record is withheld in substance on the devices that load it; and
/// production is unaffected under every ledger state.
void main() {
  ProviderContainer containerFor(
    AppEnvironment environment, {
    GroupMlsFieldCell? abi,
  }) {
    final container = ProviderContainer(
      overrides: [
        appEnvironmentProvider.overrideWithValue(environment),
        if (abi != null) runtimeAbiProvider.overrideWithValue(abi),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the ledger records exactly what was run', () {
    test('arm64-v8a has one admissible record and nothing else does', () {
      expect(GroupExperimentalGate.ledger.evidence, hasLength(1));
      expect(
        GroupExperimentalGate.ledger.evidenceFor(GroupMlsFieldCell.arm64V8a),
        isNotNull,
      );
      expect(
        GroupExperimentalGate.ledger.evidenceFor(GroupMlsFieldCell.armeabiV7a),
        isNull,
      );
      expect(
        GroupExperimentalGate.ledger.evidenceFor(GroupMlsFieldCell.x8664),
        isNull,
      );
      expect(GroupExperimentalGate.ledger.outstanding, <GroupMlsFieldCell>[
        GroupMlsFieldCell.armeabiV7a,
        GroupMlsFieldCell.x8664,
      ]);
    });

    test('the record is admissible on its own rules', () {
      final record = GroupExperimentalGate.ledger.evidenceFor(
        GroupMlsFieldCell.arm64V8a,
      )!;
      expect(record.isAdmissible, isTrue);
      expect(record.emulated, isFalse);
      expect(record.observedOn, '2026-08-24');
      expect(record.operations, GroupMlsExercisedOperation.values);
    });

    test('the record points at a run that is actually committed', () {
      // A ledger entry naming a file nobody can read is an assertion, not
      // evidence. The record has to be here, and it has to say the run passed
      // on hardware rather than on something that merely reported a device.
      final record = GroupExperimentalGate.ledger.evidenceFor(
        GroupMlsFieldCell.arm64V8a,
      )!;
      final file = File(record.runRecord);
      expect(file.existsSync(), isTrue, reason: 'missing ${record.runRecord}');

      final run = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(run['schema'], 'beta-mls-core-run/1');
      expect(run['abi'], GroupMlsFieldCell.arm64V8a.abi);
      expect(run['emulated'], isFalse);
      expect(run['exit_code'], 0);
      expect(run['tests_failed'], 0);
      expect(run['tests_passed'], greaterThan(0));
      expect(
        run['model'],
        contains('A566B'),
        reason: 'the ledger and the run record must describe one device',
      );
      expect(run['recorded_at_utc'], startsWith(record.observedOn));

      // The suite it ran is the one that exercises the operation, not a subset
      // that happened to link. These two names are the round trip itself.
      final output = File(
        '${file.parent.path}/test-output.txt',
      ).readAsStringSync();
      expect(
        output,
        contains(
          'operation_round_trips_create_join_private_message_proposal_'
          'commit_and_remove',
        ),
      );
      expect(
        output,
        contains(
          'authenticated_suite_runs_key_package_welcome_proposal_commit_'
          'private_message_and_exporter',
        ),
      );
      expect(output, contains('0 failed'));
    });

    test('no run record exists for an ABI the ledger calls unmeasured', () {
      // The inverse of the check above, and the one that catches a run being
      // produced and then not read: a committed record for an outstanding cell
      // means somebody measured it and forgot to open it.
      final directories = Directory(
        'docs/validation/beta-mls-core',
      ).listSync().whereType<Directory>();
      for (final directory in directories) {
        for (final cell in GroupExperimentalGate.ledger.outstanding) {
          expect(
            directory.path.endsWith(cell.abi),
            isFalse,
            reason:
                '${directory.path} measures ${cell.abi}, which the ledger '
                'still calls outstanding',
          );
        }
      }
    });
  });

  group('the gate cannot be opened at runtime', () {
    final source = File(
      'lib/app/config/group_production_gate.dart',
    ).readAsStringSync();

    test('there is no define, no remote value and no setter', () {
      expect(source, isNot(contains('bool.fromEnvironment')));
      expect(source, isNot(contains('String.fromEnvironment')));
      expect(source, isNot(contains('int.fromEnvironment')));
      expect(source, contains('static const ledger'));
      expect(source, contains('@visibleForTesting'));
      for (final consumer in const [
        'lib/app/dependencies/group_providers.dart',
        'lib/app/dependencies/sync_providers.dart',
        'lib/features/groups/presentation/add_group_members_page.dart',
        'lib/features/groups/presentation/create_group_page.dart',
        'lib/features/groups/presentation/edit_group_page.dart',
        'lib/features/groups/presentation/group_callbacks.dart',
        'lib/features/groups/presentation/group_chat_page.dart',
        'lib/features/groups/presentation/group_components.dart',
        'lib/features/groups/presentation/group_info_page.dart',
        'lib/features/groups/presentation/group_member_picker.dart',
        'lib/features/groups/presentation/group_production_gate_page.dart',
        'lib/features/contacts/presentation/contact_components.dart',
        'lib/features/contacts/presentation/contacts_new_page.dart',
        'lib/features/contacts/presentation/contact_profile_page.dart',
        'lib/features/contacts/presentation/edit_profile_page.dart',
        'lib/features/contacts/presentation/safety_number_page.dart',
      ]) {
        expect(
          File(consumer).readAsStringSync(),
          isNot(contains('forEvidence')),
          reason: '$consumer must not be able to supply its own ledger',
        );
      }
    });

    test('the ABI is read, never chosen', () {
      // `Abi.current()` is a property of the AOT snapshot the platform loaded.
      // It reaches the application through one provider so it can be pinned in
      // a test, and that provider must be the only place it is read.
      final core = File(
        'lib/app/dependencies/core_providers.dart',
      ).readAsStringSync();
      expect(core, contains('Provider<GroupMlsFieldCell?>'));
      expect(core, contains('currentGroupMlsAbiCell()'));
      for (final consumer in const [
        'lib/app/config/group_production_gate.dart',
        'lib/app/dependencies/group_providers.dart',
        'lib/app/dependencies/sync_providers.dart',
        'lib/features/groups/presentation/add_group_members_page.dart',
        'lib/features/groups/presentation/create_group_page.dart',
        'lib/features/groups/presentation/edit_group_page.dart',
        'lib/features/groups/presentation/group_callbacks.dart',
        'lib/features/groups/presentation/group_chat_page.dart',
        'lib/features/groups/presentation/group_components.dart',
        'lib/features/groups/presentation/group_info_page.dart',
        'lib/features/groups/presentation/group_member_picker.dart',
        'lib/features/groups/presentation/group_production_gate_page.dart',
        'lib/features/contacts/presentation/contact_components.dart',
        'lib/features/contacts/presentation/contacts_new_page.dart',
        'lib/features/contacts/presentation/contact_profile_page.dart',
        'lib/features/contacts/presentation/edit_profile_page.dart',
        'lib/features/contacts/presentation/safety_number_page.dart',
      ]) {
        final source = File(consumer).readAsStringSync();
        expect(
          source,
          isNot(contains('Abi.current()')),
          reason: '$consumer must read the ABI through runtimeAbiProvider',
        );
        expect(
          source,
          isNot(contains("import 'dart:ffi'")),
          reason: '$consumer must compile on every target this repo builds',
        );
      }
    });

    test('the permit still requires the beta environment as well', () {
      expect(source, contains('environment == AppEnvironment.beta'));
      expect(
        GroupExperimentalGate.forEvidence(
          _fullLedger,
        ).hasEvidenceFor(GroupMlsFieldCell.armeabiV7a),
        isTrue,
        reason: 'the mechanism must work, or the real ledger proves nothing',
      );
    });
  });

  group('admissibility refuses the ways a ledger becomes decoration', () {
    test('a complete record on hardware is admissible', () {
      expect(_evidence().isAdmissible, isTrue);
    });

    test('an emulator record never counts', () {
      expect(_evidence(emulated: true).isAdmissible, isFalse);
      expect(
        GroupExperimentalGate.forEvidence([
          _evidence(cell: GroupMlsFieldCell.armeabiV7a, emulated: true),
        ]).hasEvidenceFor(GroupMlsFieldCell.armeabiV7a),
        isFalse,
      );
    });

    test('a run that skipped any operation of the round trip never counts', () {
      for (final skipped in GroupMlsExercisedOperation.values) {
        final partial = GroupMlsExercisedOperation.values
            .where((operation) => operation != skipped)
            .toList(growable: false);
        expect(
          _evidence(operations: partial).isAdmissible,
          isFalse,
          reason: 'a record missing $skipped opened a cell',
        );
      }
    });

    test('a row with nothing behind it never counts', () {
      expect(_evidence(hardware: '  ').isAdmissible, isFalse);
      expect(_evidence(platformVersion: '').isAdmissible, isFalse);
      expect(_evidence(runRecord: '   ').isAdmissible, isFalse);
    });

    test('a date nobody could have observed on never counts', () {
      for (final date in const [
        '2026-13-45',
        '2026-02-30',
        '26-08-24',
        '2026-8-24',
        'yesterday',
        '',
      ]) {
        expect(
          _evidence(observedOn: date).isAdmissible,
          isFalse,
          reason: '$date was accepted as a date',
        );
      }
    });
  });

  group('evidence resolves per ABI, and fails closed off the map', () {
    test('a measured ABI is available, an unmeasured one is withheld', () {
      expect(
        containerFor(
          AppEnvironment.beta,
          abi: GroupMlsFieldCell.arm64V8a,
        ).read(groupFeatureAvailabilityProvider),
        GroupFeatureAvailability.privateExperimental,
      );
      for (final abi in const [
        GroupMlsFieldCell.armeabiV7a,
        GroupMlsFieldCell.x8664,
      ]) {
        expect(
          containerFor(
            AppEnvironment.beta,
            abi: abi,
          ).read(groupFeatureAvailabilityProvider),
          GroupFeatureAvailability.privateExperimentalWithheld,
          reason: '$abi has no admissible record and must be withheld',
        );
      }
    });

    test('a target this artifact packages no library for has no evidence', () {
      // The artifact packages three ABIs. Anything else - a desktop host
      // running this suite, an Android RISC-V device, an ABI added later
      // without a run - resolves to no cell at all, and must fail closed
      // rather than inherit another cell's record.
      expect(GroupExperimentalGate.ledger.hasEvidenceFor(null), isFalse);
      expect(
        GroupExperimentalGate.forEvidence(_fullLedger).hasEvidenceFor(null),
        isFalse,
        reason: 'not even a complete ledger may answer for an unknown target',
      );
      expect(
        containerFor(
          AppEnvironment.beta,
        ).read(groupFeatureAvailabilityProvider),
        GroupFeatureAvailability.privateExperimentalWithheld,
        reason: 'this suite runs on a host the artifact packages nothing for',
      );
    });

    test('the native resolver really runs, and answers null off the map', () {
      // Not a source assertion: `runtime_abi_native.dart` is the one resolver
      // there is, and this suite runs it on the Dart VM. Calling it here
      // exercises the `Abi.current()` read and the default arm for real - on a
      // host the artifact packages no library for, which must resolve to no
      // cell.
      expect(currentGroupMlsAbiCell(), isNull);
      expect(
        ProviderContainer().read(runtimeAbiProvider),
        isNull,
        reason: 'the provider must return what the resolver returns',
      );
    });

    test('the platform seam maps every packaged ABI and nothing else', () {
      // Android is the only target, so the seam is one file rather than a
      // conditional import selecting between several. What is asserted here is
      // its shape: every packaged cell appears in the resolver, and the default
      // arm is null, so an ABI this artifact carries no library for reports
      // nothing rather than borrowing another cell's answer.
      final native = File(
        'lib/app/config/runtime_abi_native.dart',
      ).readAsStringSync();
      for (final cell in GroupMlsFieldCell.values) {
        expect(
          native,
          contains('GroupMlsFieldCell.${cell.name}'),
          reason: '${cell.abi} is packaged but the resolver cannot report it',
        );
      }
      expect(native, contains('_ => null'));
    });
  });

  group('a withheld ABI is withheld in substance', () {
    ProviderContainer withheldBeta() =>
        containerFor(AppEnvironment.beta, abi: GroupMlsFieldCell.armeabiV7a);

    test('availability is withheld, and withheld is not available', () {
      expect(
        withheldBeta().read(groupFeatureAvailabilityProvider),
        GroupFeatureAvailability.privateExperimentalWithheld,
      );
      expect(
        GroupFeatureAvailability.privateExperimentalWithheld.isAvailable,
        isFalse,
      );
    });

    test('no MLS stack is composed', () {
      final container = withheldBeta();
      expect(
        container.read(groupMlsCryptoProvider),
        isA<UnsupportedGroupMlsCrypto>(),
      );
      expect(
        container.read(fullyComposedGroupMlsCryptoProvider.future),
        completion(isA<UnsupportedGroupMlsCrypto>()),
      );
    });

    test('no KeyPackage is generated or uploaded', () {
      // The half that separates withheld from hidden. A build that closes its
      // screens while still publishing KeyPackages advertises a capability it
      // will not honour, and its peers pay for that rather than it.
      expect(
        withheldBeta().read(
          groupKeyPackageMaintenanceServiceProvider((
            userId: '11111111-1111-4111-8111-111111111111',
            deviceId: '22222222-2222-4222-8222-222222222222',
          )).future,
        ),
        throwsStateError,
      );
    });

    test('no screen can be reached around the gate', () {
      // One gate, pinned to the screen it belongs to. This used to count five
      // occurrences of `gate` in one concatenated source string and reason
      // about their byte offsets relative to each other, which only held while
      // every group screen shared a file. Per file is the stronger form: the
      // total is still five, but a page that grows a second gate or loses its
      // own is now named, instead of disappearing into a sum that still
      // reaches five.
      const gate =
          'if (!ref.watch(groupFeatureAvailabilityProvider).isAvailable) {';
      const screens = <String, String?>{
        'create_group_page':
            'if (injectedContacts != null && onCreate != null) {',
        'group_chat_page':
            'if (injectedState != null && injectedMessages != null && '
            'onSend != null) {',
        'group_info_page': 'if (injectedState != null && onMutate != null) {',
        'edit_group_page': null,
        'add_group_members_page': null,
      };
      for (final screen in screens.entries) {
        final path = 'lib/features/groups/presentation/${screen.key}.dart';
        final source = File(path).readAsStringSync();
        expect(
          gate.allMatches(source),
          hasLength(1),
          reason: '$path must gate exactly once',
        );
        final injection = screen.value;
        if (injection == null) {
          // This screen takes no test injection, and the assertion is that it
          // cannot grow one that the gate above does not cover. An `injected`
          // constructor argument is the shape the other three take.
          expect(
            source,
            isNot(contains('injected')),
            reason: '$path grew an injection seam the gate does not precede',
          );
          continue;
        }
        final injectionAt = source.indexOf(injection);
        expect(injectionAt, greaterThan(-1), reason: 'missing: $injection');
        final gateBefore = source.lastIndexOf(gate, injectionAt);
        expect(gateBefore, greaterThan(-1));
        expect(
          source.substring(gateBefore, injectionAt),
          isNot(contains('Widget build(')),
          reason: 'the gate preceding $injection belongs to another widget',
        );
      }
    });
  });

  group('a measured ABI gets the stack it was measured for', () {
    test('the permit is granted and the maintenance path opens', () {
      expect(
        GroupProductionGate.privateExperimentalPermit(
          AppEnvironment.beta,
          GroupMlsFieldCell.arm64V8a,
        ),
        isNotNull,
      );
      expect(
        GroupProductionGate.privateExperimentalWithheld(
          AppEnvironment.beta,
          GroupMlsFieldCell.arm64V8a,
        ),
        isFalse,
      );
    });

    test('the KeyPackage path is no longer what refuses', () async {
      // On a withheld ABI this provider throws the gate's own `StateError`. On
      // a measured one it must get past the gate and fail further down, on a
      // platform binding this host test has no adapters for. Asserting the
      // *absence* of the gate's refusal is what proves the surface opened;
      // asserting a plain throw would pass either way.
      Object? thrown;
      try {
        await containerFor(
          AppEnvironment.beta,
          abi: GroupMlsFieldCell.arm64V8a,
        ).read(
          groupKeyPackageMaintenanceServiceProvider((
            userId: '11111111-1111-4111-8111-111111111111',
            deviceId: '22222222-2222-4222-8222-222222222222',
          )).future,
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNot(isA<StateError>()));
      expect(
        thrown.toString(),
        isNot(contains('private experimental permit')),
        reason: 'a measured ABI must not be refused by the gate',
      );

      Object? withheld;
      try {
        await containerFor(
          AppEnvironment.beta,
          abi: GroupMlsFieldCell.armeabiV7a,
        ).read(
          groupKeyPackageMaintenanceServiceProvider((
            userId: '11111111-1111-4111-8111-111111111111',
            deviceId: '22222222-2222-4222-8222-222222222222',
          )).future,
        );
      } catch (error) {
        withheld = error;
      }
      expect(withheld, isA<StateError>());
      expect(withheld.toString(), contains('private experimental permit'));
    });
  });

  group('production is unchanged by any of this', () {
    test('production is unavailable on every ABI, measured or not', () {
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
          GroupProductionGate.privateExperimentalWithheld(
            AppEnvironment.production,
            abi,
          ),
          isFalse,
          reason: 'production has no group stack to withhold',
        );
        expect(
          containerFor(
            AppEnvironment.production,
            abi: abi,
          ).read(groupFeatureAvailabilityProvider),
          GroupFeatureAvailability.productionUnavailable,
        );
        expect(
          containerFor(
            AppEnvironment.production,
            abi: abi,
          ).read(groupMlsCryptoProvider),
          isA<UnsupportedGroupMlsCrypto>(),
        );
      }
    });

    test('the production transport assertion is untouched', () {
      expect(
        GroupProductionGate.releaseAssertion.productionTransportEnabled,
        isFalse,
      );
      expect(
        File('lib/main_production.dart').readAsStringSync(),
        contains('GroupProductionGate.releaseAssertion'),
      );
    });

    test('a fully satisfied ledger would still leave production closed', () {
      final full = GroupExperimentalGate.forEvidence(_fullLedger);
      for (final abi in const [
        GroupMlsFieldCell.arm64V8a,
        GroupMlsFieldCell.armeabiV7a,
        GroupMlsFieldCell.x8664,
      ]) {
        expect(full.hasEvidenceFor(abi), isTrue);
        expect(
          GroupProductionGate.privateExperimentalPermit(
            AppEnvironment.production,
            abi,
          ),
          isNull,
        );
      }
    });
  });
}

GroupMlsFieldEvidence _evidence({
  GroupMlsFieldCell cell = GroupMlsFieldCell.arm64V8a,
  String hardware = 'samsung SM-A566B',
  String platformVersion = 'Android 16 (API 36)',
  String observedOn = '2026-08-24',
  bool emulated = false,
  List<GroupMlsExercisedOperation>? operations,
  String runRecord = 'docs/validation/beta-mls-core/example/run.json',
}) => GroupMlsFieldEvidence(
  cell: cell,
  hardware: hardware,
  platformVersion: platformVersion,
  observedOn: observedOn,
  emulated: emulated,
  operations: operations ?? GroupMlsExercisedOperation.values,
  runRecord: runRecord,
);

final _fullLedger = <GroupMlsFieldEvidence>[
  for (final cell in GroupMlsFieldCell.values) _evidence(cell: cell),
];
