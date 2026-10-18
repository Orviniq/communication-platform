import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';
import 'package:communication_platform/features/devices/infrastructure/prekey_maintenance_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scope = (
    userId: '00000000-0000-0000-0000-000000000001',
    deviceId: '00000000-0000-0000-0000-000000000002',
  );

  test('a service that could not be composed is composed afresh on the '
      'next due run (ADR-095)', () async {
    final clock = _Clock(DateTime.utc(2026, 10, 18, 9));
    var compositions = 0;
    final container = ProviderContainer(
      overrides: [
        timeSourceProvider.overrideWithValue(clock),
        prekeyMaintenanceServiceProvider.overrideWith((ref, scope) {
          compositions += 1;
          throw StateError('protected storage is locked');
        }),
      ],
    );
    addTearDown(container.dispose);
    final schedule = container.read(scheduledPrekeyMaintenanceProvider(scope));

    final first = await schedule.runIfDue();
    expect(first, isA<FailureResult<PrekeyMaintenanceReport>>());
    expect(compositions, 1);

    clock.value = clock.value.add(const Duration(minutes: 5));
    await schedule.runIfDue();
    expect(
      compositions,
      2,
      reason: 'a cached error would hold maintenance off for the process',
    );
  });

  test('the engine of a scope keeps one schedule for it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      identical(
        container.read(scheduledPrekeyMaintenanceProvider(scope)),
        container.read(scheduledPrekeyMaintenanceProvider(scope)),
      ),
      isTrue,
    );
  });
}

final class _Clock implements TimeSource {
  _Clock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}
