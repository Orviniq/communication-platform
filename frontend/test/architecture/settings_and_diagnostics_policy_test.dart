import 'dart:io';

import 'package:communication_platform/app/config/build_identity.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules the settings surface set and the diagnostics export rest on, in
/// the file a reviewer reads.
///
/// Two of them cannot be expressed in the type system and are therefore
/// asserted here instead: that the one constructor able to carry a string into
/// an export is called from an enumerated set of places, all of them passing
/// compile-time constants; and that nothing in the diagnostics feature can
/// reach a network at all.
void main() {
  group('what a diagnostics export is allowed to be built from', () {
    test('the only string-taking constructor has an enumerated call set', () {
      // `DiagnosticValue.constant` is documented as taking a compile-time
      // constant declared in this repository. The type system cannot enforce
      // that, so the call sites are enumerated: a third one has to be added
      // here, deliberately, where the decision to put something new in an
      // exportable document is visible.
      final callSites = <String, int>{};
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) {
          continue;
        }
        final count = 'DiagnosticValue.constant('
            .allMatches(entry.readAsStringSync())
            .length;
        if (count > 0) {
          callSites[entry.path.replaceAll(r'\', '/')] = count;
        }
      }
      expect(callSites, {
        // The declaration itself.
        'lib/features/diagnostics/domain/diagnostics_report.dart': 1,
        // The report format's own generation stamp, derived from the clock.
        'lib/features/diagnostics/application/collect_diagnostics.dart': 1,
        // The packaged version and the platform word, both compile-time.
        'lib/app/dependencies/diagnostics.dart': 2,
      });
    });

    test('the report domain depends on nothing that could transmit', () {
      // A pure value type. If it ever imported a client, a store or a
      // platform channel, "this cannot leave the device" would stop being a
      // property of the type and become a property of who calls it.
      final source = File(
        'lib/features/diagnostics/domain/diagnostics_report.dart',
      ).readAsStringSync();
      expect(RegExp(r"^import ", multiLine: true).hasMatch(source), isFalse);
    });

    test('nothing in the diagnostics feature reaches a network', () {
      const forbidden = [
        'package:dio/',
        'dart:io',
        'HttpClient',
        'DioRestClient',
        'WebSocket',
        'Uri.parse',
        'serverOrigin',
      ];
      for (final entry in Directory(
        'lib/features/diagnostics',
      ).listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) {
          continue;
        }
        final source = entry.readAsStringSync();
        for (final fragment in forbidden) {
          expect(
            source.contains(fragment),
            isFalse,
            reason: '${entry.path} mentions $fragment',
          );
        }
      }
    });

    test('the report format version moves with the field set', () {
      // A reader of an old paste has to be able to tell what they have. The
      // count is pinned so that adding, removing or redefining a field is a
      // deliberate edit here as well as there.
      expect(DiagnosticsReport.formatVersion, 2);
      expect(DiagnosticField.values, hasLength(29));
    });
  });

  group('what the application says about itself', () {
    test('the declared version is the packaged one', () {
      final declared = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync());
      expect(declared, isNotNull);
      expect(BuildIdentity.version, declared!.group(1));
    });
  });

  group('the settings surfaces', () {
    final router = File('lib/app/routing/app_router.dart').readAsStringSync();

    test('no route under Settings resolves to an unbuilt placeholder', () {
      // Every row Settings offers now has a screen behind it. A placeholder
      // reachable from here would be a destination the list advertises and
      // does not have.
      final settingsBranch = router.substring(
        router.indexOf("path: '/settings'"),
      );
      expect(settingsBranch, isNot(contains('StructuralPlaceholderPage')));
      for (final path in const [
        "path: 'appearance'",
        "path: 'profile'",
        "path: 'linked-devices'",
        "path: 'receiving-while-closed'",
        "path: 'security'",
        "path: 'recovery'",
        "path: 'safety-numbers'",
        "path: 'about'",
        "path: 'diagnostics'",
      ]) {
        expect(settingsBranch, contains(path), reason: '$path is not routed');
      }
    });

    test('the recovery screen is the only one that shows a secret, and it '
        'blocks capture', () {
      final rotation = File(
        'lib/features/settings/presentation/recovery_rotation_page.dart',
      ).readAsStringSync();
      // Both required controls from the threat model: screenshots blocked on a
      // screen that exposes a recovery secret, and a clipboard copy that
      // expires.
      expect(rotation, contains('control.setEnabled(true)'));
      expect(rotation, contains('control.setEnabled(false)'));
      expect(rotation, contains('control.copyText('));
      // The ordinary clipboard, which never clears, is not used here.
      expect(rotation, isNot(contains('Clipboard.setData')));
    });

    test('the appearance preference is stored where the wipe reaches it', () {
      final store = File(
        'lib/features/settings/infrastructure/'
        'drift_appearance_preference_store.dart',
      ).readAsStringSync();
      // The encrypted preference table, behind the Keystore-wrapped database
      // key, rather than a plain file or a shared preference that would
      // outlive a logout wipe.
      expect(store, contains('database.localPreferences'));
      expect(store, isNot(contains('SharedPreferences')));
      expect(store, isNot(contains('File(')));
    });
  });
}
