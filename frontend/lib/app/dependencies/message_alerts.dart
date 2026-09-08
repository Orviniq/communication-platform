import 'dart:async';

import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/features/notifications/application/ports/message_alert_ports.dart';
import 'package:communication_platform/features/notifications/application/reconcile_message_alerts.dart';
import 'package:communication_platform/features/notifications/domain/message_alert_model.dart';
import 'package:communication_platform/features/notifications/infrastructure/drift_message_alert_store.dart';
import 'package:communication_platform/features/notifications/infrastructure/platform_message_alert_presenter.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The alert text, in the locale the application itself is running in.
///
/// Resolved through Flutter's own supported-locale resolution rather than left
/// to Android string resources, so that one catalogue is reviewed, one
/// catalogue is translated, and the shade can never speak a different language
/// from the screen behind it.
Future<MessageAlertStrings> resolveMessageAlertStrings() async {
  final locale = basicLocaleListResolution(
    WidgetsBinding.instance.platformDispatcher.locales,
    AppLocalizations.supportedLocales,
  );
  final l10n = await AppLocalizations.delegate.load(locale);
  return MessageAlertStrings(
    channelName: l10n.notificationsChannelName,
    channelDescription: l10n.notificationsChannelDescription,
    oneMessage: l10n.notificationsNewMessage,
    manyMessages: l10n.notificationsNewMessages,
  );
}

/// How the application reaches the operating system notification surface.
/// Overridden by tests, which have no platform channel.
final messageAlertPresenterProvider = Provider<MessageAlertPresenterPort>(
  (ref) =>
      const PlatformMessageAlertPresenter(strings: resolveMessageAlertStrings),
);

/// What the alert path is doing, as application state.
enum MessageAlertStage {
  /// No session is signed in far enough to hold local messages.
  idle,

  /// Durable state is observed and the shade is kept in agreement with it.
  reconciling,

  /// The path could not be composed for this session, most plausibly because
  /// protected storage is unavailable. Nothing is posted and nothing pretends
  /// otherwise.
  unavailable,
}

/// Keeps the one system alert in agreement with committed local state, for the
/// life of the signed-in session.
///
/// It is owned by the application root for the same reason delivery is: a
/// subscription created inside a widget build is paused by Riverpod when that
/// widget leaves the view, and an alert path that stopped reconciling whenever
/// a route covered the screen would be wrong at exactly the moment alerts
/// matter.
///
/// It is deliberately not part of the delivery session. A session that fails to
/// compose still leaves unalerted messages in the database from before it, and
/// those are still the user's to be told about.
final messageAlertControllerProvider =
    NotifierProvider<MessageAlertController, MessageAlertStage>(
      MessageAlertController.new,
    );

final class MessageAlertController extends Notifier<MessageAlertStage> {
  Future<void> _transitions = Future<void>.value();

  /// Held as a list, not as two named fields, because they share one lifetime:
  /// a session either observes both signals or neither.
  final List<StreamSubscription<Object?>> _signals = [];
  ReconcileMessageAlerts? _reconciler;
  String? _startedUserId;
  String? _wantedUserId;
  bool _closed = false;
  bool _running = false;
  bool _dirty = false;

  /// A previous process may have left an alert in the shade that this one knows
  /// nothing about. Starting from "possibly posted" is what lets the first pass
  /// withdraw one whose messages were read on another device meanwhile.
  bool _alertPosted = true;

  /// The transition queue, so a test can await composition instead of pumping
  /// for it.
  @visibleForTesting
  Future<void> get settled => _transitions;

  /// The last pass conclusion, for tests and for the Settings surface.
  @visibleForTesting
  MessageAlertOutcome lastOutcome = MessageAlertOutcome.idle;

  @override
  MessageAlertStage build() {
    ref.onDispose(() {
      _closed = true;
      unawaited(_stop());
    });
    ref.listen(
      authenticationControllerProvider,
      (previous, next) => _enqueue(next),
      fireImmediately: true,
    );
    return MessageAlertStage.idle;
  }

