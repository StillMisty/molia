import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/platform/abi.dart';

/// ABI 命名映射（ADR-0038 阶段 2）。
///
/// 这些函数在本机只能观察到 Linux ABI，跨平台分支用枚举值直接断言：更新
/// 清单的 `arch` 必须与产物一致，尤其 Android 的 x86_64 不能写成桌面的 x64。
void main() {
  group('androidArchNameForAbi', () {
    test('Android 三种 ABI 映射为 APK 的 lib/ 目录名', () {
      expect(androidArchNameForAbi(Abi.androidArm64), 'arm64');
      expect(androidArchNameForAbi(Abi.androidArm), 'armv7');
      expect(androidArchNameForAbi(Abi.androidX64), 'x86_64');
    });

    test('非 Android ABI 返回 any（不允许把桌面 x64 写进 Android 清单）', () {
      expect(androidArchNameForAbi(Abi.linuxX64), 'any');
      expect(androidArchNameForAbi(Abi.macosArm64), 'any');
      expect(androidArchNameForAbi(Abi.windowsX64), 'any');
    });
  });

  group('archNameForAbi', () {
    test('各平台 arm64 / armv7 统一命名', () {
      for (final abi in [
        Abi.androidArm64,
        Abi.iosArm64,
        Abi.linuxArm64,
        Abi.macosArm64,
        Abi.windowsArm64,
      ]) {
        expect(archNameForAbi(abi), 'arm64', reason: '$abi');
      }
      for (final abi in [Abi.androidArm, Abi.iosArm, Abi.linuxArm]) {
        expect(archNameForAbi(abi), 'armv7', reason: '$abi');
      }
    });

    test('桌面 x64 与 Android x64 都映射为 x64（通用口径）', () {
      expect(archNameForAbi(Abi.linuxX64), 'x64');
      expect(archNameForAbi(Abi.windowsX64), 'x64');
      expect(archNameForAbi(Abi.macosX64), 'x64');
      expect(archNameForAbi(Abi.androidX64), 'x64');
    });

    test('未覆盖的 ABI 返回 any', () {
      expect(archNameForAbi(Abi.windowsIA32), 'any');
      expect(archNameForAbi(Abi.linuxRiscv64), 'any');
    });
  });

  test('current* 读取当前进程 ABI（测试宿主为 Linux）', () {
    expect(currentAbiLabel(), Abi.current().toString());
    expect(currentArchName(), archNameForAbi(Abi.current()));
    if (Platform.isLinux) {
      expect(currentArchName(), isNot('any'));
      expect(currentAndroidArchName(), 'any');
    }
  });
}
