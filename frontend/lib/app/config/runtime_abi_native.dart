import 'dart:ffi' show Abi;

import 'package:communication_platform/app/config/group_production_gate.dart';

/// The cell for the library this process loaded, or null when the artifact
/// packages none for it.
///
/// One APK carries `arm64-v8a`, `armeabi-v7a` and `x86_64`, and the installer
/// chooses; ADR-056 needs to know which one it got, because the closed-beta
/// MLS core has been measured on some of them and not others.
///
/// `Abi.current()` is a property of the AOT snapshot the platform selected,
/// fixed before any application code runs. It is read, never chosen: there is
/// no define, no setting and nothing a caller can pass to change the answer.
///
/// An ABI absent from this map — an Android RISC-V device, a desktop host
/// running the test suite, anything added later — returns null and is therefore
/// withheld the group surface, which is the fail-closed direction.
GroupMlsFieldCell? currentGroupMlsAbiCell() => switch (Abi.current()) {
  Abi.androidArm64 => GroupMlsFieldCell.arm64V8a,
  Abi.androidArm => GroupMlsFieldCell.armeabiV7a,
  Abi.androidX64 => GroupMlsFieldCell.x8664,
  _ => null,
};