  void _enqueue(AuthenticationViewState view) {
    final userId = _alertableUserId(view);
    _wantedUserId = userId;
    _transitions = _transitions.then((_) => _apply(userId));
  }

  /// Alerts belong to a device-bound full session and stop the moment a
  /// teardown begins: `TokenCoordinator.logout` wipes protected storage and
  /// closes the database before it emits the termination a completion-triggered
  /// stop would wait for. An account erasure ends in that same wipe, so it is
  /// the same stop and not a second one.
  String? _alertableUserId(AuthenticationViewState view) {
    if (view.isTearingDown) {
      return null;
    }
    return switch (view.access) {
      AuthenticationRouteAccess.fullScope ||
      AuthenticationRouteAccess.offlineFullScope => view.userId,
      _ => null,
    };
  }

  Future<void> _apply(String? userId) async {
    if (_closed) {
      return;
    }
    if (userId == null) {
      await _stop();
      return;
    }
    if (_reconciler != null && _startedUserId == userId) {
      return;
    }
    await _stop();
    await _start(userId);
  }

  Future<void> _start(String userId) async {
    try {
      final database = await ref.read(localDatabaseProvider.future);
      if (_closed || _wantedUserId != userId) {
        return;
      }
      final store = DriftMessageAlertStore(database);
      final visible = _VisibleConversationAdapter(
        ref.read(visibleConversationProvider),
      );
      _reconciler = ReconcileMessageAlerts(
        store: store,
        presenter: ref.read(messageAlertPresenterProvider),
        visible: visible,
        clock: ref.read(timeSourceProvider),
      );
      _startedUserId = userId;
      _signals
        ..add(store.changes.listen((_) => _schedule()))
        ..add(visible.changes.listen((_) => _schedule()));
      _setStage(MessageAlertStage.reconciling);
      _schedule();
    } on Object {
      // Storage is unavailable. Durable state is untouched, no marker is spent,
      // and the next session that composes successfully alerts for whatever is
      // still unread and unalerted.
      await _stop();
      _setStage(MessageAlertStage.unavailable);
    }
  }

  Future<void> _stop() async {
    final signals = List<StreamSubscription<Object?>>.of(_signals);
    _signals.clear();
    _reconciler = null;
    _startedUserId = null;
    _dirty = false;
    for (final signal in signals) {
      await signal.cancel();
    }
    _setStage(MessageAlertStage.idle);
  }

  /// Coalesces bursts. A drain commits envelopes one at a time, so a single
  /// arrival wave produces many signals; running one pass at a time behind a
  /// dirty flag collapses them, and a pass that spends every fresh marker
  /// leaves the follow-up pass with nothing left to alert about.
  void _schedule() {
    if (_running) {
      _dirty = true;
      return;
    }
    _running = true;
    _transitions = _transitions.then((_) => _drain());
  }

  Future<void> _drain() async {
    try {
      do {
        _dirty = false;
        final reconciler = _reconciler;
        if (reconciler == null || _closed) {
          return;
        }
        final outcome = await reconciler.call(alertPosted: _alertPosted);
        lastOutcome = outcome;
        if (outcome.shown) {
          _alertPosted = true;
        } else if (outcome.hidden) {
          _alertPosted = false;
        }
      } while (_dirty);
    } finally {
      _running = false;
    }
  }

  void _setStage(MessageAlertStage stage) {
    if (!_closed) {
      state = stage;
    }
  }
}

/// Adapts the messaging feature on-screen state to the port the notification
/// use case declares, so neither feature has to import the other.
final class _VisibleConversationAdapter implements VisibleConversationPort {
  const _VisibleConversationAdapter(this._registry);

  final VisibleConversationRegistry _registry;

  @override
  String? get conversationId => _registry.conversationId;

  @override
  bool get isForeground => _registry.isForeground;

  @override
  Stream<void> get changes => _registry.changes;
}
