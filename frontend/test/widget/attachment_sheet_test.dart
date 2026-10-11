import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_file_actions.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/attachment_platform_fake.dart';

/// ADR-089 D1 and D7: the sheet chooses in a direct chat and in Saved
/// Messages, says "not built" in a group chat, and shows a ready attachment's
/// details with Open, Save and Share.
void main() {
  testWidgets('the choices are localized and semantically reachable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(tester, const AttachmentSheet.choose());

    expect(find.text('Choose encrypted media or a file.'), findsOneWidget);
    for (final label in ['Photo or image', 'File', 'Camera']) {
      expect(
        tester.getSemantics(find.widgetWithText(ListTile, label)),
        isSemantics(label: label, isButton: true, hasTapAction: true),
        reason: label,
      );
      // One node announces the choice, and none the tile under it.
      expect(find.semantics.byLabel(label), findsOneWidget, reason: label);
    }
    expect(find.text('Not built yet'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a choice closes the sheet with the kind chosen', (tester) async {
    for (final (label, kind) in [
      ('Photo or image', AttachmentPickKind.photo),
      ('File', AttachmentPickKind.file),
      ('Camera', AttachmentPickKind.camera),
    ]) {
      final result = await _open(tester, const AttachmentSheet.choose());
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(await result, kind, reason: label);
      expect(find.byType(AttachmentSheet), findsNothing);
    }
  });

  testWidgets('a choice made by a service that does not touch the screen '
      'chooses too', (tester) async {
    final semantics = tester.ensureSemantics();
    final result = await _open(tester, const AttachmentSheet.choose());

    tester.semantics.tap(find.semantics.byLabel('Camera'));
    await tester.pumpAndSettle();

    expect(await result, AttachmentPickKind.camera);
    semantics.dispose();
  });

  testWidgets('Cancel closes the sheet with no choice', (tester) async {
    final result = await _open(tester, const AttachmentSheet.choose());

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('a group chat is told attachments are not built for it', (
    tester,
  ) async {
    await _open(tester, const AttachmentSheet.notBuilt());

    expect(
      find.text(
        'Group chats cannot send files yet. Files can be sent in direct '
        'chats and in Saved Messages.',
      ),
      findsOneWidget,
    );
    expect(find.text('Not built yet'), findsOneWidget);
    for (final label in ['Photo or image', 'File', 'Camera']) {
      expect(find.text(label), findsNothing);
    }
  });

  group('the details of a ready attachment', () {
    final descriptor = EncryptedAttachmentDescriptor(
      capabilityId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      key: Uint8List(32),
      header: _header(),
      secretstreamHeader: Uint8List(24),
      encryptedSize: 18,
      bucketSize: 65536,
      plaintextSize: 1,
      displayName: '../photo.jpg',
      mimeType: 'image/jpeg',
      mediaKind: AttachmentMediaKind.image,
      width: 1,
      height: 1,
    );
    late FakeAttachmentPlatform platform;
    late List<String> asked;
    late File cached;
    File? held;

    setUp(() {
      platform = FakeAttachmentPlatform();
      asked = [];
      cached = File('cache/plain/0123456789abcdef0123456789abcdef/photo.jpg');
      held = cached;
    });

    AttachmentSheet sheet({int days = 30}) => AttachmentSheet.details(
      descriptor: descriptor,
      retentionDays: days,
      actions: AttachmentFileActions(
        platform: platform,
        files: (attachmentId) async {
          asked.add(attachmentId);
          return held;
        },
      ),
    );

    testWidgets('show a safe name, the type, the size and how long the server '
        'keeps it', (tester) async {
      await _open(tester, sheet(days: 14));

      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('image/jpeg · 1 B'), findsOneWidget);
      expect(
        find.text(
          'The server keeps the encrypted copy for up to 14 days after it '
          'was sent.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('../'), findsNothing);
      expect(find.text('Open or save verified file'), findsNothing);
    });

    testWidgets('one day reads as one', (tester) async {
      await _open(tester, sheet(days: 1));

      expect(
        find.text(
          'The server keeps the encrypted copy for up to 1 day after it was '
          'sent.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Open, Save and Share hand the cached file to the platform', (
      tester,
    ) async {
      await _open(tester, sheet());

      for (final label in ['Open', 'Save', 'Share']) {
        await tester.tap(find.widgetWithText(AppButton, label));
        await tester.pumpAndSettle();
      }

      expect(asked, List.filled(3, descriptor.capabilityId));
      expect(platform.opens.single.file, cached);
      expect(platform.opens.single.mimeType, 'image/jpeg');
      expect(platform.saves.single.file, cached);
      expect(platform.saves.single.name, 'photo.jpg');
      expect(platform.shares.single.file, cached);
      for (final message in [
        'No app on this phone can open this file. Save it instead.',
        'The file could not be saved.',
        'The phone did not take the file.',
      ]) {
        expect(find.text(message), findsNothing);
      }
    });

    for (final (label, answer, message) in [
      (
        'Open',
        const Result<void>.failure(
          UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
        ),
        'No app on this phone can open this file. Save it instead.',
      ),
      (
        'Save',
        const Result<void>.failure(
          StorageFailure(StorageFailureKind.unavailable),
        ),
        'The file could not be saved.',
      ),
      (
        'Share',
        const Result<void>.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        ),
        'The phone did not take the file.',
      ),
    ]) {
      testWidgets('$label says why it failed', (tester) async {
        platform
          ..openAnswer = answer
          ..saveAnswer = answer
          ..shareAnswer = answer;
        await _open(tester, sheet());

        await tester.tap(find.widgetWithText(AppButton, label));
        await tester.pumpAndSettle();

        expect(find.text(message), findsOneWidget);
      });
    }

    testWidgets('a file no longer on the phone is said to need a download, '
        'and reaches no app', (tester) async {
      held = null;
      await _open(tester, sheet());

      for (final label in ['Open', 'Save', 'Share']) {
        await tester.tap(find.widgetWithText(AppButton, label));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'The file is no longer on this phone. Download it again from its '
            'message.',
          ),
          findsOneWidget,
          reason: label,
        );
      }
      expect(platform.calls, isEmpty);
    });

    testWidgets('a save the user closed says nothing', (tester) async {
      platform.saveAnswer = const Result<void>.failure(
        CancellationFailure(CancellationFailureKind.requestedByUser),
      );
      await _open(tester, sheet());

      await tester.tap(find.widgetWithText(AppButton, 'Save'));
      await tester.pumpAndSettle();

      expect(platform.saves, hasLength(1));
      expect(find.textContaining('could not'), findsNothing);
    });
  });
}

/// Opens [sheet] through the app sheet and answers what it closes with.
Future<Future<AttachmentPickKind?>> _open(
  WidgetTester tester,
  Widget sheet,
) async {
  final result = Completer<AttachmentPickKind?>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => unawaited(
                showAppSheet<AttachmentPickKind>(
                  context: context,
                  semanticLabel: 'Attach',
                  child: sheet,
                ).then(result.complete),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result.future;
}

Uint8List _header() {
  final bytes = Uint8List(66);
  bytes.setAll(0, ascii.encode('CPAFV001'));
  bytes[8] = 1;
  final data = ByteData.sublistView(bytes);
  data.setUint32(10, 65536, Endian.big);
  data.setUint64(14, 1, Endian.big);
  data.setUint64(22, 18, Endian.big);
  data.setUint32(30, 65536, Endian.big);
  return bytes;
}
