import 'package:communication_platform/app/dependencies/attachment_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-089 D8: with no private cache there is no attachment feature, and no
/// other directory takes its place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelAttachmentPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('no private cache means no storage and no cache, and a sweep that '
      'does nothing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final container = ProviderContainer.test(
      overrides: [
        localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      ],
    );
    final notAvailable = throwsA(
      anyOf(
        isA<StateError>(),
        isA<ProviderException>().having(
          (error) => error.exception,
          'exception',
          isA<StateError>(),
        ),
      ),
    );

    await expectLater(
      container.read(attachmentCacheRootProvider.future),
      notAvailable,
    );
    await expectLater(
      container.read(attachmentStorageProvider.future),
      notAvailable,
    );
    await expectLater(
      container.read(attachmentFileCacheProvider.future),
      notAvailable,
    );
    // Messaging still deletes; there is just no file to sweep.
    await container.read(attachmentSweepProvider).sweepAfterDeletion();
  });
}
