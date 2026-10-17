import 'package:communication_platform/features/messaging/presentation/chat_message_builder.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// How strong the jump tint on one bubble is right now, from 0 (none) up to
/// the peak the bubble paints ([chatPulsePeak]).
///
/// Read from the tint's own decoration rather than from a pixel, so a test can
/// tell "no tint" from "a faint one" and "a fading one" from "a steady one".
double pulseStrength(WidgetTester tester, String messageId) {
  final tint = find
      .descendant(
        of: find.byKey(ValueKey('message-pulse-$messageId')),
        matching: find.byType(DecoratedBox),
      )
      .first;
  final decoration = tester.widget<DecoratedBox>(tint).decoration;
  return (decoration as BoxDecoration).color?.a ?? 0;
}

/// The peak opacity of the tint, which a bubble at full strength paints.
const chatPulsePeak = 0.3;

/// Pumps in small steps until the bubble of [messageId] shows a tint, and
/// returns the strength it first showed. Fails if none shows within [limit].
Future<double> pumpUntilPulse(
  WidgetTester tester,
  String messageId, {
  Duration limit = const Duration(seconds: 3),
}) async {
  const step = Duration(milliseconds: 50);
  var waited = Duration.zero;
  while (waited <= limit) {
    await tester.pump(step);
    waited += step;
    if (find.byKey(ValueKey('message-pulse-$messageId')).evaluate().isEmpty) {
      continue;
    }
    final strength = pulseStrength(tester, messageId);
    if (strength > 0) return strength;
  }
  fail('no jump tint showed on $messageId within $limit');
}
