import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/linked_device_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/devices/presentation/history_transfer_status.dart';
import 'package:communication_platform/features/devices/presentation/linked_devices_page.dart';
import 'package:communication_platform/features/synchronization/domain/history_transfer_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final devices = [
    LinkedDevice(
      deviceId: '10000000-0000-4000-8000-000000000001',
      label: 'Pixel',
      labelState: LinkedDeviceLabelState.available,
      createdDate: DateTime.utc(2026),
      thisDevice: true,
      encryptedLabel: Uint8List(256),
    ),
    LinkedDevice(
      deviceId: '10000000-0000-4000-8000-000000000002',
      label: 'Desktop',
      labelState: LinkedDeviceLabelState.available,
      createdDate: DateTime.utc(2026, 2),
      thisDevice: false,
      encryptedLabel: Uint8List(256),
    ),
  ];

  testWidgets(
    'lists encrypted labels and requires explicit rename and revoke actions',
    (tester) async {
      var refreshes = 0;
      (String, String)? relabeled;
      String? revoked;

      await _pump(
        tester,
        devices: devices,
        onRefresh: () async => refreshes += 1,
        onRelabel: (deviceId, label) async {
          relabeled = (deviceId, label);
        },
        onRevoke: (deviceId) async => revoked = deviceId,
      );

      expect(refreshes, 1);
      expect(
        find.text('Device names are encrypted on this phone'),
        findsOneWidget,
      );
      expect(find.text('Pixel'), findsOneWidget);
      expect(find.text('The device you are using now'), findsOneWidget);
      expect(find.text('Desktop'), findsOneWidget);
      // The row shows the day the device was added, which is the only date the
      // server still reports about one, and says so rather than passing it off
      // as a last-seen day.
      //
      // The backend reports a calendar day with no time zone, and the row shows
      // that day. Rendering it through `toLocal()` used to move it back one day
      // for every reader west of UTC, which made the value both wrong and
      // finer-grained than the one the server holds.
      expect(find.text('Added: 2026-02-01'), findsOneWidget);
      expect(find.textContaining('Last active'), findsNothing);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(refreshes, 2);

      final peerMenu = find.byKey(
        const ValueKey(
          'linked-device-menu-10000000-0000-4000-8000-000000000002',
        ),
      );
      await tester.tap(peerMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.text('Rename device'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Workstation');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(relabeled, (
        '10000000-0000-4000-8000-000000000002',
        'Workstation',
      ));

      await tester.tap(peerMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(find.text('Remove this device?'), findsOneWidget);
      expect(
        find.textContaining('cannot be undone'),
        findsOneWidget,
        reason: 'a destructive confirmation states the consequence plainly',
      );
      await tester.tap(
        find.byKey(const ValueKey('linked-device-remove-confirm')),
      );
      await tester.pumpAndSettle();
      expect(revoked, '10000000-0000-4000-8000-000000000002');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing the device in your hand says what it costs', (
    tester,
  ) async {
    await _pump(tester, devices: devices, onRevoke: (_) async {});

    await tester.tap(
      find.byKey(
        const ValueKey(
          'linked-device-menu-10000000-0000-4000-8000-000000000001',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();

    expect(find.text('Remove the device you are using?'), findsOneWidget);
    expect(find.textContaining('everything on it is erased'), findsOneWidget);
  });

  testWidgets('the screen is translated, not left in English', (tester) async {
    await _pump(tester, devices: devices, locale: const Locale('fa'));

    expect(find.text('دستگاه‌های متصل'), findsOneWidget);
    expect(find.textContaining('Last active'), findsNothing);
    expect(find.textContaining('Device names are encrypted'), findsNothing);
  });

  testWidgets('an unreadable device list states a state, never an exception', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linkedDevicesProvider.overrideWith(
            (ref) =>
                Stream<List<LinkedDevice>>.error(StateError('unreachable')),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          // Above the navigator, so a dialog pushed on the root navigator
          // is inside the design system's scope, exactly as it is in the
          // running application.
          builder: (context, child) =>
              AppDesignSystem(child: child ?? const SizedBox.shrink()),
          home: LinkedDevicesPage(onRefresh: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Device list unavailable'), findsOneWidget);
    // The classification never reaches the user: no exception text, no code.
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('unreachable'), findsNothing);
  });

  testWidgets('adding a device is explained, never offered as a dead button', (
    tester,
  ) async {
    await _pump(tester, devices: devices);

    expect(find.text('Add another device'), findsOneWidget);
    expect(
      find.textContaining('the server has no copy to send'),
      findsOneWidget,
    );
    // §16.1's flow starts on the other device, so there is nothing here to
    // press. A button would have been a control that cannot succeed.
    expect(find.widgetWithText(ElevatedButton, 'Add device'), findsNothing);
  });

  testWidgets('history recovery states never imply server-side restoration', (
    tester,
  ) async {
    const expected = <HistoryTransferState, String>{
      HistoryTransferState.identityRecovered:
          'Message history has not been restored.',
      HistoryTransferState.waitingForSource: 'Keep an authorized device online',
      HistoryTransferState.transferring: 'directly between your devices',
      HistoryTransferState.partialTransfer: 'only held part of your history',
      HistoryTransferState.noSource: 'The server has no history copy',
      HistoryTransferState.groupReinviteRequired: 'fresh group epoch',
      HistoryTransferState.queueGapRecovery: 'recover before setup is complete',
      HistoryTransferState.done: 'Available local history has been stored',
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AppDesignSystem(
            child: Scaffold(body: HistoryTransferStatusView(state: entry.key)),
          ),
        ),
      );
      expect(find.textContaining(entry.value), findsOneWidget);
    }
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required List<LinkedDevice> devices,
  Future<void> Function()? onRefresh,
  Future<void> Function(String deviceId, String label)? onRelabel,
  Future<void> Function(String deviceId)? onRevoke,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        linkedDevicesProvider.overrideWith((ref) => Stream.value(devices)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: LinkedDevicesPage(
          onRefresh: onRefresh ?? () async {},
          onRelabel: onRelabel,
          onRevoke: onRevoke,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
