import 'package:flutter_test/flutter_test.dart';

/// Gives the test view the system insets of an Android phone that draws edge
/// to edge: [top] for the status bar, and [bottom] for the gesture bar or the
/// navigation buttons. In logical pixels: the device pixel ratio is 1.
void fakeSystemInsets(
  WidgetTester tester, {
  double top = 24,
  double bottom = 48,
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
  tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
}

/// Opens the keyboard the way Android reports it: the keyboard as a bottom
/// view inset, and no bottom padding left under it. The view padding of the
/// gesture bar stays.
void fakeOpenKeyboard(WidgetTester tester, {double height = 300}) {
  tester.view.viewInsets = FakeViewPadding(bottom: height);
  tester.view.padding = FakeViewPadding(top: tester.view.padding.top);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.view.resetPadding);
}
