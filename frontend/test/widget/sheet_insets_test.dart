import 'dart:async';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/system_insets.dart';
import '../support/voice_screen_harness.dart';

/// A sheet keeps each control out of the status bar's, the gesture bar's and
/// the keyboard's way, and the surface it draws still reaches the screen's edge
/// (`responsive-ui.md`, Adaptive shell). The rule is written once, in
/// `app_modals.dart`; this proves it on the two sheet functions themselves and
/// on the voice room's Rename sheet. The sheets of the pages that open them are
/// proved beside those pages' own tests, under the same group name.
const _phone = Size(360, 800);
const _short = Size(360, 640);
const _statusBar = 24.0;
const _gestureBar = 48.0;
const _keyboard = 300.0;
const _margin = AppSpacing.x6;

/// Forui's own share of the screen, which the sheets keep to.
const _share = 9 / 16;

final _surface = find.byKey(const ValueKey('app-sheet-surface'));

Finder _button(int index) => find.byKey(ValueKey('button-$index'));

/// [count] buttons, one under the other, the last of them [_button] `count - 1`.
Widget _buttons(int count) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (var index = 0; index < count; index += 1) ...[
      if (index > 0) const SizedBox(height: AppSpacing.x2),
      AppButton(
        key: ValueKey('button-$index'),
        label: 'Button $index',
        onPressed: () {},
      ),
    ],
  ],
);

