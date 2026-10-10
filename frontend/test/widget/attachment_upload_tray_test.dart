import 'dart:io';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_upload_tray.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-089 D5: the tray above the composer, one row for each upload job.
void main() {
  final resetsAt = DateTime.utc(2026, 10, 11);

  AttachmentUploadRowViewModel row(
    String id,
    AttachmentUploadState state, {
    int percent = 0,
    AttachmentUploadFailureKind? failure,
    bool picture = false,
    String name = 'minutes.pdf',
  }) => AttachmentUploadRowViewModel(
    id: id,
    name: name,
    picture: picture,
    state: state,
    percent: percent,
    failure: failure,
    resetsAt: failure == AttachmentUploadFailureKind.allowanceSpent
        ? resetsAt
        : null,
  );

  Future<List<AttachmentUploadIntent>> launch(
    WidgetTester tester,
    List<AttachmentUploadRowViewModel> rows, {
    Locale locale = const Locale('en'),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final intents = <AttachmentUploadIntent>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppDesignSystem(
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              AttachmentUploadTray(rows: rows, onIntent: intents.add),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return intents;
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is AppIconButton && widget.semanticLabel == label,
  );

  Finder inRow(String id, Finder finder) => find.descendant(
    of: find.byKey(ValueKey('attachment-upload-$id')),
    matching: finder,
  );

  testWidgets('a row shows each state, with the percent while it moves', (
    tester,
  ) async {
    await launch(tester, [
      row('a', AttachmentUploadState.waiting),
      row('b', AttachmentUploadState.encrypting, percent: 42),
      row('c', AttachmentUploadState.uploading, percent: 7, picture: true),
      row('d', AttachmentUploadState.sending, percent: 100),
    ]);

    expect(inRow('a', find.text('Waiting')), findsOneWidget);
    expect(inRow('b', find.text('Encrypting, 42%')), findsOneWidget);
    expect(inRow('c', find.text('Uploading, 7%')), findsOneWidget);
    expect(inRow('d', find.text('Sending')), findsOneWidget);
    for (final (id, value) in [
      ('a', 0.0),
      ('b', 0.42),
      ('c', 0.07),
      ('d', 1.0),
    ]) {
      expect(
        tester
            .widget<LinearProgressIndicator>(
              inRow(id, find.byType(LinearProgressIndicator)),
            )
            .value,
        value,
        reason: id,
      );
    }
    // Cancel acts until the message is being committed.
    for (final id in ['a', 'b', 'c']) {
      expect(
        tester
            .widget<AppIconButton>(inRow(id, button('Cancel upload')))
            .onPressed,
        isNotNull,
        reason: id,
      );
    }
    expect(
      tester
          .widget<AppIconButton>(inRow('d', button('Cancel upload')))
          .onPressed,
      isNull,
    );
    expect(button('Retry upload'), findsNothing);
    expect(button('Discard upload'), findsNothing);
  });

  testWidgets('a failed row names its reason, with Retry and Discard', (
    tester,
  ) async {
    await launch(tester, const []);
    final time = formatAttachmentTime(
      tester.element(find.byType(AttachmentUploadTray)),
      resetsAt,
    );

    final reasons = {
      AttachmentUploadFailureKind.allowanceSpent:
          "Today's upload allowance is spent. It resets at $time.",
      AttachmentUploadFailureKind.tooLarge:
          'The file is too large for the server.',
      AttachmentUploadFailureKind.storageFull:
          "The server's storage is full. Try again later.",
      AttachmentUploadFailureKind.throttled:
          'Too many transfers. Try again in a minute.',
      AttachmentUploadFailureKind.offline:
          'No connection. Try again when you are online.',
      AttachmentUploadFailureKind.failed: 'The upload failed.',
    };
    // One at a time: six rows are more than the tray's height shows.
    for (final MapEntry(key: kind, value: reason) in reasons.entries) {
      await launch(tester, [
        row(kind.name, AttachmentUploadState.failed, failure: kind),
      ]);
      expect(inRow(kind.name, find.text(reason)), findsOneWidget);
      expect(inRow(kind.name, button('Discard upload')), findsOneWidget);
      expect(
        inRow(kind.name, button('Retry upload')),
        kind == AttachmentUploadFailureKind.tooLarge
            ? findsNothing
            : findsOneWidget,
        reason: kind.name,
      );
      expect(inRow(kind.name, button('Cancel upload')), findsNothing);
      expect(
        inRow(kind.name, find.byType(LinearProgressIndicator)),
        findsNothing,
      );
    }
  });

  testWidgets('each control sends its intent for its own job', (tester) async {
    final intents = await launch(tester, [
      row('a', AttachmentUploadState.uploading, percent: 50),
      row(
        'b',
        AttachmentUploadState.failed,
        failure: AttachmentUploadFailureKind.offline,
      ),
    ]);

    await tester.tap(inRow('a', button('Cancel upload')));
    await tester.tap(inRow('b', button('Retry upload')));
    await tester.tap(inRow('b', button('Discard upload')));
    await tester.pumpAndSettle();

    expect(intents, [
      isA<CancelAttachmentUploadIntent>().having((i) => i.id, 'id', 'a'),
      isA<RetryAttachmentUploadIntent>().having((i) => i.id, 'id', 'b'),
      isA<DiscardAttachmentUploadIntent>().having((i) => i.id, 'id', 'b'),
    ]);
  });

  testWidgets('a screen reader hears each state once, not each percent', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final state = find.byKey(const ValueKey('attachment-upload-state-a'));

    await launch(tester, [
      row('a', AttachmentUploadState.uploading, percent: 10),
    ]);
    expect(
      tester.getSemantics(state),
      isSemantics(isLiveRegion: true, label: 'minutes.pdf: Uploading'),
    );

    // The percent moves: the live region says the same thing.
    await launch(tester, [
      row('a', AttachmentUploadState.uploading, percent: 60),
    ]);
    expect(
      tester.getSemantics(state),
      isSemantics(isLiveRegion: true, label: 'minutes.pdf: Uploading'),
    );
    expect(
      tester.getSemantics(find.byType(LinearProgressIndicator)),
      isSemantics(label: 'minutes.pdf', value: '60%'),
    );

    // The state changes: it says the new one.
    await launch(tester, [
      row(
        'a',
        AttachmentUploadState.failed,
        failure: AttachmentUploadFailureKind.storageFull,
      ),
    ]);
    expect(
      tester.getSemantics(state),
      isSemantics(
        isLiveRegion: true,
        label: "minutes.pdf: The server's storage is full. Try again later.",
      ),
    );
    semantics.dispose();
  });

  testWidgets('no job draws nothing', (tester) async {
    await launch(tester, const []);

    expect(find.byKey(const ValueKey('attachment-upload-tray')), findsNothing);
  });

  test('a job maps to its row', () {
    final picked = PickedAttachment(
      file: File('unused'),
      displayName: '${'م' * 90}.jpg',
      mimeType: 'image/jpeg',
      length: 10,
      mediaKind: AttachmentMediaKind.image,
    );
    AttachmentUploadJob job(
      AttachmentUploadState state, {
      double progress = 0,
    }) => AttachmentUploadJob(
      id: 'j',
      conversationId: 'c',
      target: const AttachmentUploadTarget.saved(),
      attachment: picked,
      caption: null,
      state: state,
      progress: progress,
    );

    final rows = attachmentUploadRows([
      job(AttachmentUploadState.uploading, progress: 0.426),
      job(AttachmentUploadState.sending, progress: 1),
      job(AttachmentUploadState.waiting),
    ]);

    expect([for (final row in rows) row.percent], [42, 100, 0]);
    expect(rows.first.picture, isTrue);
    expect(rows.first.name, attachmentDescriptorName(picked.displayName));
    expect(rows.first.toString(), isNot(contains('م')));
  });

  for (final locale in const [Locale('en'), Locale('fa')]) {
    testWidgets('fits 360 by 800 at 200 % text in ${locale.languageCode}, '
        'with every control at least the minimum target', (tester) async {
      await launch(
        tester,
        [
          row(
            'a',
            AttachmentUploadState.uploading,
            percent: 33,
            name: '${'م' * 60} long name.pdf',
          ),
          for (final kind in [
            AttachmentUploadFailureKind.allowanceSpent,
            AttachmentUploadFailureKind.throttled,
          ])
            row(kind.name, AttachmentUploadState.failed, failure: kind),
        ],
        locale: locale,
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      for (final control in tester.widgetList<AppIconButton>(
        find.byType(AppIconButton),
      )) {
        final size = tester.getSize(find.byWidget(control));
        expect(size.width, greaterThanOrEqualTo(AppFocus.minimumTarget));
        expect(size.height, greaterThanOrEqualTo(AppFocus.minimumTarget));
      }
    });
  }
}
