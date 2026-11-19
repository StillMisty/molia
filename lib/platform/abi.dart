/// 运行时 ABI / 架构名称（ADR-0038 阶段 2）。
///
/// 只包装 `dart:ffi` 的 [Abi] 枚举与命名映射，不做任何 FFI 调用：诊断信息与
/// 更新清单需要的是同一套「arm64 / armv7 / x64」口径，放在平台层避免各业务
/// 文件各写一份 switch，也避免 Android 的 `x86_64` 被桌面的 `x64` 混淆。
library;

import 'dart:ffi';

/// 原始 ABI 标签（诊断导出用），例如 `linux_x64` / `android_arm64`。
String currentAbiLabel() => Abi.current().toString();

/// 通用架构名：`arm64` / `armv7` / `x64`，其它（含 WASM / IA32 / RISC-V）为
/// `any`。
///
/// 用于 iOS / Windows / Linux / macOS 的更新清单 `arch` 字段。
String currentArchName() => archNameForAbi(Abi.current());

/// Android 产物架构名：`arm64` / `armv7` / `x86_64`，其它为 `any`。
///
/// Android 的 x86_64 在更新清单里必须写 `x86_64`（与 APK 的 `lib/` 目录名
/// 一致），不能复用桌面的 `x64`，否则清单匹配不到模拟器产物。
String currentAndroidArchName() => androidArchNameForAbi(Abi.current());

/// [abi] 对应的通用架构名（纯函数，便于测试覆盖无法在本机运行的平台）。
String archNameForAbi(Abi abi) => switch (abi) {
  Abi.androidArm64 ||
  Abi.iosArm64 ||
  Abi.fuchsiaArm64 ||
  Abi.linuxArm64 ||
  Abi.macosArm64 ||
  Abi.windowsArm64 => 'arm64',
  Abi.androidArm || Abi.iosArm || Abi.linuxArm => 'armv7',
  Abi.androidX64 ||
  Abi.iosX64 ||
  Abi.fuchsiaX64 ||
  Abi.linuxX64 ||
  Abi.macosX64 ||
  Abi.windowsX64 => 'x64',
  _ => 'any',
};

/// [abi] 对应的 Android 产物架构名（纯函数）。
String androidArchNameForAbi(Abi abi) => switch (abi) {
  Abi.androidArm64 => 'arm64',
  Abi.androidArm => 'armv7',
  Abi.androidX64 => 'x86_64',
  _ => 'any',
};
