import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-089 D1: the sheet chooses in a direct chat and in Saved Messages, says
/// "not built" in a group chat, and shows a received descriptor's details.
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

  testWidgets('a verified descriptor shows a safe name and bounded details', (
    tester,
  ) async {
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

    await _open(tester, AttachmentSheet.details(descriptor: descriptor));

    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('image/jpeg · 1 bytes'), findsOneWidget);
    expect(find.text('Open or save verified file'), findsOneWidget);
    expect(find.textContaining('../'), findsNothing);
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
