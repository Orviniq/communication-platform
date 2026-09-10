import 'dart:async';

import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:flutter_test/flutter_test.dart';

/// What separates a conversation being open from a conversation being read.
///
/// The bug this covers was a mark-read hung on the chat route's first frame: a
/// route that is still in the navigator behind a backgrounded application gets
/// built and laid out when the application comes back, so every message that
/// arrived while it was away was marked read before the user had seen the
/// screen — and, on the far side, reported read to the person who sent them.
/// Every case below is that distinction from one side or another.
void main() {
  test('a conversation nothing is showing is never marked read', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var marked = 0;
    final marker = _marker(registry, () => marked++);
    addTearDown(marker.dispose);

    marker.start();
    await _settle();
    expect(marked, 0);

    // Another conversation being on screen is not this one being on screen.
    registry.enter('other');
    await _settle();
    expect(marked, 0);
  });

  test('opening the application is not reading what is behind it', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var marked = 0;
    final marker = _marker(registry, () => marked++);
    addTearDown(marker.dispose);

    // The route is mounted — it never left — but the application is not in
    // front of anybody, which is the whole of the defect.
    registry.setForeground(foreground: false);
    registry.enter('conversation');
    marker.start();
    await _settle();
    expect(marked, 0);

    registry.setForeground(foreground: true);
    await _settle();
    expect(marked, 1, reason: 'the screen is now in front of the user');
  });

  test('a route replacing one for the same conversation still reads', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var marked = 0;
    final marker = _marker(registry, () => marked++);
    addTearDown(marker.dispose);

    // The registry already names this conversation, so registering it again is
    // correctly not a change and emits nothing. Starting has to look.
    registry.enter('conversation');
    marker.start();
    await _settle();
    expect(marked, 1);
  });

  test('a message arriving is read while visible and not while away', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var marked = 0;
    final marker = _marker(registry, () => marked++);
    addTearDown(marker.dispose);

    registry.enter('conversation');
    marker.start();
    await _settle();
    expect(marked, 1);

    marker.notify();
    await _settle();
    expect(marked, 2, reason: 'it landed on the screen they are looking at');

    registry.setForeground(foreground: false);
    await _settle();
    final whileAway = marked;
    marker.notify();
    await _settle();
    expect(marked, whileAway, reason: 'nobody is looking at it');
  });

  test('leaving the conversation stops it marking anything read', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var marked = 0;
    final marker = _marker(registry, () => marked++);

    registry.enter('conversation');
    marker.start();
    await _settle();
    expect(marked, 1);

    marker.dispose();
    marker.notify();
    registry.setForeground(foreground: false);
    registry.setForeground(foreground: true);
    await _settle();
    expect(marked, 1);
  });

  test('signals arriving mid-write are collapsed into one more pass', () async {
    final registry = VisibleConversationRegistry(observeLifecycle: false);
    addTearDown(registry.dispose);
    var started = 0;
    final gates = <Completer<void>>[];
    final marker = VisibleConversationReadMarker(
      registry: registry,
      conversationId: 'conversation',
      markRead: () {
        started++;
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      },
    );
    addTearDown(marker.dispose);

    registry.enter('conversation');
    marker.start();
    await _settle();
    expect(started, 1);

    // Three signals against one in-flight write. Two passes is the answer:
    // the one that is running, and one after it that sees everything they
    // asked about at once.
    marker
      ..notify()
      ..notify()
      ..notify();
    await _settle();
    expect(started, 1);

    gates.removeAt(0).complete();
    await _settle();
    expect(started, 2);

    gates.removeAt(0).complete();
    await _settle();
    expect(started, 2);
  });
}

VisibleConversationReadMarker _marker(
  VisibleConversationRegistry registry,
  void Function() onMark,
) => VisibleConversationReadMarker(
  registry: registry,
  conversationId: 'conversation',
  markRead: () async => onMark(),
);

/// Lets the marker's queued work run to a standstill.
Future<void> _settle() => Future<void>.delayed(Duration.zero);
