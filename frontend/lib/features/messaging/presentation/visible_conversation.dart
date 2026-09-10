import 'dart:async';

import 'package:flutter/widgets.dart';

/// Which conversation the user is actually looking at.
///
/// "Actually" is the whole point: a chat route can stay mounted behind a
/// backgrounded application, and a message that arrives then has not been seen
/// by anyone. Visibility is therefore the conjunction of a mounted conversation
/// route and a foregrounded application, and it collapses to nothing when
/// either half is false.
///
/// It is deliberately volatile. Nothing about which screen is open belongs in
/// durable storage, and a stale value surviving a restart would suppress an
/// alert for a conversation nobody is reading.
final class VisibleConversationRegistry with WidgetsBindingObserver {
  VisibleConversationRegistry({bool observeLifecycle = true})
    : _observesLifecycle = observeLifecycle {
    if (!observeLifecycle) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    // Flutter leaves `lifecycleState` null until the first platform lifecycle
    // message arrives. Reading that as "backgrounded" would make every alert
    // fire for a conversation the user is staring at, up until the first
    // message lands; this code only runs because a Flutter view is hosting it,
    // so foreground is the truthful reading, and the first platform message
    // corrects it either way. Same reasoning as the delivery lifecycle port.
    final reported = WidgetsBinding.instance.lifecycleState;
    _foreground = reported == null || reported == AppLifecycleState.resumed;
  }

  final bool _observesLifecycle;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  String? _route;
  bool _foreground = true;
  bool _disposed = false;

  /// The conversation on screen, or `null` when none is or the application is
  /// not in the foreground.
  String? get conversationId => _foreground ? _route : null;

  bool get isForeground => _foreground;

  Stream<void> get changes => _changes.stream;

  /// Called by a conversation route as it mounts.
  void enter(String conversationId) {
    if (_route == conversationId) {
      return;
    }
    _route = conversationId;
    _emit();
  }

  /// Called by a conversation route as it leaves. The identifier is required so
  /// that a route disposing *after* its replacement has already registered
  /// cannot clear the newer one.
  void leave(String conversationId) {
    if (_route != conversationId) {
      return;
    }
    _route = null;
    _emit();
  }

  @visibleForTesting
  void setForeground({required bool foreground}) {
    if (_foreground == foreground) {
      return;
    }
    _foreground = foreground;
    _emit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setForeground(foreground: state == AppLifecycleState.resumed);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (_observesLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    unawaited(_changes.close());
  }

  void _emit() {
    if (_disposed) {
      return;
    }
    _changes.add(null);
  }
}

/// Marks one conversation read for as long as the user is looking at it.
///
/// The distinction this exists to hold is between a route being *mounted* and a
/// conversation being *read*. Mounting is not reading: a chat route stays in
/// the navigator behind a backgrounded application, and it is built and laid
/// out before the platform has said the application is in front of anybody. A
/// mark-read hung on `initState` therefore fires for messages nobody has seen —
/// the user opens the application and finds them already read.
///
/// So the trigger is [VisibleConversationRegistry.conversationId], which is
/// mounted-and-foregrounded by construction and nothing else, and the marking
/// is re-run rather than fired once: the application returning to the
/// foreground is a read, and so is a message arriving into the conversation on
/// screen. [notify] is what a caller hands the second of those in.
///
/// [markRead] must be a no-op when nothing is unread. Marking is a write, a
/// write is observed, and an observer that calls [notify] back is the ordinary
/// case rather than a strange one; it is the emptiness of the second pass that
/// ends the exchange.
final class VisibleConversationReadMarker {
  VisibleConversationReadMarker({
    required this.registry,
    required this.conversationId,
    required this.markRead,
  });

  final VisibleConversationRegistry registry;
  final String conversationId;

  /// Clears this conversation's unread state. Failure is the caller's to
  /// absorb: nothing here is user-initiated, so there is nobody to tell.
  final Future<void> Function() markRead;

  StreamSubscription<void>? _changes;
  bool _running = false;
  bool _pending = false;
  bool _disposed = false;

  /// Begins following visibility, and evaluates what it already says.
  ///
  /// The initial evaluation is not redundant with the subscription. A route
  /// replacing another one for the same conversation registers a value the
  /// registry already holds, which is correctly not a change and so emits
  /// nothing.
  void start() {
    if (_disposed || _changes != null) {
      return;
    }
    _changes = registry.changes.listen((_) => notify());
    notify();
  }

  /// Re-evaluates visibility, and marks read if this conversation has it.
  void notify() {
    if (_disposed || registry.conversationId != conversationId) {
      return;
    }
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && registry.conversationId == conversationId) {
        _pending = false;
        await markRead();
        if (!_pending) {
          return;
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_changes?.cancel());
    _changes = null;
  }
}

/// Registers the conversation this subtree shows for as long as it is mounted.
class VisibleConversationScope extends StatefulWidget {
  const VisibleConversationScope({
    required this.registry,
    required this.conversationId,
    required this.child,
    super.key,
  });

  final VisibleConversationRegistry registry;
  final String conversationId;
  final Widget child;

  @override
  State<VisibleConversationScope> createState() =>
      _VisibleConversationScopeState();
}

class _VisibleConversationScopeState extends State<VisibleConversationScope> {
  @override
  void initState() {
    super.initState();
    widget.registry.enter(widget.conversationId);
  }

  @override
  void didUpdateWidget(VisibleConversationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        !identical(oldWidget.registry, widget.registry)) {
      oldWidget.registry.leave(oldWidget.conversationId);
      widget.registry.enter(widget.conversationId);
    }
  }

  @override
  void dispose() {
    widget.registry.leave(widget.conversationId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
