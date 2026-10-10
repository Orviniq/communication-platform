import 'dart:async';
import 'dart:io';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_uploads.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_upload_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_preview_sheet.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_send_flow.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/attachment_platform_fake.dart';
import '../support/system_insets.dart';

/// ADR-089 D5 and D6: the choice, the pick, and the preview step.
void main() {
  const narrow = Size(360, 800);
  const dailyBytes = 268435456;
  late FakeAttachmentPlatform platform;
  late _Files files;
  late _Allowance allowance;
  late AttachmentUploads uploads;

  setUp(() {
    platform = FakeAttachmentPlatform();
    files = _Files();
    allowance = _Allowance();
    uploads = AttachmentUploads(
      platform: platform,
      holds: AttachmentOutgoingHolds(),
      limits: () =>
          (buckets: AttachmentCryptoProtocolV1.buckets, dailyBytes: dailyBytes),
      clock: const _Clock(),
      files: () async => files,
      allowance: () async => allowance,
      states: () => throw StateError('not in this test'),
      // A job waits here, so the test sees it as it was enqueued.
      transfer: () => Completer<AttachmentTransferService>().future,
      messages: () => throw StateError('not in this test'),
    );
  });

  PickedAttachment picked({
    String name = 'minutes.pdf',
    String mimeType = 'application/pdf',
    int length = 200000,
    AttachmentMediaKind mediaKind = AttachmentMediaKind.file,
  }) => PickedAttachment(
    file: File(
      [
        Directory.systemTemp.path,
        'outgoing',
        'ab' * 16,
        name,
      ].join(Platform.pathSeparator),
    ),
    displayName: name,
    mimeType: mimeType,
    length: length,
    mediaKind: mediaKind,
    width: mediaKind == AttachmentMediaKind.image ? 2048 : null,
    height: mediaKind == AttachmentMediaKind.image ? 1536 : null,
  );

  Future<void> launch(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double textScale = 1,
    Size size = narrow,
    double pixelRatio = 1,
  }) async {
    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => unawaited(
                  runAttachmentSendFlow(
                    context: context,
                    session: () async => uploads,
                    conversationId: 'c-1',
                    target: const AttachmentUploadTarget.direct('peer'),
                  ),
                ),
                child: const Text('attach'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The paperclip, then a choice.
  Future<void> choose(WidgetTester tester, String choice) async {
    await tester.tap(find.text('attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(choice));
    await tester.pumpAndSettle();
  }

  final send = find.byKey(const ValueKey('attachment-preview-send'));
  final caption = find.byKey(const ValueKey('attachment-caption-field'));

  bool sendEnabled(WidgetTester tester) =>
      tester.widget<AppButton>(send).onPressed != null;

  group('a choice', () {
    testWidgets('asks the platform for its kind under the pick limit', (
      tester,
    ) async {
      await launch(tester);

      for (final (label, kind) in [
        ('Photo or image', AttachmentPickKind.photo),
        ('File', AttachmentPickKind.file),
        ('Camera', AttachmentPickKind.camera),
      ]) {
        await choose(tester, label);
        expect(platform.picks.last.kind, kind);
        expect(
          platform.picks.last.maxBytes,
          attachmentPlaintextLimit(67108864),
        );
      }
      // Each pick answered that the user closed the picker: nothing is said,
      // and no preview opens.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AttachmentPreviewSheet), findsNothing);
    });

    testWidgets('that fails says why, once for each failure of the port', (
      tester,
    ) async {
      await launch(tester);
      final cases = <(Failure, String)>[
        (
          const ValidationFailure(ValidationFailureKind.conflict),
          'A picker is already open. Finish with it first.',
        ),
        (
          const ValidationFailure(ValidationFailureKind.limitExceeded),
          'This file is too large to send. The largest file is 64 MB.',
        ),
        (
          const ValidationFailure(ValidationFailureKind.invalidInput),
          'This picture cannot be read on this phone. Send it as a file '
              'instead.',
        ),
        (
          const StorageFailure(StorageFailureKind.unavailable),
          'The file could not be read. Nothing was attached.',
        ),
        (
          const UnsupportedProtocolFailure(
            UnsupportedProtocolFailureKind.capability,
          ),
          'No camera app is available on this phone.',
        ),
        (
          const SecurityFailure(SecurityFailureKind.policyBlocked),
          'The phone refused the file. Nothing was attached.',
        ),
        (
          const SecurityFailure(SecurityFailureKind.malformedServerResponse),
          'The picker gave an answer this app does not accept. Nothing was '
              'attached.',
        ),
      ];
      for (final (failure, message) in cases) {
        platform.enqueuePick(Result.failure(failure));
        await choose(tester, 'Camera');

        expect(find.text(message), findsOneWidget, reason: '$failure');
        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .clearSnackBars();
        await tester.pumpAndSettle();
      }
      expect(find.byType(AttachmentPreviewSheet), findsNothing);
    });
  });

  group('the preview step', () {
    testWidgets('shows the sizes and the remainder, and sends the caption', (
      tester,
    ) async {
      allowance.spent = dailyBytes - 100 * 1024 * 1024;
      final copy = picked();
      platform.enqueuePick(Result.success(copy));
      await launch(tester);

      await choose(tester, 'File');

      expect(find.text('minutes.pdf'), findsOneWidget);
      expect(find.text('Size: 195 KB'), findsOneWidget);
      expect(find.text('Upload size: 256 KB'), findsOneWidget);
      expect(find.text('Left today: 100 MB'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attachment-preview-image')),
        findsNothing,
      );
      expect(sendEnabled(tester), isTrue);

      await tester.enterText(caption, '  for Monday ');
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(find.byType(AttachmentPreviewSheet), findsNothing);
      final job = uploads.jobs.single;
      expect(job.conversationId, 'c-1');
      expect(job.caption, 'for Monday');
      expect(job.attachment, same(copy));
      expect(files.discarded, isEmpty);
    });

    testWidgets('over the remainder says when the day turns, and Send is '
        'disabled', (tester) async {
      allowance.spent = dailyBytes - 100000;
      platform.enqueuePick(Result.success(picked()));
      await launch(tester);

      await choose(tester, 'File');

      final context = tester.element(find.byType(AttachmentPreviewSheet));
      final strings = AppLocalizations.of(context);
      final time = formatAttachmentTime(context, DateTime.utc(2026, 10, 11));
      expect(
        find.text(
          'This upload needs 256 KB, and today has '
          '${formatAttachmentSize(strings, 100000)} left. The allowance '
          'resets at $time.',
        ),
        findsOneWidget,
      );
      expect(sendEnabled(tester), isFalse);
    });

    testWidgets('a size the server does not take cannot be sent', (
      tester,
    ) async {
      uploads = AttachmentUploads(
        platform: platform,
        holds: AttachmentOutgoingHolds(),
        limits: () => (buckets: const {65536}, dailyBytes: dailyBytes),
        clock: const _Clock(),
        files: () async => files,
        allowance: () async => allowance,
        states: () => throw StateError('not in this test'),
        transfer: () => throw StateError('not in this test'),
        messages: () => throw StateError('not in this test'),
      );
      platform.enqueuePick(Result.success(picked()));
      await launch(tester);

      await choose(tester, 'File');

      expect(
        find.text('This server takes no upload of this size.'),
        findsOneWidget,
      );
      expect(sendEnabled(tester), isFalse);
    });

    testWidgets('Cancel deletes the copy and sends nothing', (tester) async {
      final copy = picked();
      platform.enqueuePick(Result.success(copy));
      await launch(tester);
      await choose(tester, 'File');

      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(files.discarded, [copy.file.path]);
      expect(uploads.jobs, isEmpty);
    });

    testWidgets('keeps a caption to 1,024 characters, with a counter near '
        'the limit', (tester) async {
      platform.enqueuePick(Result.success(picked()));
      await launch(tester);
      await choose(tester, 'File');

      await tester.enterText(caption, 'x' * 900);
      await tester.pump();
      expect(find.textContaining('characters'), findsNothing);

      await tester.enterText(caption, 'x' * 950);
      await tester.pump();
      expect(find.text('950/1024 characters'), findsOneWidget);

      await tester.enterText(caption, 'x' * 1100);
      await tester.pump();
      expect(tester.widget<TextField>(caption).controller!.text, 'x' * 1024);
      expect(find.text('1024/1024 characters'), findsOneWidget);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('refuses a caption that makes the details pass 4,096 bytes, '
        'and says why', (tester) async {
      platform.enqueuePick(Result.success(picked()));
      await launch(tester);
      await choose(tester, 'File');

      // Within the characters, past the bytes: four bytes each.
      await tester.enterText(caption, '\u{1F600}' * 1020);
      await tester.pump();

      expect(
        find.text(
          "With this caption the file's details pass 4096 bytes, the most "
          'an attachment carries. Shorten the caption.',
        ),
        findsOneWidget,
      );
      expect(find.text('4114/4096 bytes of details'), findsOneWidget);
      expect(sendEnabled(tester), isFalse);

      await tester.enterText(caption, '\u{1F600}' * 10);
      await tester.pump();
      expect(find.textContaining('bytes of details'), findsNothing);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('sets the caption direction from its first strong character', (
      tester,
    ) async {
      platform.enqueuePick(Result.success(picked()));
      await launch(tester);
      await choose(tester, 'File');

      await tester.enterText(caption, '۱۲ سلام hello');
      await tester.pump();
      expect(
        tester.widget<TextField>(caption).textDirection,
        TextDirection.rtl,
      );

      await tester.enterText(caption, 'hello سلام');
      await tester.pump();
      expect(
        tester.widget<TextField>(caption).textDirection,
        TextDirection.ltr,
      );
    });

    testWidgets('decodes a picture no wider than the sheet in device pixels', (
      tester,
    ) async {
      platform.enqueuePick(
        Result.success(
          picked(
            name: 'photo.jpg',
            mimeType: 'image/jpeg',
            mediaKind: AttachmentMediaKind.image,
          ),
        ),
      );
      await launch(tester, pixelRatio: 2);
      await choose(tester, 'Photo or image');

      final image = tester.widget<Image>(
        find.byKey(const ValueKey('attachment-preview-image')),
      );
      final width = tester
          .getSize(find.byKey(const ValueKey('attachment-preview-image')))
          .width;
      expect(
        image.image,
        isA<ResizeImage>().having(
          (resize) => resize.width,
          'width',
          (width * 2).floor(),
        ),
      );
    });

    testWidgets('never decodes a picture wider than 1024 pixels', (
      tester,
    ) async {
      platform.enqueuePick(
        Result.success(
          picked(
            name: 'photo.jpg',
            mimeType: 'image/jpeg',
            mediaKind: AttachmentMediaKind.image,
          ),
        ),
      );
      await launch(tester, size: const Size(800, 1000), pixelRatio: 3);
      await choose(tester, 'Photo or image');

      final image = tester.widget<Image>(
        find.byKey(const ValueKey('attachment-preview-image')),
      );
      expect((image.image as ResizeImage).width, 1024);
    });

    for (final locale in const [Locale('en'), Locale('fa')]) {
      testWidgets('fits 360 by 800 at 200 % text in ${locale.languageCode}', (
        tester,
      ) async {
        allowance.spent = dailyBytes - 100000;
        platform.enqueuePick(
          Result.success(
            picked(
              name: '${'م' * 40} photo.jpg',
              mimeType: 'image/jpeg',
              mediaKind: AttachmentMediaKind.image,
            ),
          ),
        );
        fakeSystemInsets(tester);
        await launch(tester, locale: locale, textScale: 2);
        final strings = AppLocalizations.of(
          tester.element(find.byType(Scaffold)),
        );

        await choose(tester, strings.attachmentPhotoOption);
        await tester.enterText(caption, '\u{1F600}' * 1020);
        await tester.pump();

        expect(tester.takeException(), isNull);
        await tester.ensureVisible(send);
        await tester.pumpAndSettle();
        expect(tester.getRect(send).bottom, lessThanOrEqualTo(800 - 48));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('keeps Send above the keyboard', (tester) async {
      platform.enqueuePick(Result.success(picked()));
      fakeSystemInsets(tester);
      await launch(tester, textScale: 2);
      await choose(tester, 'File');

      await tester.ensureVisible(caption);
      await tester.pumpAndSettle();
      await tester.tap(caption);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      fakeOpenKeyboard(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();

      expect(tester.getRect(send).bottom, lessThanOrEqualTo(800 - 300));
      expect(tester.takeException(), isNull);
    });
  });
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 10, 10, 21, 30);
}

final class _Allowance implements AttachmentAllowancePort {
  int spent = 0;

  @override
  Future<AttachmentDailyAllowance> read(DateTime now) async =>
      AttachmentDailyAllowance(day: utcDayOf(now), spentBytes: spent);

  @override
  Future<void> record({required int bytes, required DateTime now}) async {}
}

/// The cache's part of the queue, with no file system under it.
final class _Files implements AttachmentOutgoingFilesPort {
  final discarded = <String>[];

  @override
  Future<void> beforeTransfer({required Iterable<File> liveOutgoing}) async {}

  @override
  Future<Result<String>> adoptOutgoing({
    required String attachmentId,
    required File copy,
  }) async => const Result.success('00112233445566778899aabbccddeeff');

  @override
  Future<void> discardOutgoing(File copy) async => discarded.add(copy.path);
}
