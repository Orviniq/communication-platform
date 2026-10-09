import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one file that opens a sheet.
///
/// `showAppSheet` and `showAppAnchoredSheet` carry the rule that keeps a sheet's
/// controls out of the status bar, the gesture bar and the keyboard
/// (`responsive-ui.md`, Adaptive shell). A sheet opened any other way gets none
/// of it, and its last button ends up under the gesture bar.
const _opener = 'lib/app/design_system/components/app_modals.dart';

/// What opens a sheet, or a surface that stands in for one: Material's two,
/// Forui's, and the general dialog route that `showAppAnchoredSheet` is built on.
final _sheetFunction = RegExp(
  r'\b(showModalBottomSheet|showBottomSheet|showFSheet|showGeneralDialog)\b',
);

/// The files among [sources] (path to source) that name a sheet function in
/// code, outside [_opener].
///
/// Naming is enough, not only calling: `final open = showFSheet;` is a call
/// waiting to happen. A comment that mentions one is not code, so it is not a
/// violation.
List<String> sheetViolations(
  Map<String, String> sources, {
  bool exemptOpener = true,
}) => [
  for (final MapEntry(key: path, value: source) in sources.entries)
    if (!(exemptOpener && path == _opener) &&
        _sheetFunction.hasMatch(_withoutComments(source)))
      path,
];

/// [source] with its comments blanked: block comments, and line comments
/// (documentation included) from the first `//` that is not inside a string.
String _withoutComments(String source) {
  final lines = <String>[];
  for (final line
      in source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '').split('\n')) {
    String? quote;
    var end = line.length;
    for (var index = 0; index < line.length; index += 1) {
      final character = line[index];
      if (quote != null) {
        if (character == r'\') {
          index += 1;
        } else if (character == quote) {
          quote = null;
        }
      } else if (character == "'" || character == '"') {
        quote = character;
      } else if (character == '/' &&
          index + 1 < line.length &&
          line[index + 1] == '/') {
        end = index;
        break;
      }
    }
    lines.add(line.substring(0, end));
  }
  return lines.join('\n');
}

Map<String, String> _libSources() => {
  for (final entry in Directory('lib').listSync(recursive: true))
    if (entry is File && entry.path.endsWith('.dart'))
      entry.path.replaceAll('\\', '/'): entry.readAsStringSync(),
};

void main() {
  group('the guard', () {
    test('finds each way into a sheet outside the opener', () {
      for (final name in [
        'showModalBottomSheet',
        'showBottomSheet',
        'showFSheet',
        'showGeneralDialog',
      ]) {
        expect(
          sheetViolations({
            'lib/features/x.dart': 'await $name<void>(context: context);',
          }),
          ['lib/features/x.dart'],
          reason: name,
        );
      }
      // Scaffold's own, reached through a `ScaffoldState`; and a tear-off.
      expect(
        sheetViolations({
          'lib/a.dart': 'Scaffold.of(context).showBottomSheet(builder);',
          'lib/b.dart': 'final open = showFSheet;',
        }),
        ['lib/a.dart', 'lib/b.dart'],
      );
    });

    test('lets a comment name a sheet function, and a longer name stand', () {
      expect(
        sheetViolations({
          'lib/a.dart':
              '/// Unlike showModalBottomSheet, this one scrolls.\n'
              '// showFSheet is behind showAppSheet.\n'
              '/* showGeneralDialog\n   showBottomSheet */\n'
              'final a = 1; // showModalBottomSheet\n',
          'lib/b.dart':
              'showAppSheet(); showAppAnchoredSheet(); showFDialog();',
        }),
        isEmpty,
      );
    });

    test('is not fooled by a // inside a string before the call', () {
      expect(
        sheetViolations({
          'lib/a.dart': "link('https://x.test'); showFSheet(context: c);",
        }),
        ['lib/a.dart'],
      );
    });

    test('exempts the opener, and only the opener', () {
      final sources = {
        _opener: 'showFSheet(); showGeneralDialog();',
        'lib/app/design_system/components/other.dart': 'showFSheet();',
      };
      expect(sheetViolations(sources), [
        'lib/app/design_system/components/other.dart',
      ]);
      expect(sheetViolations(sources, exemptOpener: false), [
        _opener,
        'lib/app/design_system/components/other.dart',
      ]);
    });
  });

  group('the tree', () {
    test('only app_modals.dart opens a sheet', () {
      final violations = sheetViolations(_libSources());
      expect(
        violations,
        isEmpty,
        reason:
            'Open a sheet with showAppSheet or showAppAnchoredSheet: they '
            'keep its controls out of the system insets and the keyboard.\n'
            '${violations.join('\n')}',
      );
    });

    test('the scan reads the real tree, and sees the opener there', () {
      // Without the exemption the opener is found, which shows the guard is
      // looking at the sources and not at nothing.
      expect(
        sheetViolations(_libSources(), exemptOpener: false),
        contains(_opener),
      );
    });
  });
}
