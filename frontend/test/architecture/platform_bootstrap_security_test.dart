import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android release baseline disables cleartext and user-CA trust', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final baseline = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:usesCleartextTraffic="false"'));
    expect(
      manifest,
      contains('android:networkSecurityConfig="@xml/network_security_config"'),
    );
    expect(baseline, contains('cleartextTrafficPermitted="false"'));
    expect(baseline, isNot(contains('<certificates src="user"')));
  });

  test('Android provisioning template requires a private CA and two pins', () {
    final template = File(
      'android/provisioning/network_security_config.xml.template',
    ).readAsStringSync();

    expect(template, contains('@raw/provisioned_private_ca'));
    expect(template, contains('@@SERVER_HOST@@'));
    expect(template, contains('@@PRIMARY_SPKI_SHA256@@'));
    expect(template, contains('@@BACKUP_SPKI_SHA256@@'));
    expect(
      RegExp(r'<pin digest="SHA-256">').allMatches(template),
      hasLength(2),
    );
    expect(template, isNot(contains('src="user"')));
  });

  test('the app transport trusts only the provisioned authority', () {
    final native = File(
      'lib/features/networking/infrastructure/tls/transport_security_native.dart',
    ).readAsStringSync();

    // Removing the built-in roots is what makes this trust exclusive. Without
    // it the provisioned authority would merely be added to every public one.
    expect(native, contains('withTrustedRoots: false'));
    expect(native, contains('setTrustedCertificatesBytes'));

    // The one callback that could defeat every check above must be a constant
    // refusal. Any path returning true here accepts arbitrary certificates.
    expect(
      native,
      contains('badCertificateCallback = (certificate, host, port) => false'),
    );
    expect(native, isNot(contains('=> true')));
  });

  test('no global TLS override or certificate bypass exists', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final source = entity.readAsStringSync();
      // HttpOverrides would replace the client for the whole isolate and
      // silently discard the provisioned context.
      if (source.contains('HttpOverrides')) {
        offenders.add('${entity.path}: HttpOverrides');
      }
      if (RegExp(
        r'badCertificateCallback\s*=\s*\(?[^)]*\)?\s*=>\s*true',
      ).hasMatch(source)) {
        offenders.add('${entity.path}: accepts bad certificates');
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('both transports receive the same provisioned trust', () {
    final rest = File(
      'lib/features/networking/infrastructure/api/dio_rest_client.dart',
    ).readAsStringSync();
    final socket = File(
      'lib/features/networking/infrastructure/realtime/'
      'platform_socket_connector_native.dart',
    ).readAsStringSync();
    final foundation = File(
      'lib/app/dependencies/networking_foundation.dart',
    ).readAsStringSync();

    // REST and WebSocket both run on dart:io; trusting the authority on only
    // one of them would leave the other on the public root store.
    expect(rest, contains('transportSecurity.httpClientAdapter'));
    expect(socket, contains('customClient:'));
    expect(foundation, contains('transportSecurity.socketConnector'));
  });
}
