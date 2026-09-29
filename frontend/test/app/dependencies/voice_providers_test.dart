import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/voice_providers.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/voice/support/relay_fakes.dart';

/// The composed service asks the limits in force whether this deployment
/// serves voice, mints through the authenticated client, and counts on the
/// application clock.
void main() {
  final t0 = DateTime.utc(2026, 9, 30, 12);

  ProviderContainer containerOn(
    RelayAdapter adapter,
    ServerConfigSnapshot limits,
  ) {
    final container = ProviderContainer(
      overrides: [
        authenticatedRestClientProvider.overrideWithValue(
          relayRestClient(adapter),
        ),
        serverConfigSnapshotProvider.overrideWithValue(limits),
        timeSourceProvider.overrideWithValue(MutableClock(t0)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the fallback limits offer no voice, and nothing is asked', () async {
    final adapter = RelayAdapter([relayJson(200, relayBody())]);
    final service = containerOn(
      adapter,
      const FixedServerConfig.fallback(),
    ).read(relayCredentialServiceProvider);

    expect(service.isVoiceAvailable, isFalse);
    expect(await service.fetchForJoin(), isA<VoiceUnavailable>());
    expect(adapter.requests, isEmpty);
  });

  test('a deployment that serves voice gets one mint at a join', () async {
    final adapter = RelayAdapter([relayJson(200, relayBody())]);
    final service = containerOn(
      adapter,
      FixedServerConfig(withVoice(ServerConfig.fallback)),
    ).read(relayCredentialServiceProvider);

    final joined = await service.fetchForJoin();

    expect(
      (joined as RelayCredentialMinted).credential.expiresAt,
      t0.add(const Duration(hours: 6)),
    );
    expect(adapter.requests.single.path, '/api/v1/me/relay');
  });
}
