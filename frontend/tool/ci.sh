#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
sh ./tool/generate.sh
git diff --exit-code -- lib
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test
flutter build apk --debug --flavor development --target lib/main_development.dart
# CI never holds the production key (ADR-076 D6). The release build asks for an
# unsigned package explicitly, and runs in a subshell from which every production
# signing variable has been removed, so a key in the caller's environment can
# neither sign this artifact nor fail the build for asking for both.
(
  for name in $(env | awk -F= '/^CP_PRODUCTION_(KEYSTORE_|KEY_)[A-Za-z0-9_]*=/ || /^CP_PRODUCTION_SIGNING_PROPERTIES=/ { print $1 }'); do
    unset "$name"
  done
  CP_PRODUCTION_UNSIGNED_BUILD=1 flutter build apk --release --flavor production \
    --target lib/main_production.dart
)
# The unsigned artifact must still be the right application, declare only what
# ADR-054 recorded, and lack the deleted beta MLS core. It is verified as the
# unsigned CI artifact, never as a distributable one. Flutter copies it without
# the "-unsigned" suffix the Android build gave it, so the name alone must never
# be taken as evidence.
sh ./tool/verify_release_apk.sh --production-unsigned \
  build/app/outputs/flutter-apk/app-production-release.apk