/// Mounts an app with one button, `open`, that calls [open], and presses it.
///
/// The view is [size] at a pixel ratio of 1 with the status bar and the gesture
/// bar of an Android phone that draws edge to edge. With [keyboard] the
/// keyboard is open before the sheet is.
Future<void> _launch(
  WidgetTester tester, {
  required Size size,
  required Future<Object?> Function(BuildContext context) open,
  double textScale = 1,
  bool keyboard = false,
}) async {
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  fakeSystemInsets(tester, top: _statusBar, bottom: _gestureBar);
  if (keyboard) {
    fakeOpenKeyboard(tester, height: _keyboard);
  }
  await tester.pumpWidget(
    MaterialApp(
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
            child: ElevatedButton(
              onPressed: () => unawaited(open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<Object?> Function(BuildContext) _sheet(
  Widget child, {
  bool childScrolls = false,
}) =>
    (context) => showAppSheet<void>(
      context: context,
      semanticLabel: 'Test sheet',
      childScrolls: childScrolls,
      child: child,
    );

Future<Object?> Function(BuildContext) _anchoredSheet(Widget child) =>
    (context) => showAppAnchoredSheet<void>(
      context: context,
      semanticLabel: 'Test sheet',
      anchored: const SizedBox(
        key: ValueKey('anchored'),
        width: 200,
        height: 56,
      ),
      child: child,
    );

/// The position of the sheet's own scroll view: the first scrollable under the
/// surface, before any text field's.
ScrollPosition _scrollPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _surface, matching: find.byType(Scrollable)).first,
    )
    .position;

void main() {
  group('sheets keep clear of the system insets and the keyboard', () {
    group('showAppSheet', () {
      testWidgets('the last control rests above the gesture bar, and the '
          'surface runs down to the edge of the screen', (tester) async {
        await _launch(tester, size: _phone, open: _sheet(_buttons(3)));

        final surface = tester.getRect(_surface);
        expect(surface.bottom, _phone.height);
        expect(surface.left, 0);
        expect(surface.right, _phone.width);
        // Above the gesture bar by the sheet's margin, once: the inset is not
        // applied a second time anywhere.
        expect(
          tester.getRect(_button(2)).bottom,
          closeTo(_phone.height - _gestureBar - _margin, 0.01),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('a SafeArea in the child adds no second inset', (
        tester,
      ) async {
        await _launch(
          tester,
          size: _phone,
          open: _sheet(SafeArea(child: _buttons(3))),
        );

        expect(
          tester.getRect(_button(2)).bottom,
          closeTo(_phone.height - _gestureBar - _margin, 0.01),
        );
      });

      for (final opensFirst in [true, false]) {
        testWidgets(
          'with the keyboard open the sheet sits on it, with no gap but '
          "the sheet's margin (the keyboard ${opensFirst ? 'before' : 'after'}"
          ' the sheet)',
          (tester) async {
            await _launch(
              tester,
              size: _phone,
              keyboard: opensFirst,
              open: _sheet(_buttons(3)),
            );
            if (!opensFirst) {
              fakeOpenKeyboard(tester, height: _keyboard);
              await tester.pumpAndSettle();
            }

            final top = _phone.height - _keyboard;
            final last = tester.getRect(_button(2));
            expect(last.bottom, lessThanOrEqualTo(top));
            expect(top - last.bottom, closeTo(_margin, 0.01));
            expect(tester.getRect(_surface).bottom, closeTo(top, 0.01));
          },
        );
      }

      testWidgets('a sheet taller than the screen scrolls, and its last '
          'control scrolls fully into view, at 200% text on a short screen', (
        tester,
      ) async {
        await _launch(
          tester,
          size: _short,
          textScale: 2,
          open: _sheet(_buttons(10)),
        );

        final surface = tester.getRect(_surface);
        expect(surface.bottom, _short.height);
        expect(surface.top, greaterThanOrEqualTo(_statusBar));
        // As tall as the room and no taller: the share of the screen below the
        // status bar, and the gesture bar's strip on top of it.
        expect(
          surface.height,
          closeTo((_short.height - _statusBar) * _share + _gestureBar, 0.01),
        );
        final position = _scrollPosition(tester);
        expect(position.maxScrollExtent, greaterThan(0));
        expect(
          tester.getRect(_button(0)).top,
          greaterThanOrEqualTo(surface.top),
        );

        // By a drag, as a person scrolls it: the sheet's own drag to dismiss
        // does not take the gesture from the content.
        await tester.drag(_button(0), const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(_surface, findsOneWidget);
        expect(position.pixels, position.maxScrollExtent);
        final last = tester.getRect(_button(9));
        expect(
          last.bottom,
          closeTo(_short.height - _gestureBar - _margin, 0.01),
        );
        expect(last.top, greaterThanOrEqualTo(surface.top));
        expect(tester.takeException(), isNull);
      });

      testWidgets('with the keyboard open a tall sheet is kept below the '
          'status bar and above the keyboard', (tester) async {
        await _launch(
          tester,
          size: _short,
          keyboard: true,
          open: _sheet(_buttons(10)),
        );

        final surface = tester.getRect(_surface);
        expect(surface.bottom, closeTo(_short.height - _keyboard, 0.01));
        expect(surface.top, greaterThanOrEqualTo(_statusBar));
        final position = _scrollPosition(tester);
        expect(position.maxScrollExtent, greaterThan(0));
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        expect(
          tester.getRect(_button(9)).bottom,
          closeTo(surface.bottom - _margin, 0.01),
        );
      });

      for (final keyboard in [false, true]) {
        testWidgets(
          'a child that scrolls by itself is cut to the room, '
          'however tall it asks to be (keyboard ${keyboard ? 'open' : 'closed'})',
          (tester) async {
            await _launch(
              tester,
              size: _short,
              keyboard: keyboard,
              open: _sheet(
                childScrolls: true,
                SizedBox(
                  height: 900,
                  child: Column(
                    children: [
                      const Text('Title'),
                      Expanded(
                        child: ListView.builder(
                          itemCount: 60,
                          itemBuilder: (context, index) =>
                              ListTile(title: Text('Row $index')),
                        ),
                      ),
                      AppButton(
                        key: const ValueKey('footer'),
                        label: 'Footer',
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ),
            );

            final floor = keyboard ? _short.height - _keyboard : _short.height;
            final surface = tester.getRect(_surface);
            expect(surface.bottom, closeTo(floor, 0.01));
            expect(surface.top, greaterThanOrEqualTo(_statusBar));
            final footer = tester.getRect(find.byKey(const ValueKey('footer')));
            expect(
              footer.bottom,
              closeTo(floor - _margin - (keyboard ? 0 : _gestureBar), 0.01),
            );
            expect(find.text('Row 0'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    });

    group('showAppAnchoredSheet', () {
      testWidgets('the last control rests above the gesture bar, and the '
          'surface runs down to the edge of the screen', (tester) async {
        await _launch(tester, size: _phone, open: _anchoredSheet(_buttons(3)));

        expect(tester.getRect(_surface).bottom, _phone.height);
        expect(
          tester.getRect(_button(2)).bottom,
          closeTo(_phone.height - _gestureBar - _margin, 0.01),
        );
        // The floating panel keeps to the space above the sheet.
        expect(
          tester.getRect(find.byKey(const ValueKey('anchored'))).bottom,
          lessThanOrEqualTo(tester.getRect(_surface).top),
        );
      });

      testWidgets('a SafeArea in the child adds no second inset', (
        tester,
      ) async {
        await _launch(
          tester,
          size: _phone,
          open: _anchoredSheet(SafeArea(child: _buttons(3))),
        );

        expect(
          tester.getRect(_button(2)).bottom,
          closeTo(_phone.height - _gestureBar - _margin, 0.01),
        );
      });

      testWidgets('with the keyboard open the whole sheet sits on it', (
        tester,
      ) async {
        await _launch(
          tester,
          size: _phone,
          keyboard: true,
          open: _anchoredSheet(_buttons(3)),
        );

        final top = _phone.height - _keyboard;
        expect(tester.getRect(_surface).bottom, closeTo(top, 0.01));
        expect(top - tester.getRect(_button(2)).bottom, closeTo(_margin, 0.01));
      });

      testWidgets('a sheet taller than the screen scrolls, and its last '
          'control scrolls fully into view, at 200% text on a short screen', (
        tester,
      ) async {
        await _launch(
          tester,
          size: _short,
          textScale: 2,
          open: _anchoredSheet(_buttons(10)),
        );

        final surface = tester.getRect(_surface);
        expect(surface.top, greaterThanOrEqualTo(_statusBar));
        final position = _scrollPosition(tester);
        expect(position.maxScrollExtent, greaterThan(0));
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        expect(
          tester.getRect(_button(9)).bottom,
          closeTo(_short.height - _gestureBar - _margin, 0.01),
        );
        expect(tester.takeException(), isNull);
      });
    });

    group('the Rename sheet of a voice room', () {
      const phone = Size(390, 844);

      for (final keyboard in [false, true]) {
        testWidgets('has both buttons in the visible area, with the '
            'keyboard ${keyboard ? 'open' : 'closed'}', (tester) async {
          fakeSystemInsets(tester, top: _statusBar, bottom: _gestureBar);
          await pumpVoiceRoute(
            tester,
            initialLocation: '/voice-rooms/$voiceRoomId',
            size: phone,
            page: (_) => VoiceRoomInfoView(
              room: voiceRoom(),
              people: voicePeople(),
              voiceAvailable: true,
              offline: false,
              callRoomId: null,
              callDevices: 0,
              onStartCall: () {},
              onMutate: (_) async => Result.success(voiceRoom()),
            ),
          );

          await tester.tap(find.byKey(const ValueKey('voice-room-rename')));
          await tester.pumpAndSettle();
          if (keyboard) {
            fakeOpenKeyboard(tester, height: _keyboard);
            await tester.pumpAndSettle();
          }

          final floor = keyboard ? phone.height - _keyboard : phone.height;
          final surface = tester.getRect(_surface);
          expect(surface.bottom, closeTo(floor, 0.01));
          final save = find.byKey(const ValueKey('voice-room-rename-save'));
          final cancel = find.descendant(
            of: _surface,
            matching: find.widgetWithText(AppButton, 'Cancel'),
          );
          for (final button in [cancel, save]) {
            expect(button, findsOneWidget);
            final rect = tester.getRect(button);
            expect(rect.top, greaterThanOrEqualTo(surface.top));
            expect(
              rect.bottom,
              lessThanOrEqualTo(floor - (keyboard ? 0 : _gestureBar)),
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}
