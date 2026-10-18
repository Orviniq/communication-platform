import 'dart:io';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/sustained_delivery_gate.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/synchronization/application/ports/sustained_delivery_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-053's gate: sustained delivery is not offered to anybody until it has
/// been measured on real phones, and the measurement is recorded here in a form
/// that cannot be satisfied by assumption.
///
/// This file exists because the failure mode of a validation gate is not that
/// somebody argues their way past it — it is that somebody edits one boolean
/// during unrelated work and nothing notices. Everything below is written to
/// fail loudly at that moment.
void main() {
  group('the ledger is empty, and empty is its default', () {
    test('no field evidence has been recorded for any cell', () {
      expect(
        SustainedDeliveryGate.releaseAssertion.evidence,
        isEmpty,
        reason:
            'nothing about this capability has been observed on any hardware; '
            'see docs/sustained-delivery-validation.md',
      );
      expect(SustainedDeliveryGate.releaseAssertion.isOpen, isFalse);
      expect(
        SustainedDeliveryGate.releaseAssertion.outstanding,
        SustainedDeliveryFleetCell.values
            .where((cell) => cell.mandatory)
            .toList(),
        reason: 'every mandatory cell is outstanding, because none was run',
      );
    });

    test('every cell of this matrix is mandatory', () {
      // A partially satisfied matrix opens nothing, and an optional cell would
      // be a matrix with a hole in it that still reported closed for the wrong
      // reason. If a later decision makes a cell optional, that is an ADR, and
      // this assertion is where it has to be argued.
      expect(
        SustainedDeliveryFleetCell.values.where((cell) => !cell.mandatory),
        isEmpty,
      );
      expect(SustainedDeliveryFleetCell.values, hasLength(7));
    });

    test('what reaches a user is best effort; only development measures', () {
      expect(
        SustainedDeliveryGate.availabilityIn(AppEnvironment.production),
        SustainedDeliveryAvailability.bestEffort,
        reason:
            'production is the build handed to the people in ADR-076, and '
            'ADR-094 offers it the tier on no field evidence',
      );
      expect(
        SustainedDeliveryGate.availabilityIn(AppEnvironment.development),
        SustainedDeliveryAvailability.measurementOnly,
        reason:
            'the matrix has to be runnable, including in a release AOT build, '
            'or the ledger could never be completed by anything',
      );
      // There is no value that refuses the tier any more: ADR-094 superseded
      // ADR-053 for production, and nothing else was withholding it.
      expect(SustainedDeliveryAvailability.values, const [
        SustainedDeliveryAvailability.evidenced,
        SustainedDeliveryAvailability.bestEffort,
        SustainedDeliveryAvailability.measurementOnly,
      ]);
    });

    test('there is no way to open it but source, and no way to widen it', () {
      final source = File(
        'lib/app/config/sustained_delivery_gate.dart',
      ).readAsStringSync();
      for (final escape in const [
        'bool.fromEnvironment',
        'String.fromEnvironment',
        'int.fromEnvironment',
        'kDebugMode',
        'kProfileMode',
        'Platform.environment',
      ]) {
        expect(
          source,
          isNot(contains(escape)),
          reason:
              'a gate a build flag can open is a gate that opens on the '
              'machine of whoever is in a hurry',
        );
      }
      // And the ledger is a compile-time constant with a final field, so the
      // only way to add a row is to edit this file and rebuild.
      expect(source, contains('static const releaseAssertion'));
      expect(
        source,
        contains('final List<SustainedDeliveryFieldEvidence> evidence;'),
      );
    });
  });

  group('what would open it, and what could never', () {
    SustainedDeliveryFieldEvidence record(
      SustainedDeliveryFleetCell cell, {
      bool emulated = false,
      int holdingHours = 24,
      int deliveriesObserved = 20,
      int repetitions = 3,
      String observedOn = '2026-09-01',
      String hardware = 'Samsung SM-A155F',
      String runRecord = 'docs/validation/sustained-delivery/example.json',
    }) => SustainedDeliveryFieldEvidence(
      cell: cell,
      hardware: hardware,
      platformVersion: 'Android 13 (API 33)',
      vendorSkin: 'One UI 5.1',
      observedOn: observedOn,
      emulated: emulated,
      vendorStepPerformed: false,
      holdingHours: holdingHours,
      deliveriesObserved: deliveriesObserved,
      repetitions: repetitions,
      runRecord: runRecord,
    );

    test(
      'a full set of admissible records is what opens it, and only that',
      () {
        final full = SustainedDeliveryFleetCell.values.map(record).toList();
        expect(full.every((entry) => entry.isAdmissible), isTrue);

        // The mechanism is real rather than decorative: a complete, admissible
        // ledger does open the gate. That is what makes the empty one a
        // statement about the evidence and not about the code.
        expect(_gateWith(full).isOpen, isTrue);
        expect(_gateWith(full).outstanding, isEmpty);
        // And it is what moves the offer from best effort to evidenced, in
        // production and in development alike.
        for (final environment in AppEnvironment.values) {
          expect(
            _gateWith(full).availabilityFor(environment),
            SustainedDeliveryAvailability.evidenced,
          );
        }
        expect(
          _gateWith(full.sublist(1)).availabilityFor(AppEnvironment.production),
          SustainedDeliveryAvailability.bestEffort,
          reason: 'one cell short is still best effort',
        );

        // One cell short opens nothing at all.
        expect(_gateWith(full.sublist(1)).isOpen, isFalse);
        expect(_gateWith(full.sublist(1)).outstanding, [
          SustainedDeliveryFleetCell.values.first,
        ]);
      },
    );

    test('an emulator can never stand in for a phone', () {
      final emulated = SustainedDeliveryFleetCell.values
          .map((cell) => record(cell, emulated: true, hardware: 'sdk_gphone64'))
          .toList();
      expect(emulated.every((entry) => entry.isAdmissible), isFalse);
      expect(
        _gateWith(emulated).isOpen,
        isFalse,
        reason:
            'the question every cell asks is what a manufacturer build does, '
            'and an emulator has no manufacturer',
      );
      expect(_gateWith(emulated).outstanding, hasLength(7));
      expect(
        _gateWith(emulated).availabilityFor(AppEnvironment.production),
        SustainedDeliveryAvailability.bestEffort,
        reason: 'an emulator record counts for nothing, so nothing moves',
      );
    });

    test('a run too short, too few, or once is not evidence', () {
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          holdingHours: 23,
        ).isAdmissible,
        isFalse,
      );
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          deliveriesObserved: 19,
        ).isAdmissible,
        isFalse,
      );
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          repetitions: 2,
        ).isAdmissible,
        isFalse,
        reason: 'a single observation is not a property of a device',
      );
      final short = SustainedDeliveryFleetCell.values
          .map((cell) => record(cell, holdingHours: 23))
          .toList();
      expect(
        _gateWith(short).availabilityFor(AppEnvironment.production),
        SustainedDeliveryAvailability.bestEffort,
        reason: 'a run too short counts for nothing, so nothing moves',
      );
      // The thresholds are the ones written down before anything was measured.
      expect(SustainedDeliveryFieldEvidence.minimumHoldingHours, 24);
      expect(SustainedDeliveryFieldEvidence.minimumDeliveries, 20);
      expect(SustainedDeliveryFieldEvidence.minimumRepetitions, 3);
    });

    test('a row with nothing behind it is not evidence', () {
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          hardware: '  ',
        ).isAdmissible,
        isFalse,
      );
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          observedOn: 'soon',
        ).isAdmissible,
        isFalse,
      );
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          observedOn: '2026-13-45',
        ).isAdmissible,
        isFalse,
      );
      expect(
        record(
          SustainedDeliveryFleetCell.samsungAndroid13,
          runRecord: '',
        ).isAdmissible,
        isFalse,
        reason: 'a claim with no run record behind it is a claim, not a run',
      );
    });
  });

  group('what a production build does while the ledger is incomplete', () {
    ProviderContainer production(_RecordingPlatform platform) {
      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
          sustainedDeliveryPlatformProvider.overrideWithValue(platform),
          // The signed-out state, so that the controller reaches no use case.
          authenticationControllerProvider.overrideWithBuild(
            (ref, notifier) => const AuthenticationViewState.dormant(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('it offers the switch, and asks the platform nothing yet', () async {
      final platform = _RecordingPlatform();
      final container = production(platform);

      expect(
        container.read(sustainedDeliveryAvailabilityProvider),
        SustainedDeliveryAvailability.bestEffort,
      );
      final status = container.read(sustainedDeliveryControllerProvider);
      expect(status, SustainedDeliveryStatus.off);
      expect(status.offersSwitch, isTrue);

      await container
          .read(sustainedDeliveryControllerProvider.notifier)
          .settled;
      expect(platform.startCalls, 0, reason: 'nothing starts by itself');
      expect(platform.exemptionRequests, 0, reason: 'nobody was asked yet');
      expect(
        platform.stopCalls,
        0,
        reason: 'and a build that offers the tier does not stand it down',
      );
    });

    test('a build that offers it is not a build that holds a socket', () async {
      final platform = _RecordingPlatform();
      final container = production(platform);

      final controller = container.read(
        sustainedDeliveryControllerProvider.notifier,
      );
      await controller.settled;
      await controller.refresh();

      expect(
        container
            .read(sustainedConnectionPolicyProvider)
            .mayHoldWhileBackgrounded,
        isFalse,
        reason:
            'only a user who turned it on, and a service that is running, '
            'keep the connection open; offering the switch changes neither',
      );
    });

    test('only a running service holds a connection', () {
      expect(SustainedDeliveryStatus.unavailable.offersSwitch, isFalse);
      expect(SustainedDeliveryStatus.off.offersSwitch, isTrue);
      for (final status in SustainedDeliveryStatus.values) {
        expect(
          status.holdsConnection,
          status == SustainedDeliveryStatus.holding,
          reason: '$status',
        );
      }
    });

    test('the withheld state is gone from the code and both catalogues', () {
      // ADR-094 offers the tier in production, so nothing returns the state
      // that refused it and nothing may be left that displays it.
      for (final catalogue in const ['app_en.arb', 'app_fa.arb']) {
        final source = File('lib/l10n/$catalogue').readAsStringSync();
        for (final key in const [
          'settingsSustainedWithheld',
          'sustainedStatusWithheld',
          'sustainedRefusedWithheld',
        ]) {
          expect(
            source,
            isNot(contains('"$key"')),
            reason: '$key in $catalogue',
          );
        }
      }
      for (final path in const [
        'lib/app/dependencies/sustained_delivery.dart',
        'lib/features/synchronization/domain/sustained_delivery_model.dart',
        'lib/features/synchronization/presentation/sustained_delivery_page.dart',
      ]) {
        expect(
          File(
            path,
          ).readAsStringSync().contains(RegExp('(?<![sS])[wW]ithheld')),
          isFalse,
          reason: '$path still refers to a withheld tier',
        );
      }
    });

    test('no surface promises a delivery time nobody has measured', () {
      final english = File('lib/l10n/app_en.arb').readAsStringSync();
      // ADR-051 shipped "messages can reach you within seconds of being sent"
      // in a build where nothing had ever been timed. A latency is exactly the
      // kind of claim that may only ever come from a measurement.
      expect(
        english,
        isNot(contains('within seconds')),
        reason:
            'a user-facing latency claim may never be derived from '
            'documentation; it is a measurement or it is not said',
      );
    });
  });

  group('the gate is discoverable by somebody who does not know it exists', () {
    test('the validation document names every cell of the matrix', () {
      final doc = File('docs/sustained-delivery-validation.md');
      expect(doc.existsSync(), isTrue);
      final text = doc.readAsStringSync();
      for (final cell in SustainedDeliveryFleetCell.values) {
        expect(
          text,
          contains(cell.name),
          reason:
              'a cell the ledger knows about and the document does not is a '
              'cell nobody can run',
        );
      }
      for (final anchor in const [
        'Gate state',
        'CLOSED',
        'Success criteria',
        'before any measurement',
      ]) {
        expect(text, contains(anchor));
      }
    });

    test('the procedure is a script somebody can run, not a paragraph', () {
      expect(File('tool/measure_sustained_delivery.sh').existsSync(), isTrue);
    });

    test('the release checklist and the platform document point at it', () {
      expect(
        File('docs/deployment-and-release.md').readAsStringSync(),
        contains('sustained-delivery-validation.md'),
      );
      expect(
        File('docs/platform-android.md').readAsStringSync(),
        contains('sustained-delivery-validation.md'),
      );
      expect(
        File('docs/README.md').readAsStringSync(),
        contains('sustained-delivery-validation.md'),
      );
    });
  });
}

SustainedDeliveryGate _gateWith(
  List<SustainedDeliveryFieldEvidence> evidence,
) => SustainedDeliveryGate.forEvidence(evidence);

/// A platform side that records what it was asked and answers truthfully.
final class _RecordingPlatform implements SustainedDeliveryPlatformPort {
  bool running = false;
  int startCalls = 0;
  int stopCalls = 0;
  int exemptionRequests = 0;

  SustainedDeliveryPlatformState get _state => SustainedDeliveryPlatformState(
    supported: true,
    running: running,
    exempt: true,
    alertsEnabled: true,
  );

  @override
  Future<SustainedDeliveryPlatformState?> platformState() async => _state;

  @override
  Future<SustainedDeliveryPlatformState?> requestExemption() async {
    exemptionRequests += 1;
    return _state;
  }

  @override
  Future<SustainedDeliveryPlatformState?> start() async {
    startCalls += 1;
    running = true;
    return _state;
  }

  @override
  Future<SustainedDeliveryPlatformState?> stop() async {
    stopCalls += 1;
    running = false;
    return _state;
  }

  @override
  Future<void> openVendorSettings() async {}
}
