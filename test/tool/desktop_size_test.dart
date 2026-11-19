import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent/src/desktop_size.dart';

Directory _bundle(Map<String, int> files) {
  final dir = Directory.systemTemp.createTempSync('molia-desktop-bundle-');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final entry in files.entries) {
    final file = File('${dir.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(entry.value, 0));
  }
  return dir;
}

void main() {
  group('inspectDesktopBundle', () {
    test('识别 Linux 布局与原生库大小', () {
      final dir = _bundle({
        'molia': 10,
        'lib/libapp.so': 100,
        'lib/libflutter_linux_gtk.so': 200,
        'lib/libsqlite3.so': 50,
        'data/flutter_assets/AssetManifest.bin': 5,
      });

      final report = inspectDesktopBundle(dir)!;
      expect(report.platform, DesktopBundlePlatform.linux);
      expect(report.totalBytes, 365);
      expect(report.sortedLibraries.map((library) => library.name), [
        'libflutter_linux_gtk.so',
        'libapp.so',
        'libsqlite3.so',
      ]);
      expect(
        report.sortedLibraries.first.relativePath,
        'lib/libflutter_linux_gtk.so',
      );
    });

    test('识别 Windows 布局（exe + 资源目录）', () {
      final dir = _bundle({
        'molia.exe': 10,
        'flutter_windows.dll': 20,
        'data/flutter_assets/AssetManifest.bin': 5,
      });

      final report = inspectDesktopBundle(dir)!;
      expect(report.platform, DesktopBundlePlatform.windows);
      expect(report.executables, ['molia.exe']);
      expect(report.hasAssetsDir, isTrue);
    });

    test('不存在的目录返回 null', () {
      expect(inspectDesktopBundle(Directory('/no/such/bundle')), isNull);
    });
  });

  group('checkDesktopBundle', () {
    test('干净的 Linux bundle 通过', () {
      final dir = _bundle({
        'lib/libapp.so': 100,
        'lib/libflutter_linux_gtk.so': 200,
        'lib/libsqlite3.so': 50,
      });
      expect(checkDesktopBundle(inspectDesktopBundle(dir)!), isEmpty);
    });

    test('递归拦回 dartjni（大小写不敏感）', () {
      final dir = _bundle({
        'lib/libapp.so': 100,
        'lib/libflutter_linux_gtk.so': 200,
        'data/nested/libDartJni.DLL': 10,
        'lib/libdartjni.so': 10,
      });

      final errors = checkDesktopBundle(inspectDesktopBundle(dir)!);
      expect(errors, hasLength(2));
      expect(
        errors.every((error) => error.toLowerCase().contains('dartjni')),
        isTrue,
      );
    });

    test('Linux 缺少 AOT / 引擎库时报错', () {
      final dir = _bundle({'lib/libsqlite3.so': 10});
      expect(inspectDesktopBundle(dir)!.platform, isNull);
      final errors = checkDesktopBundle(inspectDesktopBundle(dir)!);
      expect(errors.single, contains('无法识别桌面 bundle'));
    });

    test('Windows 缺少 exe 或资源目录时报错', () {
      final dir = _bundle({'data/flutter_assets/x': 1});
      final report = inspectDesktopBundle(dir)!;
      expect(report.platform, DesktopBundlePlatform.windows);
      final errors = checkDesktopBundle(report);
      expect(errors.any((error) => error.contains('缺少入口 exe')), isTrue);
    });
  });

  group('renderDesktopBundleMarkdown', () {
    test('列出平台、总体积与原生库', () {
      final dir = _bundle({
        'lib/libapp.so': 1024,
        'lib/libflutter_linux_gtk.so': 2048,
        'lib/libdartjni.so': 512,
      });
      final text = renderDesktopBundleMarkdown(inspectDesktopBundle(dir)!);
      expect(text, contains('平台: linux'));
      expect(text, contains('bundle: 3.50KB'));
      expect(text, contains('| libdartjni.so | lib/libdartjni.so | 512B |'));
    });
  });
}
