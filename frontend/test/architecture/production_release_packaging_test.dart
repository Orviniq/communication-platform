import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one command in `tool/build_production_release.sh` that builds.
const _flutterBuild = r'flutter "${build_arguments[@]}"';

/// The text of [source] from the first [start] up to the first [end] after it.
String _between(String source, String start, String end) {
  final from = source.indexOf(start);
  expect(from, isNot(-1), reason: 'Expected to find `$start`.');
  final to = source.indexOf(end, from + start.length);
  expect(to, isNot(-1), reason: 'Expected to find `$end` after `$start`.');
  return source.substring(from, to);
}

/// Expects every one of [markers] in [source], each before [boundary].
void _expectAllBefore(String source, List<String> markers, String boundary) {
  final end = source.indexOf(boundary);
  expect(end, isNot(-1), reason: 'Expected to find `$boundary`.');
  for (final marker in markers) {
    final at = source.indexOf(marker);
    expect(at, isNot(-1), reason: 'Expected to find `$marker`.');
    expect(at, lessThan(end), reason: '`$marker` must run before `$boundary`.');
  }
}

/// Expects [markers] in [source], in this order.
void _expectInOrder(String source, List<String> markers) {
  var from = 0;
  for (final marker in markers) {
    final at = source.indexOf(marker, from);
    expect(
      at,
      isNot(-1),
      reason: 'Expected to find `$marker` after the markers before it.',
    );
    from = at + marker.length;
  }
}

/// The lines of [source] without their line endings, whatever those are.
List<String> _lines(String source) =>
    source.split('\n').map((line) => line.trimRight()).toList();

