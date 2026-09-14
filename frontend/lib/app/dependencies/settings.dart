import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/settings/application/ports/settings_ports.dart';
import 'package:communication_platform/features/settings/domain/appearance_model.dart';
import 'package:communication_platform/features/settings/infrastructure/drift_appearance_preference_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the display preferences live, when this build has protected storage.
final appearancePreferenceStoreProvider =
    FutureProvider<AppearancePreferenceStore>((ref) async {
      final database = await ref.watch(localDatabaseProvider.future);
      return DriftAppearancePreferenceStore(database);
    });

/// The preferences the application is rendering with, right now.
///
/// Synchronous by design. The root widget reads it on every build to choose a
/// theme and a locale, and it may not wait for a database to open before it can
/// paint: an installation whose storage is slow, missing or unreadable renders
/// with the phone's own settings, which is the correct answer rather than a
/// fallback pretending to be one. The stored values replace it as soon as they
/// arrive.
final appearancePreferencesProvider =
    NotifierProvider<AppearanceController, AppearancePreferences>(
      AppearanceController.new,
    );

/// `base` for the same reason the sustained-delivery controller is: a widget
/// test has to be able to render this application at a chosen theme and
/// language without a database behind it, and a substitute should still be a
/// real controller rather than a structural imitation of one.
base class AppearanceController extends Notifier<AppearancePreferences> {
  var _closed = false;

  /// The load, so a test can await it instead of pumping for it.
  @visibleForTesting
  Future<void> get settled => _loaded;
  Future<void> _loaded = Future<void>.value();

  @override
  AppearancePreferences build() {
    ref.onDispose(() => _closed = true);
    _loaded = _load();
    return AppearancePreferences.followSystem;
  }

  /// Applies a change and reports whether it stuck.
  ///
  /// The screen updates immediately either way, so a user never taps a control
  /// that appears to do nothing; a failed write is surfaced by the screen as a
  /// preference that will not survive a restart, which is the truth.
  Future<Result<void>> update(AppearancePreferences preferences) async {
    if (_closed) {
      return const Result.success(null);
    }
    state = preferences;
    try {
      final store = await ref.read(appearancePreferenceStoreProvider.future);
      return await store.write(preferences);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<void> _load() async {
    try {
      final store = await ref.read(appearancePreferenceStoreProvider.future);
      final stored = await store.read();
      if (!_closed) {
        state = stored;
      }
    } on Object {
      // No storage in this composition. The phone's own settings stand, which
      // is what `build` already returned.
    }
  }
}
