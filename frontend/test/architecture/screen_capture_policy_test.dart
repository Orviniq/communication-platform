import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app blocks screen capture everywhere, in every build (ADR-092).
///
/// `FLAG_SECURE` is a window flag, so the guarantee is a property of the
/// activity's Kotlin source and is asserted there: set before the first frame,
/// and cleared by nothing.
void main() {
  const kotlinRoot = 'android/app/src/main/kotlin';
  const activity =
      '$kotlinRoot/com/example/communication_platform/MainActivity.kt';

  String source(File file) => file.readAsStringSync().replaceAll('\r\n', '\n');

  List<File> kotlinSources() => [
    for (final entry in Directory(kotlinRoot).listSync(recursive: true))
      if (entry is File && entry.path.endsWith('.kt')) entry,
  ];

  test('the activity adds FLAG_SECURE in onCreate, before the first frame', () {
    final text = source(File(activity));
    final start = text.indexOf('override fun onCreate(');
    expect(start, isNonNegative, reason: 'MainActivity overrides onCreate');
    final superCall = text.indexOf('super.onCreate(', start);
    expect(superCall, greaterThan(start));

    final before = text.substring(start, superCall);
    expect(
      RegExp(
        r'window\.addFlags\(\s*WindowManager\.LayoutParams\.FLAG_SECURE\s*\)',
      ).hasMatch(before),
      isTrue,
      reason: 'FLAG_SECURE is added before super.onCreate runs',
    );
  });

  test('no Kotlin source clears FLAG_SECURE', () {
    final sources = kotlinSources();
    expect(sources, isNotEmpty);
    for (final file in sources) {
      final text = source(file);
      expect(
        RegExp(r'clearFlags\s*\([^)]*FLAG_SECURE').hasMatch(text),
        isFalse,
        reason: '${file.path} clears FLAG_SECURE',
      );
      // `setFlags(0, mask)` clears a flag without naming `clearFlags`.
      expect(
        RegExp(r'setFlags\s*\([^;]*FLAG_SECURE').hasMatch(text),
        isFalse,
        reason: '${file.path} sets the flags in a way that can drop it',
      );
    }
  });

  test('FLAG_SECURE appears only in addFlags calls', () {
    var occurrences = 0;
    for (final file in kotlinSources()) {
      final text = source(file);
      for (final match in RegExp('FLAG_SECURE').allMatches(text)) {
        occurrences++;
        final line = text.substring(
          text.lastIndexOf('\n', match.start) + 1,
          match.end,
        );
        final isComment = line.trimLeft().startsWith('//');
        final isAdd = RegExp(r'addFlags\(\s*(WindowManager\.LayoutParams\.)?')
            .hasMatch(
              text.substring(
                (match.start - 80).clamp(0, match.start),
                match.start,
              ),
            );
        expect(
          isComment || isAdd,
          isTrue,
          reason: '${file.path}: FLAG_SECURE outside addFlags: $line',
        );
      }
    }
    expect(occurrences, greaterThanOrEqualTo(2));
  });

  test('the sensitive-screen channel method keeps the flag on', () {
    final text = source(File(activity));
    final start = text.indexOf('"setSensitiveScreen" ->');
    expect(start, isNonNegative);
    final end = text.indexOf('"copySensitiveText" ->', start);
    final body = text.substring(start, end);
    expect(body, contains('FLAG_SECURE'));
    expect(body, isNot(contains('clearFlags')));
    expect(body, isNot(contains('else')));
  });
}
