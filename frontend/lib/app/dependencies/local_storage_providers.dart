import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/features/local_storage/application/ports/local_storage_ports.dart';
import 'package:communication_platform/features/local_storage/domain/local_storage_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_conversation_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/local_storage/infrastructure/platform/platform_local_storage_native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localStorageRuntimeProvider = Provider<SecureLocalStorageRuntime>((ref) {
  final runtime = createPlatformLocalStorageRuntime();
  ref.onDispose(runtime.close);
  return runtime;
});

final localDatabaseProvider = FutureProvider<LocalDatabase>((ref) async {
  final result = await ref.watch(localStorageRuntimeProvider).open();
  return result.fold(
    onSuccess: (database) => database,
    onFailure: (failure) => throw LocalStorageProjectionException(failure),
  );
});

final conversationProjectionRepositoryProvider =
    FutureProvider<ConversationProjectionRepository>((ref) async {
      final database = await ref.watch(localDatabaseProvider.future);
      return DriftConversationProjectionRepository(database);
    });

final conversationProjectionsProvider =
    StreamProvider<List<ConversationProjection>>((ref) async* {
      final repository = await ref.watch(
        conversationProjectionRepositoryProvider.future,
      );
      yield* repository.watchConversations();
    });

final class LocalStorageProjectionException implements Exception {
  const LocalStorageProjectionException(this.failure);

  final Failure failure;

  @override
  String toString() =>
      'Local storage projection unavailable (${failure.category.name})';
}
