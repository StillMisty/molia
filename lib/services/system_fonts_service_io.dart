import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'sfnt_families.dart';

/// 设备已安装字体族枚举（应用字体 / 海报字体选择的公共数据源）。
///
/// 各平台数据源均与渲染器同源，返回的名字可直接被 `TextStyle.fontFamily`
/// 解析：
/// - Android：解析系统字体配置（`fonts.xml` 系列）中的 family/alias 名字，
///   与 Skia 的字体匹配逻辑一致。该配置属于字体数据（`font_data_file`，
///   app.te 明确允许应用读取），Flutter 引擎自身也解析同一文件构建字体族；
/// - iOS/macOS：`UIFont.familyNames`（Runner 注册的 `system_fonts` 通道）；
/// - Linux：`fc-list : family`（fontconfig，与桌面端渲染同源）；
/// - Windows：扫描系统 / 用户字体目录并合并注册表
///   （`…\CurrentVersion\Fonts` 的 HKLM + HKCU，覆盖自定义安装目录），
///   家族名从字体文件 `name` 表解析（与 DirectWrite 家族名同源）；
/// - 其它平台：空列表（没有枚举实现），调用方回退「系统默认」。
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

  /// Windows 系统 UI 字体族（未自定义「应用字体」时的默认）。
  ///
  /// 来源是 `HKCU\Control Panel\Desktop\WindowMetrics\MessageFont` 的
  /// LOGFONTW face name：中文 Windows 通常是 `Microsoft YaHei UI`，英文
  /// 系统是 `Segoe UI`。它与原生 Win32 窗口同源，也能跟随用户在系统里
  /// 改的窗口字体；非 Windows / 解析失败为 null（交给引擎默认排版）。
  static String? get platformDefaultFamily => _platformDefaultFamily;

  static String? _platformDefaultFamily;

  /// 系统字体缺字时的回退链（仅 Windows）。
  ///
  /// DirectWrite 逐字选择，只有主字体没有该字形才会走到这里：CJK 兜底到
  /// 中文 UI 字体，Latin/符号兜底到 Segoe UI。不要依赖 Flutter 的 CJK
  /// 回退——它由平台决定且不保证选中系统 UI 字体
  /// （flutter/flutter#103811）。
  static const List<String> windowsSystemFontFallbacks = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ];

  /// 系统默认字体缺失字形时的回退链；没有系统默认字体时为 null。
  static List<String>? get platformDefaultFontFallbacks =>
      _platformDefaultFamily == null ? null : windowsSystemFontFallbacks;

  /// 启动时解析一次 Windows 系统 UI 字体（组合根在 runApp 前 await；
  /// 其它平台是空操作）。
  ///
  /// 失败 / 超时保持 null：回退引擎默认字体，不影响启动。
  static Future<void> loadPlatformDefaultFamily() async {
    if (!Platform.isWindows) return;
    try {
      _platformDefaultFamily = await _windowsMessageFontFamily().timeout(
        const Duration(seconds: 1),
        onTimeout: () => null,
      );
    } catch (_) {
      _platformDefaultFamily = null;
    }
  }

  /// 解析 `reg query … /v MessageFont` 的 `REG_BINARY` 输出为字体族名。
  ///
  /// `MessageFont` 是 LOGFONTW：前 28 字节是高度/宽度/字重等字段，
  /// 之后是 32 个 UTF-16LE 字符的 face name（以 NUL 结束）。hex 行可能
  /// 被 reg.exe 折行，按「后续只含 hex 字符的行」续读。解析不出返回 null
  /// （回退引擎默认字体）。
  static String? parseWindowsMessageFontOutput(String output) {
    final buffer = StringBuffer();
    var found = false;
    // reg.exe 在 Windows 上输出 CRLF；按行拆时把 \r 一并吃掉，
    // 否则续行的纯 hex 正则会被行尾 \r 破坏、只解析到第一段。
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (!found) {
        final marker = RegExp(r'MessageFont[ \t]{2,}REG_BINARY');
        final match = marker.firstMatch(line);
        if (match == null) continue;
        found = true;
        buffer.write(_hexDigits(line.substring(match.end)));
        continue;
      }
      // 续行只可能是纯 hex（reg.exe 的折行）；其它行说明值已结束。
      if (!RegExp(r'^[ \t]*[0-9a-fA-F \t]+$').hasMatch(line)) break;
      buffer.write(_hexDigits(line));
    }
    final hex = buffer.toString();
    if (hex.length < 60) return null; // 至少要有 face name 的首字符
    final bytes = <int>[
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    // 28 字节头部之后是 UTF-16LE face name（NUL 结束）。
    final chars = <int>[];
    for (var i = 28; i + 1 < bytes.length; i += 2) {
      final unit = bytes[i] | (bytes[i + 1] << 8);
      if (unit == 0) break;
      chars.add(unit);
    }
    if (chars.isEmpty) return null;
    final name = String.fromCharCodes(chars).trim();
    return name.isEmpty ? null : name;
  }

  static String _hexDigits(String text) =>
      text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');

  static Future<String?> _windowsMessageFontFamily() async {
    final result = await Process.run(
      'reg.exe',
      <String>[
        'query',
        r'HKCU\Control Panel\Desktop\WindowMetrics',
        '/v',
        'MessageFont',
      ],
    );
    if (result.exitCode != 0) return null;
    return parseWindowsMessageFontOutput('${result.stdout}');
  }

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
      } else if (Platform.isWindows) {
        families = await _windowsFamilies();
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

  /// 可解析家族名的字体文件扩展名（点阵 `.fon`、Type 1 `.pfb` 都不是 sfnt）。
  static final RegExp _sfntFilePattern =
      RegExp(r'\.(ttf|otf|ttc|otc)$', caseSensitive: false);

  /// Windows 字体枚举：目录扫描合并注册表条目，家族名从字体文件 `name`
  /// 表解析；文件解析整体失败时回退注册表值名（有样式后缀、不保证可解析，
  /// 只保证列表不为空）。
  static Future<List<String>> _windowsFamilies() async {
    final fontDir = _windowsFontDir;
    final files = <String>{};
    for (final dir in _windowsFontDirs) {
      files.addAll(await _listFontFiles(dir));
    }

    final entries = <({String name, String file})>[];
    for (final key in _windowsFontRegistryKeys) {
      entries.addAll(await _windowsRegistryEntries(key));
    }
    for (final entry in entries) {
      final resolved = _resolveWindowsFontFile(entry.file, fontDir);
      if (resolved != null) files.add(resolved);
    }

    final families = <String>{};
    for (final path in files) {
      families.addAll(await _fontFileFamilies(path));
    }
    if (families.isEmpty) {
      for (final entry in entries) {
        families.addAll(parseWindowsFontRegistryName(entry.name));
      }
    }
    return families.toList()..sort(_compareNames);
  }

  /// Windows 注册表字体键：HKLM 是机器级安装，HKCU 是「仅为我安装」
  /// （Win10 1809+ 免管理员，字体落在 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`）。
  static const List<String> _windowsFontRegistryKeys = <String>[
    r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
    r'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
  ];

  /// 系统字体目录（注册表相对路径的基准）；环境变量缺失返回 null。
  static String? get _windowsFontDir {
    final root =
        Platform.environment['SystemRoot'] ?? Platform.environment['windir'];
    return root == null || root.isEmpty ? null : '$root\\Fonts';
  }

  /// 需扫描的字体目录：系统目录 + 用户安装目录。
  static List<String> get _windowsFontDirs {
    final dirs = <String>[];
    final fontDir = _windowsFontDir;
    if (fontDir != null) dirs.add(fontDir);
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      dirs.add('$localAppData\\Microsoft\\Windows\\Fonts');
    }
    return dirs;
  }

  /// 列目录下的 sfnt 字体文件（字体目录是平铺的，不递归）。
  static Future<List<String>> _listFontFiles(String dir) async {
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) return const <String>[];
      final files = <String>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (_sfntFilePattern.hasMatch(p.basename(entity.path))) {
          files.add(entity.path);
        }
      }
      return files;
    } catch (_) {
      // 目录不可读（权限 / 虚拟化）：跳过，不影响其它来源。
      return const <String>[];
    }
  }

  /// 查询一个注册表键并解析（`reg.exe` 缺失 / 键不存在时返回空）。
  static Future<List<({String name, String file})>> _windowsRegistryEntries(
    String key,
  ) async {
    try {
      final result = await Process.run('reg.exe', <String>['query', key]);
      if (result.exitCode != 0) return const [];
      return parseWindowsFontRegistryOutput('${result.stdout}');
    } catch (_) {
      return const [];
    }
  }

  /// 解析 `reg query "…\CurrentVersion\Fonts"` 输出为「值名 → 文件」条目。
  ///
  /// 行格式（`reg.exe` 固定列宽）：
  /// `    Arial (TrueType)    REG_SZ    arial.ttf`
  /// 值名可含空格与 `&`（TTC 多家族）、可带样式后缀；只保留 sfnt 扩展名的
  /// 条目并跳过 `(Default)`。返回的文件可能是相对 `%SystemRoot%\Fonts`
  /// 的文件名，也可能是绝对路径（字体装在自定义目录时）。
  static List<({String name, String file})> parseWindowsFontRegistryOutput(
    String output,
  ) {
    final entries = <({String name, String file})>[];
    // 列间是固定 4 空格；用 [ \t] 而不是 \s，避免跨行匹配把两行粘成一条。
    final pattern = RegExp(
      r'^[ \t]+(.+?)[ \t]{4,}REG_(?:SZ|EXPAND_SZ)[ \t]{4,}(.+?)[ \t]*$',
      multiLine: true,
    );
    for (final match in pattern.allMatches(output)) {
      final name = match.group(1)!.trim();
      final file = match.group(2)!.trim();
      if (name.isEmpty || name == '(Default)' || file.isEmpty) continue;
      if (!_sfntFilePattern.hasMatch(file)) continue;
      entries.add((name: name, file: file));
    }
    return entries;
  }

  /// 注册表值名 → 家族名候选：去掉结尾的类型后缀（`(TrueType)` /
  /// `(OpenType)` / `(TrueType Collection)` / `(Type 1)`…），再按 `&`
  /// 拆 TTC 多家族。仅作文件解析失败时的兜底，值名常带样式后缀
  /// （`Arial Bold`）而不可被渲染器解析。
  static List<String> parseWindowsFontRegistryName(String valueName) {
    final base = valueName.replaceFirst(RegExp(r'\s*\([^()]*\)\s*$'), '').trim();
    if (base.isEmpty) return const <String>[];
    return <String>[
      for (final part in base.split('&'))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// 注册表文件值 → 绝对路径：`%VAR%` 展开后是绝对路径就原样用，
  /// 否则按 [fontDir] 拼接；无法解析返回 null。
  static String? _resolveWindowsFontFile(String file, String? fontDir) {
    var resolved = file;
    if (resolved.contains('%')) {
      resolved = resolved.replaceAllMapped(
        RegExp(r'%([^%]+)%'),
        (match) => Platform.environment[match.group(1)!] ?? match.group(0)!,
      );
    }
    if (p.isAbsolute(resolved)) return resolved;
    if (fontDir == null) return null;
    return p.join(fontDir, resolved);
  }

  /// 字体文件 → 家族名：只读解析所需区间（CJK 字体集合单文件可达数十 MB）。
  static Future<List<String>> _fontFileFamilies(String path) async {
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      final length = file.lengthSync();
      final source = file;
      return sfntFamilyNames((offset, size) {
        if (offset < 0 || size <= 0 || offset + size > length) {
          return Uint8List(0);
        }
        final bytes = Uint8List(size);
        source.setPositionSync(offset);
        source.readIntoSync(bytes);
        return bytes;
      });
    } catch (_) {
      // 不可读 / 非 sfnt：跳过该文件。
      return const <String>[];
    } finally {
      try {
        await file?.close();
      } catch (_) {
        // 关闭失败不影响已解析结果。
      }
    }
  }

  /// 仅测试使用：清空进程内缓存。
  static void debugResetCache() {
    _cache = null;
  }
}
