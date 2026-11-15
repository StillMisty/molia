/// APK 体积 / native 库明细与发布约束校验（跨端，替代 `size apk`）。
///
/// 约束来源与 sh / py 版本一致：
/// - Android 包不得出现 libmpv.so / libmediakitandroidhelper.so（media_kit 的
///   umbrella libs 会让 Android 体积 +~3MB）；
/// - 不得出现 libcnativeapi.so（桌面 nativeapi 专用，见 android/app/build.gradle）；
/// - 必须保留 libsqlite3.so（drift，见 docs/pitfalls.md）与
///   libquickjs_c_bridge_plugin.so（LX 引擎）。
library;

import 'dart:convert';
import 'dart:io';

import 'zip_index.dart';

const Map<String, String> forbiddenLibraries = {
  'libmpv.so': 'media_kit Android libs 不应进入 APK',
  'libmediakitandroidhelper.so': 'media_kit Android helper 不应进入 APK',
  'libcnativeapi.so': 'nativeapi 桌面专用，Android 应排除',
};

const Map<String, String> requiredLibraries = {
  'libsqlite3.so': 'drift 运行期必需（docs/pitfalls.md）',
  'libquickjs_c_bridge_plugin.so': 'LX 音源引擎必需',
};

class ZipSizeEntry {
  const ZipSizeEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  final String name;
  final int compressedSize;
  final int uncompressedSize;
}

class SizeGroup {
  SizeGroup();

  int count = 0;
  int uncompressed = 0;
  int compressed = 0;
}

class ApkReport {
  ApkReport({
    required this.path,
    required this.size,
    required this.groups,
    required this.libs,
    required this.top,
  });

  final String path;
  final int size;
  final Map<String, SizeGroup> groups;
  final List<ZipSizeEntry> libs;
  final List<ZipSizeEntry> top;

  /// 供测试与 JSON 输出：分组按压缩后大小降序；同分时保持首次出现的顺序
  /// （与体积基线表 / 旧 Python 实现一致，避免同分组的行序漂移）。
  List<MapEntry<String, SizeGroup>> get sortedGroups {
    final entries = groups.entries.toList();
    final order = <String, int>{
      for (var index = 0; index < entries.length; index++)
        entries[index].key: index,
    };
    entries.sort((a, b) {
      final bySize = b.value.compressed.compareTo(a.value.compressed);
      return bySize != 0 ? bySize : order[a.key]!.compareTo(order[b.key]!);
    });
    return entries;
  }
}

/// 1024 进制、两位小数（与 py / 体积基线表一致）。
String humanBytes(int bytes) {
  const suffixes = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  for (final suffix in suffixes) {
    if (value < 1024 || suffix == 'GB') {
      return suffix == 'B'
          ? '${value.toInt()}B'
          : '${value.toStringAsFixed(2)}$suffix';
    }
    value /= 1024;
  }
  return '${bytes}B';
}

/// APK 内的顶层分组名：按已知前缀归类，其余取首段目录名。
String groupOf(String entryName) {
  const prefixes = {
    'lib/': 'lib/',
    'assets/flutter_assets/': 'flutter_assets/',
    'res/': 'res/',
    'META-INF/': 'META-INF/',
    'kotlin/': 'kotlin/',
  };
  for (final entry in prefixes.entries) {
    if (entryName.startsWith(entry.key)) return entry.value;
  }
  if (entryName.endsWith('.dex')) return 'dex';
  final slash = entryName.indexOf('/');
  return slash < 0 ? entryName : entryName.substring(0, slash);
}

ApkReport inspectApk(File file) {
  final entries = readZipDirectory(file);
  final groups = <String, SizeGroup>{};
  final libs = <ZipSizeEntry>[];
  for (final entry in entries) {
    final group = groups.putIfAbsent(groupOf(entry.name), SizeGroup.new);
    group.count += 1;
    group.uncompressed += entry.uncompressedSize;
    group.compressed += entry.compressedSize;
    if (entry.name.startsWith('lib/')) {
      libs.add(
        ZipSizeEntry(
          name: entry.name,
          compressedSize: entry.compressedSize,
          uncompressedSize: entry.uncompressedSize,
        ),
      );
    }
  }
  libs.sort((a, b) => b.compressedSize.compareTo(a.compressedSize));
  final top =
      entries
          .map(
            (entry) => ZipSizeEntry(
              name: entry.name,
              compressedSize: entry.compressedSize,
              uncompressedSize: entry.uncompressedSize,
            ),
          )
          .toList()
        ..sort((a, b) => b.compressedSize.compareTo(a.compressedSize));

  return ApkReport(
    path: file.path,
    size: file.lengthSync(),
    groups: groups,
    libs: libs,
    top: top.take(10).toList(),
  );
}

/// 返回违反发布约束的说明；空列表表示通过。
List<String> checkApk(ApkReport report) {
  final names = report.libs.map((entry) => entry.name.split('/').last).toSet();
  final errors = <String>[];
  for (final entry in forbiddenLibraries.entries) {
    if (names.contains(entry.key)) {
      errors.add('发现禁止库 ${entry.key}：${entry.value}');
    }
  }
  for (final entry in requiredLibraries.entries) {
    if (!names.contains(entry.key)) {
      errors.add('缺少必需库 ${entry.key}：${entry.value}');
    }
  }
  return errors;
}

String renderApkMarkdown(ApkReport report) {
  final buffer = StringBuffer()
    ..writeln('# ${report.path}')
    ..writeln('APK: ${humanBytes(report.size)} (${report.size} B)')
    ..writeln()
    ..writeln('| 分组 | 文件数 | 未压缩 | 压缩后 |')
    ..writeln('| --- | ---: | ---: | ---: |');
  for (final entry in report.sortedGroups) {
    final group = entry.value;
    buffer.writeln(
      '| ${entry.key} | ${group.count} | ${humanBytes(group.uncompressed)} | '
      '${humanBytes(group.compressed)} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('## lib/ 明细')
    ..writeln('| 库 | 未压缩 | 压缩后 |')
    ..writeln('| --- | ---: | ---: |');
  for (final lib in report.libs) {
    buffer.writeln(
      '| ${lib.name.split('/').last} | ${humanBytes(lib.uncompressedSize)} | '
      '${humanBytes(lib.compressedSize)} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('## 最大条目（压缩后）');
  for (final entry in report.top) {
    buffer.writeln('- ${humanBytes(entry.compressedSize)}  ${entry.name}');
  }
  return buffer.toString();
}

String renderApkJson(ApkReport report) {
  final payload = {
    'path': report.path,
    'size': report.size,
    'groups': {
      for (final entry in report.groups.entries)
        entry.key: {
          'count': entry.value.count,
          'uncompressed': entry.value.uncompressed,
          'compressed': entry.value.compressed,
        },
    },
    'libs': [
      for (final lib in report.libs)
        {
          'name': lib.name,
          'uncompressed': lib.uncompressedSize,
          'compressed': lib.compressedSize,
        },
    ],
    'top': [
      for (final item in report.top)
        {
          'name': item.name,
          'uncompressed': item.uncompressedSize,
          'compressed': item.compressedSize,
        },
    ],
  };
  return jsonEncode(payload);
}
