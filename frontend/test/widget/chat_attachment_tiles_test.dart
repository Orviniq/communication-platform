import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_download_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_attachment_tiles.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_message_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/attachment_descriptor_fixture.dart';

/// ADR-089 D7: a received attachment shows as a tile in its message, with its
/// kind, name, size and state, and a tap does what its state allows.
void main() {
  group('the tile state', () {
    test('a job decides while it exists', () {
      for (final persisted in AttachmentTransferState.values) {
        for (final cached in [null, true, false]) {
          for (final (job, shown) in [
            (AttachmentDownloadState.waiting, ChatAttachmentTileState.waiting),
            (
              AttachmentDownloadState.downloading,
              ChatAttachmentTileState.downloading,
            ),
            (
              AttachmentDownloadState.verifying,
              ChatAttachmentTileState.verifying,
            ),
            (AttachmentDownloadState.damaged, ChatAttachmentTileState.damaged),
            (AttachmentDownloadState.failed, ChatAttachmentTileState.failed),
          ]) {
            expect(
              chatAttachmentTileState(
                persisted: persisted,
                cached: cached,
                job: job,
              ),
              shown,
              reason: '$persisted $cached $job',
            );
          }
        }
      }
    });

    test('without a job the row decides, and the cache only takes a ready '
        'file back', () {
      for (final persisted in AttachmentTransferState.values) {
        for (final cached in [null, true, false]) {
          final expected = switch (persisted) {
            AttachmentTransferState.expired => ChatAttachmentTileState.expired,
            AttachmentTransferState.ready =>
              cached == false
                  ? ChatAttachmentTileState.notDownloaded
                  : ChatAttachmentTileState.ready,
            // `queued`, and every value the client never writes.
            _ => ChatAttachmentTileState.notDownloaded,
          };
          expect(
            chatAttachmentTileState(
              persisted: persisted,
              cached: cached,
              job: null,
            ),
            expected,
            reason: '$persisted $cached',
          );
        }
      }
    });

    test('a picture is drawn within 260 by 320, its ratio kept from 1:2 to '
        '2:1', () {
      expect(
        chatAttachmentPictureSize(width: 4000, height: 3000, maxWidth: 400),
        const Size(260, 195),
      );
      expect(
        chatAttachmentPictureSize(width: 1000, height: 2000, maxWidth: 400),
        const Size(160, 320),
      );
      expect(
        chatAttachmentPictureSize(width: 100, height: 8000, maxWidth: 400),
        const Size(160, 320),
      );
      expect(
        chatAttachmentPictureSize(width: 8000, height: 100, maxWidth: 200),
        const Size(200, 100),
      );
      expect(
        chatAttachmentPictureSize(width: null, height: null, maxWidth: 400),
        const Size(260, 260),
      );
    });
  });

  group('the bubble', () {
    late _Transfers transfers;
    late List<ChatIntent> intents;

    setUp(() {
      transfers = _Transfers();
      intents = [];
    });

    Future<void> show(
      WidgetTester tester,
      List<ChatMessageViewModel> messages, {
      Size size = const Size(430, 900),
      Locale locale = const Locale('en'),
      double textScale = 1,
      double pixelRatio = 1,
    }) => _pump(
      tester,
      ChatConversationView(
        model: _model(messages),
        onIntent: intents.add,
        attachmentTransfers: transfers,
        attachmentRetentionDays: 30,
      ),
      size: size,
      locale: locale,
      textScale: textScale,
      pixelRatio: pixelRatio,
    );

    Finder tile(String messageId, [int index = 0]) =>
        find.byKey(ValueKey('attachment-tile-$messageId-$index'));

    Future<void> tapTile(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      // The bubble's double tap holds the arena this long.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
    }

    testWidgets('each state says what it is, and a tap does what it allows', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final attachment = testAttachmentDescriptor(
        capability: testCapability(1),
        displayName: 'minutes.pdf',
        mimeType: 'application/pdf',
        plaintextSize: 70000,
      );
      final cases =
          <
            ({
              AttachmentTransferState persisted,
              AttachmentDownloadJob? job,
              String state,
              String? hint,
              Type? intent,
            })
          >[
            (
              persisted: AttachmentTransferState.queued,
              job: null,
              state: 'Not downloaded',
              hint: 'Download',
              intent: DownloadAttachmentIntent,
            ),
            (
              persisted: AttachmentTransferState.queued,
              job: _job(attachment, AttachmentDownloadState.waiting),
              state: 'Waiting to download',
              hint: 'Cancel the download',
              intent: CancelAttachmentDownloadIntent,
            ),
            (
              persisted: AttachmentTransferState.queued,
              job: _job(
                attachment,
                AttachmentDownloadState.downloading,
                progress: .42,
              ),
              state: 'Downloading, 42%',
              hint: 'Cancel the download',
              intent: CancelAttachmentDownloadIntent,
            ),
            (
              persisted: AttachmentTransferState.queued,
              job: _job(
                attachment,
                AttachmentDownloadState.verifying,
                progress: .5,
              ),
              state: 'Verifying, 50%',
              hint: 'Cancel the download',
              intent: CancelAttachmentDownloadIntent,
            ),
            (
              persisted: AttachmentTransferState.ready,
              job: null,
              state: 'Downloaded and verified',
              hint: 'Show Open, Save and Share',
              intent: OpenAttachmentIntent,
            ),
            (
              persisted: AttachmentTransferState.expired,
              job: null,
              state: 'Expired: the server no longer keeps this file',
              hint: null,
              intent: null,
            ),
            (
              persisted: AttachmentTransferState.queued,
              job: _job(attachment, AttachmentDownloadState.damaged),
              state:
                  'Damaged: this file did not pass the check, and nothing '
                  'was kept',
              hint: null,
              intent: null,
            ),
            (
              persisted: AttachmentTransferState.queued,
              job: _job(attachment, AttachmentDownloadState.failed),
              state: 'The download failed',
              hint: 'Try the download again',
              intent: RetryAttachmentDownloadIntent,
            ),
          ];
      for (final example in cases) {
        transfers = _Transfers()..jobs[attachment.capabilityId] = example.job;
        intents = [];
        await show(tester, [
          _attachmentMessage(
            1,
            attachments: [attachment],
            states: [example.persisted],
          ),
        ]);

        final node = tester.getSemantics(tile(_id(1)));
        expect(
          node.label,
          'Encrypted attachment: minutes.pdf, 68 KB, ${example.state}',
          reason: example.state,
        );
        expect(node.hint, example.hint ?? '', reason: example.state);
        expect(
          find.textContaining(example.state),
          findsOneWidget,
          reason: example.state,
        );
        await tapTile(tester, tile(_id(1)));

        if (example.intent == null) {
          expect(intents, isEmpty, reason: example.state);
          // A tile with nothing to do does nothing: it opens no menu.
          expect(find.text('Reply'), findsNothing, reason: example.state);
        } else {
          expect(
            intents.single.runtimeType,
            example.intent,
            reason: example.state,
          );
        }
        switch (intents.firstOrNull) {
          case DownloadAttachmentIntent(:final messageId, :final attachment):
            expect(messageId, _id(1));
            expect(attachment.capabilityId, testCapability(1));
          case OpenAttachmentIntent(:final attachment):
            expect(attachment?.capabilityId, testCapability(1));
          case CancelAttachmentDownloadIntent(:final attachment) ||
              RetryAttachmentDownloadIntent(:final attachment):
            expect(attachment.capabilityId, testCapability(1));
          default:
            break;
        }
      }
      semantics.dispose();
    });

    testWidgets('draws one tile for each attachment, and the caption below '
        'them', (tester) async {
      final first = testAttachmentDescriptor(
        capability: testCapability(1),
        displayName: 'first.pdf',
      );
      final second = testAttachmentDescriptor(
        capability: testCapability(2),
        displayName: 'second.pdf',
      );
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [first, second],
          states: const [
            AttachmentTransferState.ready,
            AttachmentTransferState.queued,
          ],
          text: 'سلام، two files',
        ),
      ]);

      expect(find.byType(ChatAttachmentTile), findsNWidgets(2));
      expect(find.text('first.pdf'), findsOneWidget);
      expect(find.text('second.pdf'), findsOneWidget);
      final caption = find.text('سلام، two files');
      expect(caption, findsOneWidget);
      // Its direction is its first strong character's, not the locale's.
      expect(tester.widget<Text>(caption).textDirection, TextDirection.rtl);
      expect(
        tester.getTopLeft(caption).dy,
        greaterThan(tester.getBottomLeft(tile(_id(1), 1)).dy),
      );

      await tapTile(tester, tile(_id(1), 1));
      expect(
        (intents.single as DownloadAttachmentIntent).attachment.capabilityId,
        testCapability(2),
      );
    });

    testWidgets('shows the message text as the caption, not the '
        'descriptor\'s, so an edit shows', (tester) async {
      final attachment = EncryptedAttachmentDescriptor(
        capabilityId: testCapability(1),
        key: testAttachmentDescriptor().key,
        header: testAttachmentDescriptor().header,
        secretstreamHeader: testAttachmentDescriptor().secretstreamHeader,
        encryptedSize: testAttachmentDescriptor().encryptedSize,
        bucketSize: testAttachmentDescriptor().bucketSize,
        plaintextSize: testAttachmentDescriptor().plaintextSize,
        displayName: 'file.txt',
        mimeType: 'text/plain',
        mediaKind: AttachmentMediaKind.file,
        caption: 'the caption it was sent with',
      );
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [attachment],
          text: 'the caption after an edit',
          edited: true,
        ),
      ]);

      expect(find.text('the caption after an edit'), findsOneWidget);
      expect(find.text('the caption it was sent with'), findsNothing);
    });

    testWidgets('a deleted message shows no tile', (tester) async {
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [testAttachmentDescriptor()],
          deleted: true,
        ),
      ]);

      expect(find.byType(ChatAttachmentTile), findsNothing);
      expect(find.text('Message deleted'), findsOneWidget);
    });

    testWidgets('a tap on the bubble outside a tile opens the menu', (
      tester,
    ) async {
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [testAttachmentDescriptor()],
          text: 'a caption',
        ),
      ]);

      await tapTile(tester, find.text('a caption'));

      expect(intents, isEmpty);
      expect(find.text('Reply'), findsOneWidget);
    });

    testWidgets('every tile keeps the minimum touch target', (tester) async {
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [
            testAttachmentDescriptor(capability: testCapability(1)),
            testAttachmentDescriptor(capability: testCapability(2)),
          ],
        ),
      ]);

      for (final index in [0, 1]) {
        final size = tester.getSize(tile(_id(1), index));
        expect(size.height, greaterThanOrEqualTo(AppFocus.minimumTarget));
        expect(size.width, greaterThanOrEqualTo(AppFocus.minimumTarget));
      }
    });

    testWidgets('a progress change redraws its own tile and nothing else', (
      tester,
    ) async {
      final first = testAttachmentDescriptor(capability: testCapability(1));
      final second = testAttachmentDescriptor(capability: testCapability(2));
      transfers
        ..jobs[first.capabilityId] = _job(
          first,
          AttachmentDownloadState.downloading,
          progress: .1,
        )
        ..jobs[second.capabilityId] = _job(
          second,
          AttachmentDownloadState.waiting,
        );
      await show(tester, [
        _attachmentMessage(1, attachments: [first, second]),
        _attachmentMessage(2, attachments: [testAttachmentDescriptor()]),
      ]);
      final rebuilt = <Widget>[];
      debugOnRebuildDirtyWidget = (element, _) => rebuilt.add(element.widget);
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      transfers.emit(
        _job(first, AttachmentDownloadState.downloading, progress: .2),
      );
      // The event reaches the tile in a microtask, and its frame is the next.
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Downloading, 20%'), findsOneWidget);
      final tiles = rebuilt.whereType<ChatAttachmentTile>().toList();
      expect(tiles, hasLength(1));
      expect(tiles.single.attachment.capabilityId, first.capabilityId);
      expect(rebuilt.whereType<ChatMessageBuilder>(), isEmpty);
      expect(rebuilt.whereType<ChatConversationView>(), isEmpty);
    });

    testWidgets(
      'a ready picture shows inline, decoded no wider than its tile',
      (tester) async {
        final directory = await tester.runAsync(
          () => Directory.systemTemp.createTemp('cp_tile_picture_'),
        );
        addTearDown(
          () => tester.runAsync(() => directory!.delete(recursive: true)),
        );
        final png = File(
          '${directory!.path}${Platform.pathSeparator}photo.png',
        );
        await tester.runAsync(() => png.writeAsBytes(_onePixelPng));
        final picture = _picture(capability: testCapability(1));
        transfers.pictures[picture.capabilityId] = png;
        await show(tester, [
          _attachmentMessage(
            1,
            attachments: [picture],
            states: const [AttachmentTransferState.ready],
            image: true,
          ),
        ]);
        await _decode(tester);

        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, isNotNull);
        expect(find.text('This picture cannot be shown'), findsNothing);
        // Drawn in the descriptor's 4:3, as wide as the bubble allows up to
        // 260, and decoded at that width in device pixels.
        final drawn = tester.getSize(find.byType(RawImage));
        expect(drawn.width, lessThanOrEqualTo(260));
        expect(drawn.width, greaterThan(200));
        expect(drawn.height, closeTo(drawn.width * 3 / 4, .01));
        final image = tester.widget<Image>(find.byType(Image));
        expect((image.image as ResizeImage).width, drawn.width.ceil());

        await tapTile(tester, tile(_id(1)));
        expect(intents.single, isA<OpenAttachmentIntent>());
      },
    );

    testWidgets('a picture is never decoded wider than 1,024 px', (
      tester,
    ) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cp_tile_picture_'),
      );
      addTearDown(
        () => tester.runAsync(() => directory!.delete(recursive: true)),
      );
      final png = File('${directory!.path}${Platform.pathSeparator}photo.png');
      await tester.runAsync(() => png.writeAsBytes(_onePixelPng));
      final picture = _picture(capability: testCapability(1));
      transfers.pictures[picture.capabilityId] = png;
      await show(
        tester,
        [
          _attachmentMessage(
            1,
            attachments: [picture],
            states: const [AttachmentTransferState.ready],
            image: true,
          ),
        ],
        // 2150 by 4500 physical pixels at five to one: 430 by 900 logical.
        size: const Size(2150, 4500),
        pixelRatio: 5,
      );
      await _decode(tester);

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).width, 1024);
    });

    testWidgets('a picture that cannot be decoded says so, and still opens '
        'its details', (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cp_tile_picture_'),
      );
      addTearDown(
        () => tester.runAsync(() => directory!.delete(recursive: true)),
      );
      final broken = File('${directory!.path}${Platform.pathSeparator}x.png');
      await tester.runAsync(() => broken.writeAsBytes(utf8.encode('not png')));
      final picture = _picture(capability: testCapability(1));
      transfers.pictures[picture.capabilityId] = broken;
      await show(tester, [
        _attachmentMessage(
          1,
          attachments: [picture],
          states: const [AttachmentTransferState.ready],
          image: true,
        ),
      ]);
      await _decode(tester);

      expect(find.text('This picture cannot be shown'), findsOneWidget);
      await tapTile(tester, tile(_id(1)));
      expect(intents.single, isA<OpenAttachmentIntent>());
    });

    testWidgets('a picture not downloaded keeps its place, and a ready one '
        'the cache lost is not downloaded', (tester) async {
      final picture = _picture(capability: testCapability(1));
      final lost = _picture(capability: testCapability(2));
      await show(tester, [
        _attachmentMessage(1, attachments: [picture], image: true),
        _attachmentMessage(
          2,
          attachments: [lost],
          states: const [AttachmentTransferState.ready],
          image: true,
        ),
      ]);

      expect(find.byType(Image), findsNothing);
      // The placeholder holds the picture's 4:3 place above the details.
      final placeholder = tester.getSize(
        find.descendant(of: tile(_id(1)), matching: find.byType(ColoredBox)),
      );
      expect(placeholder.width, greaterThan(200));
      expect(placeholder.height, closeTo(placeholder.width * 3 / 4, .01));
      expect(
        tester.getSemantics(tile(_id(2))).label,
        contains('Not downloaded'),
      );
      await tapTile(tester, tile(_id(2)));
      expect(intents.single, isA<DownloadAttachmentIntent>());
    });

    for (final locale in [const Locale('en'), const Locale('fa')]) {
      testWidgets('nothing overflows at 200% text in ${locale.languageCode}', (
        tester,
      ) async {
        final long = 'a-very-long-file-name-that-keeps-going-and-going.pdf';
        final damaged = testAttachmentDescriptor(capability: testCapability(4));
        final failed = testAttachmentDescriptor(capability: testCapability(5));
        final running = testAttachmentDescriptor(capability: testCapability(6));
        transfers.jobs
          ..[damaged.capabilityId] = _job(
            damaged,
            AttachmentDownloadState.damaged,
          )
          ..[failed.capabilityId] = _job(failed, AttachmentDownloadState.failed)
          ..[running.capabilityId] = _job(
            running,
            AttachmentDownloadState.downloading,
            progress: .7,
          );
        await show(
          tester,
          [
            _attachmentMessage(
              1,
              attachments: [
                testAttachmentDescriptor(
                  capability: testCapability(1),
                  displayName: long,
                ),
                testAttachmentDescriptor(capability: testCapability(2)),
              ],
              states: const [
                AttachmentTransferState.queued,
                AttachmentTransferState.expired,
              ],
              text: 'A caption long enough to wrap over several lines here.',
            ),
            _attachmentMessage(
              2,
              attachments: [_picture(capability: testCapability(3))],
              image: true,
              outgoing: true,
            ),
            _attachmentMessage(3, attachments: [damaged, failed, running]),
          ],
          size: const Size(360, 800),
          locale: locale,
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(ChatAttachmentTile), findsWidgets);
      });
    }
  });
}