void main() {
  late String builder;
  late String renderer;
  late String environment;
  late String verifier;

  setUp(() {
    builder = File('tool/build_production_release.sh').readAsStringSync();
    renderer = File('tool/render_production_trust.sh').readAsStringSync();
    environment = File('tool/release_env.sh').readAsStringSync();
    verifier = File('tool/verify_release_apk.sh').readAsStringSync();
  });

  group('the release script', () {
    test('refuses before it spends any build time', () {
      _expectAllBefore(builder, const [
        r'[[ -n "$production_certificate_sha256" ]] ||',
        '\nrequire_production_provisioning',
        r'if [[ -n "${CP_PRODUCTION_SIGNING_PROPERTIES:-}" ]]; then',
        r'[[ -f "$CP_PRODUCTION_SIGNING_PROPERTIES" ]] ||',
        'refuse_repository_path "The signing properties file"',
        'refuse_repository_path "The production keystore"',
        'fail "No production signing material.',
        r'[[ -z "${CP_PRODUCTION_UNSIGNED_BUILD+set}" ]] ||',
        '\nrequire_jdk',
      ], _flutterBuild);
    });

    test('refuses a build number that does not rise', () {
      _expectAllBefore(builder, const [
        r'[[ "$build_number" =~ ^[1-9][0-9]{0,8}$ ]] ||',
        r'for metadata in "$release_directory"/*.metadata.txt; do',
        r'''recorded="$(awk '/^Version code:/''',
        r'(( build_number > highest_recorded )) ||',
        r'for existing in "$release_directory"/*-"$build_number".apk*; do',
      ], _flutterBuild);
      expect(
        builder,
        contains(
          r'readonly release_directory="$frontend_root/build/production-release"',
        ),
      );
      // The metadata the script publishes carries the line the refusal reads.
      expect(
        builder,
        matches(RegExp(r'^Version code: +\$build_number\r?$', multiLine: true)),
      );
    });

    test('checks the primary pin the live host serves before it builds', () {
      _expectAllBefore(builder, const [
        r'openssl s_client -connect "$live_endpoint"',
        r'[[ "$live_certificate" == *"-----BEGIN CERTIFICATE-----"* ]] ||',
        r'[[ "$live_primary_pin" == "$PRODUCTION_PRIMARY_SPKI_SHA256" ]] ||',
      ], _flutterBuild);
      // A host that cannot be reached, or never answers, stops the build
      // instead of skipping the check.
      expect(
        builder,
        contains(
          r'with_timeout() { timeout "$live_check_timeout_seconds" "$@"; }',
        ),
      );
      expect(builder, contains('fail "Could not read a certificate from'));
    });

    test('renders the trust resources on every build', () {
      const render = r'"$frontend_root/tool/render_production_trust.sh"';
      // A top-level statement, so no condition can skip it.
      expect(_lines(builder), contains(render));
      _expectAllBefore(builder, const [render], _flutterBuild);
    });

    test('builds signed production with every define the app reads', () {
      final arguments = _between(builder, 'build_arguments=(', '\n)');
      for (final argument in const [
        'build apk',
        '--release',
        '--flavor production',
        '--target lib/main_production.dart',
        r'--build-number "$build_number"',
      ]) {
        expect(arguments, contains(argument));
      }

      // Exactly the defines lib/app/config/app_configuration.dart reads for
      // production, so a value the app comes to require cannot be left out.
      final configuration = File(
        'lib/app/config/app_configuration.dart',
      ).readAsStringSync();
      final readByTheApp = RegExp(
        r"String\.fromEnvironment\(\s*'(PRODUCTION_[A-Z0-9_]+)'",
      ).allMatches(configuration).map((match) => match.group(1)).toSet();
      final defined = RegExp(
        r'"--dart-define=(PRODUCTION_[A-Z0-9_]+)=',
      ).allMatches(arguments).map((match) => match.group(1)).toSet();
      expect(readByTheApp, hasLength(5));
      expect(defined, readByTheApp);

      // The script never asks for an unsigned package.
      expect(builder, isNot(contains('CP_PRODUCTION_UNSIGNED_BUILD=1')));
    });

    test('publishes only what the verifier passed', () {
      _expectInOrder(builder, const [
        _flutterBuild,
        r'"$frontend_root/tool/verify_release_apk.sh" --production "$built_apk"',
        r'[[ "$resolved_version_code" == "$build_number" ]] ||',
        r'cp "$built_apk" "$artifact_path"',
        r'cat > "$artifact_path.metadata.txt" <<METADATA',
      ]);
      // apksigner rejects a /c/... JAVA_HOME, and jdk_home is C:/... on Windows.
      _expectInOrder(builder, const [
        r'export JAVA_HOME="$jdk_home"',
        r'"$frontend_root/tool/verify_release_apk.sh" --production "$built_apk"',
      ]);
      expect(
        builder,
        contains(
          'readonly artifact_name='
          r'"communication-platform-$resolved_version_name-$build_number.apk"',
        ),
      );

      final metadata = _between(builder, '<<METADATA', '\nMETADATA');
      for (final field in const [
        'Source revision:',
        'Working tree dirty:',
        'Application ID:',
        'Version name:',
        'Version code:',
        'Signing certificate SHA-256:',
        'APK SHA-256:',
        'Server origin:',
      ]) {
        expect(metadata, contains(field));
      }
      // Pins and CA digests stay out of everything that travels with a build.
      expect(metadata, isNot(contains('SPKI')));
      expect(metadata, isNot(contains('PRIVATE_CA')));
    });
  });

  group('the trust renderer', () {
    test('requires every value, each in the form the app accepts', () {
      expect(renderer, contains('\nrequire_production_provisioning'));

      final names = _between(
        environment,
        'readonly -a production_provisioning_names=(',
        ')',
      );
      for (final name in const [
        'PRODUCTION_SERVER_ORIGIN',
        'PRODUCTION_PRIVATE_CA_SHA256',
        'PRODUCTION_PRIMARY_SPKI_SHA256',
        'PRODUCTION_BACKUP_SPKI_SHA256',
        'PRODUCTION_PRIVATE_CA_PEM',
      ]) {
        expect(names, contains(name));
      }

      final check = _between(
        environment,
        'require_production_provisioning() {',
        '\n}',
      );
      for (final refusal in const [
        r'fail "Missing production provisioning: ${missing[*]}.',
        r'[[ "$PRODUCTION_SERVER_ORIGIN" == https://* && -n "$authority" && '
            r'"$authority" != *[/?#@]* ]] ||',
        r'[[ "$PRODUCTION_PRIMARY_SPKI_SHA256" != '
            r'"$PRODUCTION_BACKUP_SPKI_SHA256" ]] ||',
        r'[[ -f "$PRODUCTION_PRIVATE_CA_PEM" ]] ||',
      ]) {
        expect(check, contains(refusal));
      }

      // The same forms lib/app/config/app_configuration.dart accepts.
      final configuration = File(
        'lib/app/config/app_configuration.dart',
      ).readAsStringSync();
      expect(configuration, contains(r"RegExp(r'^[0-9a-fA-F]{64}$')"));
      expect(
        check,
        contains(
          r'[[ "$PRODUCTION_PRIVATE_CA_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||',
        ),
      );
      expect(configuration, contains(r"RegExp(r'^[A-Za-z0-9+/]{43}=$')"));
      expect(check, contains(r'[[ "${!name}" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||'));
    });

    test('checks the CA against its digest and its expiry before writing', () {
      _expectAllBefore(renderer, const [
        r'[[ "$pem_blocks" == "1" && "$certificate_blocks" == "1" ]] ||',
        r'[[ "$actual_ca_sha256" == "$expected_ca_sha256" ]] ||',
        'fail "The CA certificate does not match PRODUCTION_PRIVATE_CA_SHA256.',
        '-noout -checkend 0',
      ], r'mkdir -p "$production_res/xml" "$production_res/raw"');
    });

    test('refuses a placeholder that survives substitution', () {
      final template = File(
        'android/provisioning/network_security_config.xml.template',
      ).readAsStringSync();
      for (final placeholder in const [
        '@@SERVER_HOST@@',
        '@@PRIMARY_SPKI_SHA256@@',
        '@@BACKUP_SPKI_SHA256@@',
      ]) {
        expect(template, contains(placeholder));
        expect(renderer, contains('sub(/$placeholder/'));
      }
      _expectInOrder(renderer, const [
        r'"$template" > "$rendered_config"',
        r'''if grep -q '@@' "$rendered_config"; then''',
        'unsubstituted placeholder',
        r'cp "$PRODUCTION_PRIVATE_CA_PEM" "$rendered_ca"',
      ]);
    });

    test('writes only resources that git ignores', () {
      for (final path in const [
        r'readonly production_res="$android_root/app/src/production/res"',
        r'readonly rendered_config="$production_res/xml/'
            'network_security_config.xml"',
        r'readonly rendered_ca="$production_res/raw/provisioned_private_ca.pem"',
      ]) {
        expect(renderer, contains(path));
      }
      expect(
        _lines(File('.gitignore').readAsStringSync()),
        containsAll(<String>[
          '/android/app/src/production/res/xml/network_security_config.xml',
          '/android/app/src/production/res/raw/provisioned_private_ca.*',
          // Where the release script publishes.
          '/build/',
        ]),
      );
    });
  });

  group('the verifier', () {
    test('reads the packaged trust config back, in --production only', () {
      final trust = _between(
        verifier,
        '# --- Native trust, read out of the packaged artifact',
        '# --- The deleted beta MLS core stays deleted',
      );
      expect(trust, contains(r'if [[ "$mode" == "production" ]]; then'));
      // Gated once, on the signed mode, so --production-unsigned skips it all.
      expect(RegExp(r'\$mode').allMatches(trust), hasLength(1));

      for (final check in const [
        // Found through the resource table: release file names are obfuscated.
        r'resource_table="$(aapt2 dump resources "$native_apk_path" '
            r'2>/dev/null)" ||',
        "grep -A1 'xml/network_security_config'",
        r'trust_tree="$(aapt2 dump xmltree "$native_apk_path" --file '
            r'"$trust_resource" 2>&1)" ||',
        // A domain-config, pinning the origin's host when that is set.
        r'[[ "$trust_tree" == *"domain-config"* ]] ||',
        r'''[[ "$trust_tree" == *"'$expected_host'"* ]] ||''',
        // At least two pins, and both provisioned pins when those are set.
        r'''pin_count="$(grep -c 'digest="SHA-256"' <<<"$trust_tree" || true)"''',
        r'[[ "$pin_count" -ge 2 ]] ||',
        'for pin_name in PRODUCTION_PRIMARY_SPKI_SHA256 '
            'PRODUCTION_BACKUP_SPKI_SHA256; do',
        r'''[[ "$trust_tree" == *"'$pin_value'"* ]] ||''',
        // Cleartext off everywhere, and the CA packaged as the trust anchor.
        r'[[ "$trust_tree" == *"cleartextTrafficPermitted=false"* &&',
        r'"$trust_tree" != *"cleartextTrafficPermitted=true"* ]] ||',
        r'[[ "$resource_table" == *"raw/provisioned_private_ca"* ]] ||',
      ]) {
        expect(trust, contains(check));
      }
    });
  });
}
