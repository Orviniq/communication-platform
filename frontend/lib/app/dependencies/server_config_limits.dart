import 'dart:async';

import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/drift_server_config_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The limits in force, and the durable row they come from.
///
/// Separate from `server_config_providers.dart`, which owns the *read* of
/// `GET /api/v1/config`, because almost everything that needs a limit does not
/// need the read: a transport, a store and a screen all want the number that is
/// in force now, and the read needs the authenticated REST client, which is
/// composed alongside the transports that would then be importing it back.

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

/// The limits in force, readable synchronously by everything that measures
/// against one.
///
/// A separate provider from [serverConfigProvider] because the readers are not
/// widgets: a socket frame is validated as it arrives and a response inside a
/// `decode` callback, neither of which can await anything. It follows the same
/// durable row, so the value moves without the socket or the delivery engine
/// being rebuilt around it.
///
/// It answers before the store has opened, and keeps answering if the store
/// never opens, because the fallback is a complete configuration rather than an
/// absence.
final serverConfigSnapshotProvider = Provider<ServerConfigSnapshot>((ref) {
  final follower = LatestServerConfig(
    // Not `serverConfigProvider`: an `AsyncValue` would have to be unwrapped on
    // every read, and its loading state has no answer to give. The store's own
    // stream has one from its first event.
    Stream.fromFuture(
      ref.watch(serverConfigStoreProvider.future),
    ).asyncExpand((store) => store.watch()),
  );
  ref.onDispose(follower.close);
  return follower;
});
