/// 桌面 release bundle 的原生库清单与发布约束（`size desktop`）。
///
/// 约束来源：ADR-0038 阶段 5。Android 才会加载 JNI 运行时；桌面包里的
/// `libdartjni.so` / `dartjni.dll` 是 `jni` 插件的传递产物，没有任何调用方。
/// release 工作流先删除它，再由本文件挡回人为 / 依赖变更造成的回流。
///
/// 只做纯 Dart 目录扫描：不解析 ELF / PE，也不依赖本机是哪个桌面系统。
library;

import 'dart:io';

import 'apk_size.dart' show humanBytes;

/// 桌面 bundle 不允许出现的原生库（文件名包含即违规，大小写不敏感）。
const List<String> forbiddenDesktopLibraryPatterns = ['dartjni'];

/// Linux bundle 必须保留的库：Dart AOT 产物与 Flutter 引擎。
const Map<String, String> requiredLinuxLibraries = {
  'libapp.so': 'Dart AOT 产物',
  'libflutter_linux_gtk.so': 'Flutter Linux 引擎',
};

/// Windows bundle 的目录结构要求：入口 exe 与 Flutter 资源目录。
const String windowsAssetsDir = 'data/flutter_assets';

const Set<String> _libraryExtensions = {'.so', '.dll', '.dylib'};

enum DesktopBundlePlatform { linux, windows }

class DesktopLibrary {
  const DesktopLibrary({
    required this.name,
    required this.relativePath,
    required this.size,
  });

  final String name;

  /// 相对 bundle 根目录的路径（分隔符统一成 `/`，便于跨平台断言）。
  final String relativePath;
  final int size;
}

class DesktopBundleReport {
  const DesktopBundleReport({
    required this.path,
    required this.platform,
    required this.totalBytes,
    required this.libraries,
    required this.executables,
    required this.hasAssetsDir,
  });

  final String path;

  /// 无法识别时为 null；`--check` 会把它当成违规。
  final DesktopBundlePlatform? platform;
  final int totalBytes;
  final List<DesktopLibrary> libraries;

  /// bundle 里的 `.exe`（相对路径，排序后）。Windows 布局必须有入口。
  final List<String> executables;
  final bool hasAssetsDir;

  /// 供测试与输出：按大小降序，同分按路径排序，避免目录遍历顺序漂移。
  List<DesktopLibrary> get sortedLibraries {
    final sorted = libraries.toList()
      ..sort((a, b) {
        final bySize = b.size.compareTo(a.size);
        return bySize != 0 ? bySize : a.relativePath.compareTo(b.relativePath);
      });
    return sorted;
  }

  Set<String> get libraryNames =>
      libraries.map((library) => library.name).toSet();
}

String _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  final relative = path.startsWith(prefix)
      ? path.substring(prefix.length)
      : path;
  return relative.replaceAll(Platform.pathSeparator, '/');
}

/// 递归扫描目录；不存在的目录返回 null（由调用方给出可操作错误）。
DesktopBundleReport? inspectDesktopBundle(Directory directory) {
  if (!directory.existsSync()) return null;
  final root = directory.absolute.path;
  var totalBytes = 0;
  final libraries = <DesktopLibrary>[];
  final executables = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final stat = entity.statSync();
    totalBytes += stat.size;
    final relative = _relative(root, entity.absolute.path);
    final name = relative.split('/').last;
    final lower = name.toLowerCase();
    if (_libraryExtensions.any(lower.endsWith)) {
      libraries.add(
        DesktopLibrary(name: name, relativePath: relative, size: stat.size),
      );
    }
    if (lower.endsWith('.exe')) executables.add(relative);
  }
  executables.sort();

  final names = libraries.map((library) => library.name).toSet();
  final linuxLayout =
      names.contains('libapp.so') || names.contains('libflutter_linux_gtk.so');
  final windowsLayout =
      executables.isNotEmpty ||
      Directory('${directory.path}/data/flutter_assets').existsSync();
  final platform = linuxLayout
      ? DesktopBundlePlatform.linux
      : windowsLayout
      ? DesktopBundlePlatform.windows
      : null;

  return DesktopBundleReport(
    path: directory.path,
    platform: platform,
    totalBytes: totalBytes,
    libraries: libraries,
    executables: executables,
    hasAssetsDir: Directory('${directory.path}/$windowsAssetsDir').existsSync(),
  );
}

/// 返回违反发布约束的说明；空列表表示通过。
List<String> checkDesktopBundle(DesktopBundleReport report) {
  final errors = <String>[];
  final names = report.libraryNames;
  for (final library in report.libraries) {
    final lower = library.name.toLowerCase();
    for (final pattern in forbiddenDesktopLibraryPatterns) {
      if (lower.contains(pattern)) {
        errors.add(
          '发现禁止库 ${library.relativePath}：桌面不使用 JNI 运行时'
          '（ADR-0038 阶段 5）',
        );
      }
    }
  }

  switch (report.platform) {
    case DesktopBundlePlatform.linux:
      for (final entry in requiredLinuxLibraries.entries) {
        if (!names.contains(entry.key)) {
          errors.add('缺少必需库 ${entry.key}：${entry.value}');
        }
      }
    case DesktopBundlePlatform.windows:
      if (report.executables.isEmpty) {
        errors.add('缺少入口 exe：Windows bundle 根目录应有 molia.exe');
      }
      if (!report.hasAssetsDir) {
        errors.add('缺少 $windowsAssetsDir/：Windows bundle 结构不完整');
      }
    case null:
      errors.add(
        '无法识别桌面 bundle：既没有 libapp.so / libflutter_linux_gtk.so，'
        '也没有 .exe（传入 flutter build 产出的 bundle 目录）',
      );
  }
  return errors;
}

String renderDesktopBundleMarkdown(DesktopBundleReport report) {
  final platform = switch (report.platform) {
    DesktopBundlePlatform.linux => 'linux',
    DesktopBundlePlatform.windows => 'windows',
    null => '未知',
  };
  final buffer = StringBuffer()
    ..writeln('# ${report.path}')
    ..writeln('平台: $platform')
    ..writeln(
      'bundle: ${humanBytes(report.totalBytes)} '
      '(${report.totalBytes} B)',
    )
    ..writeln()
    ..writeln('| 原生库 | 相对路径 | 大小 |')
    ..writeln('| --- | --- | ---: |');
  for (final library in report.sortedLibraries) {
    buffer.writeln(
      '| ${library.name} | ${library.relativePath} | '
      '${humanBytes(library.size)} |',
    );
  }
  return buffer.toString();
}
