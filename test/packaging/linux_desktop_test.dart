import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Linux 桌面集成打包资产的契约测试：只读仓库文件，不依赖系统工具。
///
/// 这些契约在发布包里直接对用户可见，坏掉的表现是「应用菜单找不到」或
/// 「dock 显示通用图标」，所以用测试钉住。
void main() {
  const packagingDir = 'linux/packaging';
  const appId = 'top.stillmisty.molia';
  final desktopFile = File('$packagingDir/share/applications/$appId.desktop');

  test('.desktop 文件名与 app_id 一致，且必填键齐全（Wayland 靠文件名匹配）', () {
    expect(p.basename(desktopFile.path), '$appId.desktop');
    expect(desktopFile.existsSync(), isTrue);

    final entries = <String, String>{};
    for (final line in desktopFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('[')) {
        continue;
      }
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      entries[trimmed.substring(0, separator)] =
          trimmed.substring(separator + 1);
    }

    expect(entries['Type'], 'Application');
    expect(entries['Name'], 'Molia');
    expect(entries['Name[zh_CN]'], '茉咏');
    expect(entries['Exec'], 'molia');
    expect(entries['Icon'], appId);
    expect(entries['StartupWMClass'], appId);
    expect(entries['Categories'], endsWith(';'));
    expect(entries['Terminal'], 'false');
  });

  test('hicolor 图标齐全，目录尺寸与 PNG 实际尺寸一致', () {
    const sizes = [16, 24, 32, 48, 64, 128, 256, 512];
    for (final size in sizes) {
      final file = File(
        '$packagingDir/share/icons/hicolor/${size}x$size/apps/$appId.png',
      );
      expect(file.existsSync(), isTrue, reason: '缺少 ${size}x$size 图标');
      final bytes = file.readAsBytesSync();
      expect(
        bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        reason: '${size}x$size 不是 PNG',
      );
      final header = ByteData.sublistView(bytes, 16, 24);
      expect(header.getUint32(0), size);
      expect(header.getUint32(4), size);
    }
  });

  test('运行期窗口图标资产存在（X11 的 setIcon 目标）', () {
    final file = File('assets/icons/app_icon.png');
    expect(file.existsSync(), isTrue);
    final bytes = file.readAsBytesSync();
    final header = ByteData.sublistView(bytes, 16, 24);
    expect(header.getUint32(0), 256);
    expect(header.getUint32(4), 256);
  });

  test('install.sh / uninstall.sh 带可执行位', () {
    for (final name in ['install.sh', 'uninstall.sh']) {
      final mode = File('$packagingDir/$name').statSync().mode;
      // 0o111：任一执行位存在即可（git 只保存整体可执行标记）。
      expect(mode & 0x49, isNot(0), reason: '$name 需要可执行位');
    }
  });

  test('desktop-file-validate 通过（工具缺失时跳过）', () async {
    final probe = await Process.run('which', ['desktop-file-validate']);
    if (probe.exitCode != 0) return;
    final result = await Process.run('desktop-file-validate', [
      desktopFile.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}${result.stderr}',
    );
  });
}
