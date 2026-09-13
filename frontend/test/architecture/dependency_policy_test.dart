import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What this project has decided to take from outside, and what enforces it.
///
/// ADR-054 enumerated the platform integration points the delivery and
/// notification work reaches, decided each one, and pinned what was adopted.
/// A decision nothing checks is a preference, so these assertions are the
/// automatic half of it: the declared set, the resolved set, and the merged
/// manifest are all recorded here, and a change to any of them has to be made
/// deliberately, in this file, where a reviewer sees it.
///
/// The other half is enforced outside Dart. `flutter pub get --enforce-lockfile`
/// refuses a Dart pin that drifted; Gradle dependency locking refuses an Android
/// module that is not in `android/app/gradle.lockfile`, including one that
/// arrived transitively; and `tool/verify_release_apk.sh` reads the permissions
/// and components back out of the packaged artifact.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final pubspecLock = File('pubspec.lock').readAsStringSync();
  final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
  final rootGradle = File('android/build.gradle.kts').readAsStringSync();
  final settingsGradle = File('android/settings.gradle.kts').readAsStringSync();
  final gradleLock = File('android/app/gradle.lockfile').readAsStringSync();
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  group('what this project declares it depends on', () {
    test('the direct Dart set is exactly the set ADR-054 reviewed', () {
      // Adding one line here is cheap; the cost is that everything it drags in
      // becomes part of an artifact whose premise is that it can be reasoned
      // about. Making the list literal is what turns "a dependency appeared"
      // into a review conversation instead of a `pub get`.
      expect(_declaredDependencies(pubspec, 'dependencies'), <String, String>{
        'connectivity_plus': '6.0.5',
        'dio': '5.11.0',
        'drift': '2.34.2',
        'drift_flutter': '0.3.1',
        'emoji_picker_flutter': '4.5.3',
        'ffi': '2.2.0',
        'flutter': _fromSdk,
        'flutter_localizations': _fromSdk,
        'flutter_riverpod': '3.3.2',
        'forui': '0.24.3',
        'go_router': '17.3.0',
        'intl': '0.20.2',
        'qr_flutter': '4.1.0',
        'sqlite3': '3.5.0',
        'web_socket_channel': '3.0.3',
      });
      expect(
        _declaredDependencies(pubspec, 'dev_dependencies'),
        <String, String>{
          'build_runner': '2.15.1',
          'drift_dev': '2.34.0',
          'flutter_lints': '6.0.0',
          'flutter_test': _fromSdk,
          'integration_test': _fromSdk,
        },
      );
    });

    test('every direct dependency is one exact version, never a range', () {
      // A caret range is not a pin. `pubspec.lock` would still hold the
      // resolution, but the declared intent would be "whatever is compatible",
      // and the next person to regenerate the lock would get something nobody
      // reviewed.
      for (final section in const ['dependencies', 'dev_dependencies']) {
        for (final entry in _declaredDependencies(pubspec, section).entries) {
          if (entry.value == _fromSdk) {
            continue;
          }
          expect(
            RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(entry.value),
            isTrue,
            reason:
                '${entry.key} is declared as "${entry.value}", which is a '
                'range or a constraint rather than one exact version',
          );
        }
      }
    });

    test('the lock agrees with the pubspec about what is direct', () {
      final declared = <String>{
        ..._declaredDependencies(pubspec, 'dependencies').keys,
        ..._declaredDependencies(pubspec, 'dev_dependencies').keys,
      };
      expect(_lockedDirectPackages(pubspecLock), declared);
    });

    test('nothing in the resolved Dart set is a retracted or pre-release '
        'version', () {
      // Both have been in this lock. `jni` 1.0.1 was retracted by its
      // publisher the day after it was published, for the breaking Kotlin
      // plugin change this build carried a workaround for; and
      // `riverpod_analyzer_utils` was resolved at a `-dev` version by a code
      // generator nothing in `lib/` ever used. A lockfile keeps whatever it
      // was given, and `--enforce-lockfile` then reinstalls it forever, so the
      // shape has to be checked rather than assumed.
      final prerelease = RegExp(r'^\s+version: "[^"]*-(dev|alpha|beta|rc)');
      final offenders = pubspecLock
          .split('\n')
          .where(prerelease.hasMatch)
          .toList();
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('what the Android build links from outside', () {
    test('the app module adopts one library, at the locked version', () {
      final declared = _gradleImplementationCoordinates(appGradle);
      expect(declared, <String>['androidx.core:core:1.16.0']);
      // Dependency locking constrains a version rather than reporting it, so a
      // build file and a lock that disagree would resolve silently to the
      // lock's answer. Requiring them to agree is what keeps the declaration
      // honest about what is actually linked.
      for (final coordinate in declared) {
        expect(
          _lockedModules(gradleLock).keys,
          contains(coordinate),
          reason: '$coordinate is declared but is not what the lock resolves',
        );
      }
    });

    test('no Gradle dependency or plugin is declared dynamically', () {
      // A dynamic version resolves to whatever exists on the day of the build,
      // which is the opposite of an artifact that can be rebuilt years later
      // from source control, on a workstation with no route out of the country.
      final dynamicVersion = RegExp(
        r'''["']([\w.\-]+:[\w.\-]+:)?'''
        r'''(\+|latest\.\w+|[\d.]*\+|\[[^\]]*\]|\([^)]*\))["']''',
      );
      for (final entry in <String, String>{
        'android/app/build.gradle.kts': appGradle,
        'android/build.gradle.kts': rootGradle,
        'android/settings.gradle.kts': settingsGradle,
      }.entries) {
        final matches = dynamicVersion
            .allMatches(entry.value)
            .map((match) => match.group(0)!)
            .toList();
        expect(matches, isEmpty, reason: '${entry.key}: $matches');
      }
    });

    test('the lock covers every configuration a built artifact resolves', () {
      // STRICT mode fails a locked configuration that has no recorded state,
      // but it cannot notice a configuration that was never named - an AGP
      // rename would silently switch locking off for it. Naming them here is
      // what makes that a failing test rather than a quiet loss of enforcement.
      expect(_lockedConfigurations(gradleLock), <String>{
        'developmentDebugCompileClasspath',
        'developmentDebugRuntimeClasspath',
        'productionReleaseCompileClasspath',
        'productionReleaseRuntimeClasspath',
      });
      for (final configuration in _lockedConfigurations(gradleLock)) {
        expect(
          appGradle,
          contains('"$configuration"'),
          reason: 'the build file must ask for locking on $configuration',
        );
      }
    });

    test('a released artifact links exactly the reviewed modules', () {
      // This is the answer to "what does the packaged artifact contain that
      // this project did not write", on the Android side, in full.
      final release = _modulesIn(
        gradleLock,
        'productionReleaseRuntimeClasspath',
      );
      expect(_withoutEngineRevision(release), _reviewedReleaseModules);
    });

    test('the notices document lists exactly what a release links', () {
      // Apache-2.0 and the BSD 3-Clause licence both require that whoever
      // receives the binary receives the attribution. A notices document that
      // has drifted from the lock is a distribution with the wrong notices,
      // which is the same failure as a distribution with none.
      final notices = File(
        'docs/third-party-notices.md',
      ).readAsStringSync().replaceAll(String.fromCharCode(13), '');
      final listed = RegExp(
        r'^- `([\w.\-]+:[\w.\-]+:[^`]+)`$',
        multiLine: true,
      ).allMatches(notices).map((match) => match.group(1)!).toSet();
      expect(
        listed,
        _modulesIn(gradleLock, 'productionReleaseRuntimeClasspath'),
      );
    });

    test('the Flutter engine is one revision everywhere', () {
      final engines =
          _modulesIn(gradleLock, 'productionReleaseRuntimeClasspath')
              .where((module) => module.startsWith('io.flutter:'))
              .map((module) => module.split(':').last)
              .toSet();
      expect(engines, hasLength(1));
      expect(
        RegExp(r'^1\.0\.0-[0-9a-f]{40}$').hasMatch(engines.single),
        isTrue,
      );
    });

    test('test infrastructure reaches no distributed configuration', () {
      // Espresso, JUnit, Guava and Hamcrest arrive with `integration_test`,
      // which is a dev dependency. Nothing enforced that they stayed out of a
      // release classpath; the lock now records that they do, per module.
      for (final entry in _lockedModules(gradleLock).entries) {
        final group = entry.key.split(':').first;
        final isTestOnly =
            group.startsWith('androidx.test') ||
            group == 'junit' ||
            group == 'org.hamcrest' ||
            group == 'com.google.guava' && entry.key.contains(':guava:') ||
            group == 'com.squareup' ||
            group == 'javax.inject';
        if (!isTestOnly) {
          continue;
        }
        expect(
          entry.value.where(
            (configuration) => !configuration.startsWith('developmentDebug'),
          ),
          isEmpty,
          reason: '${entry.key} reaches a distributed configuration',
        );
      }
    });
  });

  group('what the merged manifest may contain', () {
    test('every permission in the artifact is declared here', () {
      // `ACCESS_NETWORK_STATE` arrives from connectivity_plus whether this file
      // names it or not. Declaring it locally is what keeps the manifest a
      // complete, justified statement of what the application asks for, rather
      // than a partial one a reviewer has to reconcile against a package.
      expect(_declaredPermissions(manifest), <String>{
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
        'android.permission.INTERNET',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.RECEIVE_BOOT_COMPLETED',
        'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        'android.permission.VIBRATE',
      });
    });

    test('the receiver androidx.profileinstaller contributes is refused', () {
      // An exported component with four intent filters, from a library two
      // levels below anything this project chose. The baseline profile is
      // still written on first run by `ProfileInstallerInitializer`, which
      // calls `ProfileInstaller.writeProfile` and never names this receiver.
      expect(manifest, contains('xmlns:tools='));
      expect(
        manifest,
        contains('androidx.profileinstaller.ProfileInstallReceiver'),
      );
      expect(manifest, contains('tools:node="remove"'));
    });

    test('this application declares one exported component', () {
      // The launcher activity, and nothing else. Both services are unexported;
      // the job service is additionally bound with BIND_JOB_SERVICE.
      expect('android:exported="true"'.allMatches(manifest), hasLength(1));
    });
  });
}

/// The marker used for a dependency that comes from the Flutter SDK and so
/// carries the SDK's version rather than one of its own.
const _fromSdk = 'sdk:flutter';

/// The complete set of Android modules a distributed artifact links, with the
/// Flutter engine revision replaced by a placeholder so that a Flutter SDK
/// upgrade fails the lock (which records the exact revision) rather than this
/// list.
const _reviewedReleaseModules = <String>{
  'androidx.activity:activity-ktx:1.8.1',
  'androidx.activity:activity:1.8.1',
  'androidx.annotation:annotation-experimental:1.4.1',
  'androidx.annotation:annotation-jvm:1.8.1',
  'androidx.annotation:annotation:1.8.1',
  'androidx.appcompat:appcompat-resources:1.1.0',
  'androidx.appcompat:appcompat:1.1.0',
  'androidx.arch.core:core-common:2.2.0',
  'androidx.arch.core:core-runtime:2.2.0',
  'androidx.asynclayoutinflater:asynclayoutinflater:1.0.0',
  'androidx.collection:collection-jvm:1.4.2',
  'androidx.collection:collection-ktx:1.4.2',
  'androidx.collection:collection:1.4.2',
  'androidx.concurrent:concurrent-futures:1.1.0',
  'androidx.coordinatorlayout:coordinatorlayout:1.0.0',
  'androidx.core:core-ktx:1.16.0',
  'androidx.core:core-viewtree:1.0.0',
  'androidx.core:core:1.16.0',
  'androidx.cursoradapter:cursoradapter:1.0.0',
  'androidx.customview:customview:1.1.0',
  'androidx.datastore:datastore-android:1.1.7',
  'androidx.datastore:datastore-core-android:1.1.7',
  'androidx.datastore:datastore-core-okio-jvm:1.1.7',
  'androidx.datastore:datastore-core-okio:1.1.7',
  'androidx.datastore:datastore-core:1.1.7',
  'androidx.datastore:datastore-preferences-android:1.1.7',
  'androidx.datastore:datastore-preferences-core-android:1.1.7',
  'androidx.datastore:datastore-preferences-core:1.1.7',
  'androidx.datastore:datastore-preferences-external-protobuf:1.1.7',
  'androidx.datastore:datastore-preferences-proto:1.1.7',
  'androidx.datastore:datastore-preferences:1.1.7',
  'androidx.datastore:datastore:1.1.7',
  'androidx.documentfile:documentfile:1.0.0',
  'androidx.drawerlayout:drawerlayout:1.0.0',
  'androidx.exifinterface:exifinterface:1.4.1',
  'androidx.fragment:fragment-ktx:1.7.1',
  'androidx.fragment:fragment:1.7.1',
  'androidx.interpolator:interpolator:1.0.0',
  'androidx.legacy:legacy-support-core-ui:1.0.0',
  'androidx.legacy:legacy-support-core-utils:1.0.0',
  'androidx.lifecycle:lifecycle-common-java8:2.7.0',
  'androidx.lifecycle:lifecycle-common:2.7.0',
  'androidx.lifecycle:lifecycle-livedata-core-ktx:2.7.0',
  'androidx.lifecycle:lifecycle-livedata-core:2.7.0',
  'androidx.lifecycle:lifecycle-livedata:2.7.0',
  'androidx.lifecycle:lifecycle-process:2.7.0',
  'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0',
  'androidx.lifecycle:lifecycle-runtime:2.7.0',
  'androidx.lifecycle:lifecycle-viewmodel-ktx:2.7.0',
  'androidx.lifecycle:lifecycle-viewmodel-savedstate:2.7.0',
  'androidx.lifecycle:lifecycle-viewmodel:2.7.0',
  'androidx.loader:loader:1.0.0',
  'androidx.localbroadcastmanager:localbroadcastmanager:1.0.0',
  'androidx.preference:preference:1.2.1',
  'androidx.print:print:1.0.0',
  'androidx.profileinstaller:profileinstaller:1.3.1',
  'androidx.recyclerview:recyclerview:1.0.0',
  'androidx.savedstate:savedstate-ktx:1.2.1',
  'androidx.savedstate:savedstate:1.2.1',
  'androidx.slidingpanelayout:slidingpanelayout:1.2.0',
  'androidx.startup:startup-runtime:1.1.1',
  'androidx.swiperefreshlayout:swiperefreshlayout:1.0.0',
  'androidx.tracing:tracing:1.2.0',
  'androidx.transition:transition:1.4.1',
  'androidx.vectordrawable:vectordrawable-animated:1.1.0',
  'androidx.vectordrawable:vectordrawable:1.1.0',
  'androidx.versionedparcelable:versionedparcelable:1.1.1',
  'androidx.viewpager:viewpager:1.0.0',
  'androidx.window.extensions.core:core:1.0.0',
  'androidx.window:window-java:1.2.0',
  'androidx.window:window:1.2.0',
  'com.getkeepsafe.relinker:relinker:1.4.5',
  'com.google.guava:listenablefuture:1.0',
  'com.squareup.okio:okio-jvm:3.4.0',
  'com.squareup.okio:okio:3.4.0',
  'io.flutter:arm64_v8a_release:<engine>',
  'io.flutter:armeabi_v7a_release:<engine>',
  'io.flutter:flutter_embedding_release:<engine>',
  'io.flutter:x86_64_release:<engine>',
  'org.jetbrains.kotlin:kotlin-android-extensions-runtime:1.9.22',
  'org.jetbrains.kotlin:kotlin-parcelize-runtime:1.9.22',
  'org.jetbrains.kotlin:kotlin-stdlib-common:2.3.20',
  'org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.9.20',
  'org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.8.20',
  'org.jetbrains.kotlin:kotlin-stdlib:2.3.20',
  'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3',
  'org.jetbrains.kotlinx:kotlinx-coroutines-bom:1.7.3',
  'org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.7.3',
  'org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3',
  'org.jetbrains:annotations:23.0.0',
  'org.jspecify:jspecify:1.0.0',
};

/// Reads one dependency block out of `pubspec.yaml` as name to exact version.
Map<String, String> _declaredDependencies(String pubspec, String section) {
  final result = <String, String>{};
  var inSection = false;
  String? pendingName;
  for (final rawLine in pubspec.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line.trimLeft() != line || line.isEmpty) {
      if (!inSection) {
        continue;
      }
      final entry = RegExp(r'^  ([a-z0-9_]+):\s*(\S*)\s*$').firstMatch(line);
      if (entry != null) {
        pendingName = entry.group(1);
        final version = entry.group(2)!;
        if (version.isNotEmpty) {
          result[pendingName!] = version;
          pendingName = null;
        }
        continue;
      }
      if (pendingName != null && line.trim() == 'sdk: flutter') {
        result[pendingName] = _fromSdk;
        pendingName = null;
      }
      continue;
    }
    inSection = line.startsWith('$section:');
    pendingName = null;
  }
  return result;
}

/// The packages `pubspec.lock` records as directly depended on.
Set<String> _lockedDirectPackages(String lock) {
  final result = <String>{};
  String? current;
  for (final rawLine in lock.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    final name = RegExp(r'^  ([a-z0-9_]+):$').firstMatch(line);
    if (name != null) {
      current = name.group(1);
      continue;
    }
    if (current != null && line.trim().startsWith('dependency: "direct')) {
      result.add(current);
    }
  }
  return result;
}

/// Every `implementation("group:artifact:version")` this module declares.
List<String> _gradleImplementationCoordinates(String gradle) => RegExp(
  r'^\s*implementation\("([^"]+)"\)',
  multiLine: true,
).allMatches(gradle).map((match) => match.group(1)!).toList();

/// `android/app/gradle.lockfile` as module coordinate to configuration names.
Map<String, Set<String>> _lockedModules(String lock) {
  final result = <String, Set<String>>{};
  for (final rawLine in lock.split('\n')) {
    final line = rawLine.replaceAll('\r', '').trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('empty=')) {
      continue;
    }
    final separator = line.lastIndexOf('=');
    result[line.substring(0, separator)] = line
        .substring(separator + 1)
        .split(',')
        .where((name) => name.isNotEmpty)
        .toSet();
  }
  return result;
}

Set<String> _lockedConfigurations(String lock) =>
    _lockedModules(lock).values.expand((names) => names).toSet();

Set<String> _modulesIn(String lock, String configuration) =>
    _lockedModules(lock).entries
        .where((entry) => entry.value.contains(configuration))
        .map((entry) => entry.key)
        .toSet();

Set<String> _withoutEngineRevision(Set<String> modules) => modules
    .map(
      (module) => module.startsWith('io.flutter:')
          ? '${module.substring(0, module.lastIndexOf(':'))}:<engine>'
          : module,
    )
    .toSet();

/// Every permission `uses-permission` names in this project's own manifest.
Set<String> _declaredPermissions(String manifest) =>
    RegExp(r'<uses-permission\s+android:name="([^"]+)"')
        .allMatches(
          manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ''),
        )
        .map((match) => match.group(1)!)
        .toSet();
