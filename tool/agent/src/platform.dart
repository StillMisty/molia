/// 平台相关的小工具：显示前缀、设备枚举、子进程环境。
///
/// 为什么要单独一层：Linux 无头跑桌面应用必须走 Xvfb，且只改 DISPLAY 不够
/// （GDK 见到 WAYLAND_DISPLAY 会优先连真实 Wayland 合成器）；Windows /
/// macOS 不需要也不该被注入这些变量。
library;

import 'dart:io';

/// 单实例逃生口：自动化实例必须能与本机手工启动的实例并存。
const String singleInstanceEnv = 'MOLIA_SINGLE_INSTANCE_DISABLED';

/// 运行命令前需要追加的前缀。
///
/// - Linux + headless：`xvfb-run -a env -u WAYLAND_DISPLAY GDK_BACKEND=x11`
/// - Linux + 真实显示 / 其它平台：不加前缀（显示相关变量不猜）
List<String> displayPrefix({
  required bool headless,
  required bool requireDisplay,
}) {
  if (!Platform.isLinux) return const [];
  if (!headless) {
    if (requireDisplay && !_hasDisplay) {
      throw StateError('没有 DISPLAY/WAYLAND_DISPLAY：去掉 --window 用 Xvfb，或先准备显示');
    }
    return const [];
  }
  return const [
    'xvfb-run',
    '-a',
    'env',
    '-u',
    'WAYLAND_DISPLAY',
    'GDK_BACKEND=x11',
  ];
}

bool get _hasDisplay =>
    (Platform.environment['DISPLAY'] ?? '').isNotEmpty ||
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

/// 子进程环境：默认继承 + 注入单实例逃生口。
Map<String, String> childEnvironment({Map<String, String> extra = const {}}) =>
    {...Platform.environment, singleInstanceEnv: '1', ...extra};

/// 解析 `adb devices` 输出（纯函数，便于单测）。
///
/// 只看状态为 `device` 的行：`offline` / `unauthorized` 不应被当成可用设备。
List<String> parseAdbDevices(String output) {
  final serials = <String>[];
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1] == 'device' && parts[0] != 'List') {
      serials.add(parts[0]);
    }
  }
  return serials;
}

/// `adb devices` 里处于 device 状态的序列号。
List<String> adbDevices(String adb) {
  final result = Process.runSync(adb, const ['devices']);
  if (result.exitCode != 0) return const [];
  return parseAdbDevices(result.stdout.toString());
}

/// 第一个运行中的模拟器序列号（`emulator-*`）。
String? runningEmulator(String adb) {
  for (final serial in adbDevices(adb)) {
    if (serial.startsWith('emulator-')) return serial;
  }
  return null;
}
