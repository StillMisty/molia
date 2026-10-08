import 'dart:io';

import 'package:flutter/services.dart';

/// 设备已安装字体族枚举（应用字体 / 海报字体选择的公共数据源）。
///
/// 各平台数据源均与渲染器同源，返回的名字可直接被 `TextStyle.fontFamily`
/// 解析：
/// - Android：解析系统字体配置（`fonts.xml` 系列）中的 family/alias 名字，
///   与 Skia 的字体匹配逻辑一致。该配置属于字体数据（`font_data_file`，
///   app.te 明确允许应用读取），Flutter 引擎自身也解析同一文件构建字体族；
/// - iOS/macOS：`UIFont.familyNames`（Runner 注册的 `system_fonts` 通道）；
/// - Linux：`fc-list : family`（fontconfig，与桌面端渲染同源）；
/// - Web/其它：空列表（浏览器无法枚举本地字体），调用方回退「系统默认」。
///
/// 结果在进程内缓存；字体安装变化后由 [debugResetCache] 或重启刷新。
class SystemFontsService {
  SystemFontsService._();

  static const MethodChannel _channel =
      MethodChannel('top.stillmisty.molia/system_fonts');

  /// Android 字体族定义文件（不同系统版本/厂商分区，存在即解析；
  /// 权限不可读的路径静默跳过）。
  static const List<String> _androidFontConfigPaths = <String>[
    '/system/etc/fonts.xml',
    '/system/etc/fonts_customization.xml',
    '/system_ext/etc/fonts_customization.xml',
    '/product/etc/fonts_customization.xml',
    '/vendor/etc/fonts_customization.xml',
    '/oem/etc/fonts_customization.xml',
    '/data/fonts/config/config.xml',
  ];

  static List<String>? _cache;

  /// 列出设备字体族名（去重、大小写不敏感排序）；失败或平台不支持时返回空列表。
  static Future<List<String>> listFamilies() async {
    final cached = _cache;
    if (cached != null) return cached;
    List<String> families;
    try {
      if (Platform.isAndroid) {
        families = await _androidFamilies();
      } else if (Platform.isIOS || Platform.isMacOS) {
        families =
            await _channel.invokeListMethod<String>('listFamilies') ??
                const <String>[];
      } else if (Platform.isLinux) {
        families = await _linuxFamilies();
      } else {
        families = const <String>[];
      }
    } catch (_) {
      families = const <String>[];
    }
    _cache = families;
    return families;
  }

  /// 解析 Android fonts.xml 文本中的 `<family name>` / `<alias name>`
  /// （alias 名字同样可被 `TextStyle.fontFamily` 解析，一并提供）。
  static List<String> parseAndroidFontConfig(String xml) {
    final names = <String>{};
    final tagPattern = RegExp(r'<(?:family|alias)\b[^>]*>');
    final namePattern = RegExp(r'name\s*=\s*"([^"]+)"');
    for (final tag in tagPattern.allMatches(xml)) {
      final name = namePattern.firstMatch(tag.group(0)!)?.group(1)?.trim();
      if (name != null && name.isNotEmpty) {
        names.add(name);
      }
    }
    return names.toList()..sort(_compareNames);
  }

  /// 解析 `fc-list : family` 输出：每行可能带逗号分隔的多语言别名，
  /// 取第一个；兼容带 `:style=...` 后缀的格式。
  static List<String> parseFcListOutput(String output) {
    final names = <String>{};
    for (final line in output.split('\n')) {
      final name = line.split(':').first.split(',').first.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names.toList()..sort(_compareNames);
  }

  static int _compareNames(String a, String b) =>
      a.toLowerCase().compareTo(b.toLowerCase());

  static Future<List<String>> _androidFamilies() async {
    final names = <String>{};
    for (final path in _androidFontConfigPaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        names.addAll(parseAndroidFontConfig(await file.readAsString()));
      } catch (_) {
        // 个别分区/目录应用不可读：跳过，不影响其余来源。
      }
    }
    return names.toList()..sort(_compareNames);
  }

  static Future<List<String>> _linuxFamilies() async {
    final result = await Process.run('fc-list', <String>[':', 'family']);
    if (result.exitCode != 0) return const <String>[];
    return parseFcListOutput('${result.stdout}');
  }

  /// 仅测试使用：清空进程内缓存。
  static void debugResetCache() {
    _cache = null;
  }
}
