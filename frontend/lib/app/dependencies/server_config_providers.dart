import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/application/read_published_configuration.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/dio_server_config_repository.dart';
import 'package:communication_platform/features/server_config/infrastructure/drift_server_config_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final serverConfigReadPortProvider = Provider<ServerConfigReadPort>(
  (ref) =>
      DioServerConfigRepository(ref.watch(authenticatedRestClientProvider)),
);

final serverConfigStoreProvider = FutureProvider<ServerConfigStore>((
  ref,
) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftServerConfigStore(database);
});

/// The limits in force: the operator's once they have been read, and the
/// client's own constants until then.
///
/// It is a projection of the durable row rather than a value the fetch hands
/// out, so a session that started with no network picks the answer up the
/// moment it arrives, and every reader sees the same one.
final serverConfigProvider = StreamProvider<ServerConfig>((ref) async* {
  final store = await ref.watch(serverConfigStoreProvider.future);
  yield* store.watch();
});

/// What the configuration read is doing, as application state.
enum ServerConfigStage {
  /// No session has reached full scope, so the route cannot be called.
  idle,

  /// The call is in flight. Nothing is waiting for it.
  reading,

  /// The deployment's limits are stored.
  published,

  /// The call did not answer. The client keeps what it already held, which is
  /// the last stored answer or its own constants.
  unavailable,
}

/// Reads `GET /api/v1/config` once, when the client reaches full scope.
///
/// Owned by the application root and not by a screen, for the same reason
/// delivery and alerts are: a subscription created inside a widget build is
/// paused by Riverpod when that widget leaves the view, and a read that had not
/// happened yet would then never happen.
///
/// Nothing blocks on it. The application is already running on stored or
/// fallback limits by the time this starts, so the read is a correction rather
/// than a precondition — which is what keeps the client startable offline.
///
/// One attempt per signed-in session, in either direction. The route counts
/// against the `accounts` rate limit like every other full-scope route and its
/// values change only when the operator restarts the server, so a retry loop
/// would spend an account's budget on numbers the server is enforcing anyway.
final serverConfigControllerProvider =
    NotifierProvider<ServerConfigController, ServerConfigStage>(
      ServerConfigController.new,
    );

final class ServerConfigController extends Notifier<ServerConfigStage> {
  Future<void> _transitions = Future<void>.value();
  String? _attemptedUserId;
  bool _closed = false;

  /// The transition queue, so a test can await the read instead of pumping for
  /// it.
  @visibleForTesting
  Future<void> get settled => _transitions;

  @override
  ServerConfigStage build() {
    ref.onDispose(() => _closed = true);
    ref.listen(
      authenticationControllerProvider,
      (previous, next) => _enqueue(next),
      fireImmediately: true,
    );
    return ServerConfigStage.idle;
  }

  void _enqueue(AuthenticationViewState view) {
    _transitions = _transitions.then((_) => _apply(_readableUserId(view)));
  }

  /// The route takes a full-scope token, so a register-scope session cannot
  /// reach it and an offline one has nothing to reach. A teardown ends the
  /// session before the answer could be stored, and the wipe it runs would
  /// destroy the row anyway.
  String? _readableUserId(AuthenticationViewState view) {
    if (view.isTearingDown) {
      return null;
    }
    return view.access == AuthenticationRouteAccess.fullScope
        ? view.userId
        : null;
  }

  Future<void> _apply(String? userId) async {
    if (_closed || userId == null || _attemptedUserId == userId) {
      return;
    }
    _attemptedUserId = userId;
    _setStage(ServerConfigStage.reading);
    try {
      final store = await ref.read(serverConfigStoreProvider.future);
      if (_closed) {
        return;
      }
      final read = await ReadPublishedConfiguration(
        remote: ref.read(serverConfigReadPortProvider),
        store: store,
      ).refresh();
      // A read that did not land leaves the previous answer in force, which is
      // what `watch` was already handing out. The honest report is that this
      // read did not land, not that the limits are wrong.
      _setStage(
        read.stored
            ? ServerConfigStage.published
            : ServerConfigStage.unavailable,
      );
    } on Object {
      // Most plausibly protected storage: the database could not be opened, so
      // there is nowhere to keep an answer. Nothing durable is lost and the
      // client runs on its own constants.
      _setStage(ServerConfigStage.unavailable);
    }
  }

  void _setStage(ServerConfigStage stage) {
    if (!_closed) {
      state = stage;
    }
  }
}