/// Lets the picture's file be read and decoded, which happens outside the
/// test's fake clock.
Future<void> _decode(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

final class _Transfers implements ChatAttachmentTransfers {
  final jobs = <String, AttachmentDownloadJob?>{};
  final pictures = <String, File>{};
  final _changes = StreamController<AttachmentDownloadJob>.broadcast();

  void emit(AttachmentDownloadJob job) {
    jobs[job.attachmentId] = job;
    _changes.add(job);
  }

  @override
  AttachmentDownloadJob? jobOf(String attachmentId) => jobs[attachmentId];

  @override
  Stream<AttachmentDownloadJob?> watch(String attachmentId) =>
      _changes.stream.where((job) => job.attachmentId == attachmentId);

  @override
  Future<File?> picture(String attachmentId) async => pictures[attachmentId];
}

AttachmentDownloadJob _job(
  EncryptedAttachmentDescriptor attachment,
  AttachmentDownloadState state, {
  double progress = 0,
}) => AttachmentDownloadJob(
  messageId: 'message',
  descriptor: attachment,
  state: state,
  progress: progress,
);

EncryptedAttachmentDescriptor _picture({required String capability}) {
  final base = testAttachmentDescriptor(
    capability: capability,
    displayName: 'photo.png',
    mimeType: 'image/png',
    mediaKind: AttachmentMediaKind.image,
  );
  return EncryptedAttachmentDescriptor(
    capabilityId: base.capabilityId,
    key: base.key,
    header: base.header,
    secretstreamHeader: base.secretstreamHeader,
    encryptedSize: base.encryptedSize,
    bucketSize: base.bucketSize,
    plaintextSize: base.plaintextSize,
    displayName: base.displayName,
    mimeType: base.mimeType,
    mediaKind: base.mediaKind,
    width: 4000,
    height: 3000,
  );
}

String _id(int index) => 'message-id-$index';

ChatMessageViewModel _attachmentMessage(
  int index, {
  required List<EncryptedAttachmentDescriptor> attachments,
  List<AttachmentTransferState>? states,
  String? text,
  bool deleted = false,
  bool edited = false,
  bool outgoing = false,
  bool image = false,
}) => ChatMessageViewModel(
  id: _id(index),
  authorId: outgoing ? 'self' : 'peer',
  authorName: outgoing ? 'You' : 'Peer',
  outgoing: outgoing,
  kind: image
      ? ChatTimelineContentKind.image
      : ChatTimelineContentKind.attachment,
  text: text ?? '',
  attachments: attachments,
  attachmentStates:
      states ?? [for (final _ in attachments) AttachmentTransferState.queued],
  timestamp: DateTime(2026, 10, 10, 9, index),
  delivery: outgoing
      ? ChatDeliveryViewState.accepted
      : ChatDeliveryViewState.received,
  firstInAuthorGroup: true,
  lastInAuthorGroup: true,
  edited: edited,
  deleted: deleted,
  pinned: false,
  starred: false,
  unread: false,
  timestampSkewed: false,
  canEdit: outgoing,
  canDeleteForEveryone: outgoing,
);

ChatTimelineViewModel _model(List<ChatMessageViewModel> messages) =>
    ChatTimelineViewModel(
      state: ChatTimelineLoadState.data,
      conversationId: 'conversation',
      title: 'Peer',
      savedMessages: false,
      securityGate: ChatSecurityGate.ready,
      offline: false,
      hasMoreBefore: false,
      loadingBefore: false,
      olderLoadFailed: false,
      typing: false,
      pinnedMessages: const [],
      messages: messages,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(430, 900),
  Locale locale = const Locale('en'),
  double textScale = 1,
  double pixelRatio = 1,
}) async {
  tester.view.devicePixelRatio = pixelRatio;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A one-pixel PNG, decoded by the engine as any picture is.
final _onePixelPng = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);
