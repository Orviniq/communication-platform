import 'dart:io';

import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The boundaries of the attachment feature (ADR-089), read from the sources.
///
/// Presentation draws and asks: it reaches no transport, no database, no file
/// and no platform channel. One adapter names the channel, one composition
/// root builds the transport, the group chat keeps its "not built" sheet, and
/// nothing the phase added writes a log.
void main() {
  group('the attachment presentation', () {
    final files = _dartFiles('lib/features/attachments/presentation');

    test('imports no transport, no database, no platform services and no '
        'infrastructure', () {
      expect(files, isNotEmpty);
      final violations = <String>[];
      for (final file in files) {
        for (final uri in _imports(file)) {
          if (uri.startsWith('package:dio/') ||
              uri.startsWith('package:drift/') ||
              uri.startsWith('package:drift_flutter/') ||
              uri == 'package:flutter/services.dart' ||
              uri.contains('/infrastructure/')) {
            violations.add('${file.path}: $uri');
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('takes from dart:io a file handle and no file access', () {
      // `Image.file` draws a picture from its file, so a view model may carry
      // one; reading, writing or listing it is infrastructure's work.
      final directive = RegExp(
        r"^\s*import\s+'dart:io'([^;]*);",
        multiLine: true,
      );
      final access = RegExp(
        r'\.(readAs\w+|writeAs\w+|open|openSync|openRead|openWrite|'
        r'(create|delete|rename|copy|exists|length|stat|list|lastModified|'
        r'setLastModified|resolveSymbolicLinks)(Sync)?)\(',
      );
      final violations = <String>[];
      for (final file in files) {
        final source = file.readAsStringSync();
        for (final match in directive.allMatches(source)) {
          if (match.group(1)!.trim() != 'show File') {
            violations.add('${file.path}: dart:io${match.group(1)}');
          }
        }
        if (!directive.hasMatch(source)) {
          continue;
        }
        for (final call in access.allMatches(_code(source))) {
          violations.add('${file.path}: ${call.group(0)}');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  test('the platform adapter names the channel, and the private storage '
      'reaches it through the adapter only', () {
    const channel = 'communication_platform/attachments';
    expect(MethodChannelAttachmentPlatform.channelName, channel);
    final naming = <String>[];
    for (final file in _dartFiles('lib')) {
      final source = file.readAsStringSync();
      if (source.contains(channel) ||
          source.contains('MethodChannelAttachmentPlatform.channelName')) {
        naming.add(_path(file));
      }
    }
    naming.sort();
    expect(naming, [
      'lib/features/attachments/infrastructure/attachment_storage.dart',
      'lib/features/attachments/infrastructure/method_channel_attachment_platform.dart',
    ]);
  });

  test('only the networking foundation builds the attachment transport', () {
    final construction = RegExp(r'\bDioAttachmentTransport(\s*\(|\.new\b)');
    final builders = <String, int>{};
    for (final file in _dartFiles('lib')) {
      final count = construction
          .allMatches(_code(file.readAsStringSync()))
          .length;
      if (count > 0) {
        builders[_path(file)] = count;
      }
    }
    expect(builders, {
      // The constructor's own declaration.
      'lib/features/attachments/infrastructure/attachment_transport.dart': 1,
      'lib/app/dependencies/networking_foundation.dart': 1,
    });
  });

  test('the group chat keeps the sheet that says attachments are not built '
      '(ADR-089 D1, D13)', () {
    final sheet = _code(
      File(
        'lib/features/attachments/presentation/attachment_sheet.dart',
      ).readAsStringSync(),
    );
    expect(sheet, contains('const AttachmentSheet.notBuilt('));
    expect(
      sheet,
      matches(
        RegExp(
          r'mode == AttachmentSheetMode\.notBuilt\s*\?\s*'
          r'strings\.attachmentsNotBuiltNotice',
        ),
      ),
    );
    expect(sheet, contains('SurfaceMaturity.notBuilt'));
    final group = _code(
      File(
        'lib/features/groups/presentation/group_chat_page.dart',
      ).readAsStringSync(),
    );
    expect(group, contains('const AttachmentSheet.notBuilt()'));
    expect(group, contains('ChatAttachmentAvailability.notBuilt'));
    expect(group, isNot(contains('AttachmentSheet.choose')));
  });

  test('nothing the phase added writes a log', () {
    // ADR-089 D14: no capability, key, name, path, URI, type, size or
    // content, and the simplest way to keep that is to log nothing at all.
    final sources = [
      ..._dartFiles('lib/features/attachments'),
      for (final path in const [
        'lib/app/dependencies/attachment_providers.dart',
        'lib/app/design_system/components/app_scalar_limit.dart',
        'lib/features/local_storage/infrastructure/database/stored_attachment_descriptor.dart',
        'lib/features/messaging/application/ports/attachment_sweep_port.dart',
        'lib/features/messaging/presentation/chat_attachment_tiles.dart',
      ])
        File(path),
    ];
    final logging = RegExp(
      r'(?<![\w.$])(print|log)\s*\(|\bdebugPrint\w*\s*\(|'
      r'\bdeveloper\s*\.\s*log\b|\bstd(out|err)\b|'
      r"""import\s+['"]dart:developer['"]""",
    );
    final violations = <String>[];
    for (final file in sources) {
      for (final match in logging.allMatches(_code(file.readAsStringSync()))) {
        violations.add('${_path(file)}: ${match.group(0)}');
      }
    }
    expect(sources.length, greaterThan(20));
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}

List<File> _dartFiles(String directory) => [
  for (final entity in Directory(directory).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity,
];

String _path(File file) => file.path.replaceAll(r'\', '/');

final _importDirective = RegExp(
  r"^\s*(?:import|export)\s+'([^']+)'",
  multiLine: true,
);

List<String> _imports(File file) => [
  for (final match in _importDirective.allMatches(file.readAsStringSync()))
    match.group(1)!,
];

/// [source] without its comments, so an assertion reads what the code does
/// rather than what a comment says about it. A line comment is taken to start
/// at `//` that does not follow a `:`, so a URL in a string stays.
String _code(String source) => source
    .replaceAll('\r\n', '\n')
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'(?<!:)//[^\n]*'), '');
