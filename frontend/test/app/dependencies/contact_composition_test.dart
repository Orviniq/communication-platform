import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/contacts/infrastructure/drift_contact_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The authentication service the application composes reads peers from the
/// server itself.
///
/// `send_rechecks_peer_state_test.dart` proves that the service asks the port
/// it is given before every send. This is the other half: the port it is given
/// in the running application is the network repository, with nothing between
/// that could answer from memory.
void main() {
  test('the peer reads go straight to the network repository', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final container = ProviderContainer(
      overrides: [
        authenticatedRestClientProvider.overrideWithValue(
          DioRestClient(serverOrigin: Uri.parse('https://chat.example.test')),
        ),
        serverConfigSnapshotProvider.overrideWithValue(
          const FixedServerConfig.fallback(),
        ),
        contactLocalProvider.overrideWith(
          (ref) => DriftContactRepository(database),
        ),
        identityCryptoProvider.overrideWithValue(
          const UnsupportedIdentityCrypto(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final service = await container.read(
      peerAuthenticationServiceProvider.future,
    );

    expect(
      service.remote,
      same(container.read(contactRemoteProvider)),
      reason: 'a send verifies the state the server holds when it is made',
    );
  });
}
