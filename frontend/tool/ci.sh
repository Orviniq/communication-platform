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
flutter build apk --release --flavor production --target lib/main_production.dart
# Production must keep building and stay verifiable, while remaining
# undistributable: unsigned, correctly identified, and free of the Beta MLS core.
# Note that Flutter copies this artifact without the "-unsigned" suffix the
# Android build gave it, so the name alone must never be taken as evidence.
sh ./tool/verify_release_apk.sh --production \
  build/app/outputs/flutter-apk/app-production-release.apk
