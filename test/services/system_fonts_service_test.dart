import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/system_fonts_service.dart';

/// 设备字体枚举的纯解析逻辑测试（不触碰真实系统文件）：
/// Android fonts.xml 与 Linux fc-list 输出 → 去重、排序后的字体族名。
void main() {
  group('SystemFontsService.parseAndroidFontConfig', () {
    test('提取 family 与 alias 的 name，去重并忽略空名', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<familyset version="23">
  <family name="sans-serif">
    <font weight="400" style="normal">Roboto-Regular.ttf</font>
  </family>
  <family lang="zh-Hans" name="Noto Sans CJK SC">
    <font weight="400" style="normal">NotoSansCJK-Regular.ttc</font>
  </family>
  <family name="sans-serif">
    <font weight="700" style="normal">Roboto-Bold.ttf</font>
  </family>
  <family lang="ja">
    <font weight="400" style="normal">NotoSansCJK-Regular.ttc</font>
  </family>
  <alias name="monospace" to="Droid Sans Mono" />
</familyset>
''';
      expect(
        SystemFontsService.parseAndroidFontConfig(xml),
        ['monospace', 'Noto Sans CJK SC', 'sans-serif'],
      );
    });

    test('无 family/alias 时返回空列表', () {
      expect(
        SystemFontsService.parseAndroidFontConfig('<familyset />'),
        isEmpty,
      );
    });
  });

  group('SystemFontsService.parseFcListOutput', () {
    test('每行取第一个语言别名，去重并忽略空行；兼容 style 后缀', () {
      const output = '''
Noto Sans CJK SC,Noto Sans SC:style=Regular
WenQuanYi Micro Hei:style=Regular
Noto Sans CJK SC:style=Bold

DejaVu Sans Mono:style=Book
''';
      expect(
        SystemFontsService.parseFcListOutput(output),
        ['DejaVu Sans Mono', 'Noto Sans CJK SC', 'WenQuanYi Micro Hei'],
      );
    });

    test('逗号分隔的多语言别名只取第一个', () {
      const output = 'Noto Sans CJK SC,Noto Sans SC,思源黑体\n';
      expect(SystemFontsService.parseFcListOutput(output),
          ['Noto Sans CJK SC']);
    });
  });

  group('SystemFontsService.parseWindowsFontRegistryOutput', () {
    // 真实 `reg query` 输出形状：4 空格列宽的「值名 / REG_SZ / 文件」。
    const output = r'''
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts
    (Default)    REG_SZ    (value not set)
    Arial (TrueType)    REG_SZ    arial.ttf
    Arial Bold (TrueType)    REG_SZ    arialbd.ttf
    Cambria & Cambria Math (TrueType)    REG_SZ    cambria.ttc
    Microsoft YaHei & Microsoft YaHei UI (TrueType)    REG_SZ    msyh.ttc
    Noto Sans CJK JP (OpenType)    REG_SZ    C:\Program Files\Fonts\NotoSansCJKjp.otf
    Source Han Sans (Type 1)    REG_SZ    sourcehan.pfb
''';

    test('保留 sfnt 条目（相对 / 绝对路径原样），跳过 (Default) 与非 sfnt', () {
      final entries = SystemFontsService.parseWindowsFontRegistryOutput(output);
      expect(entries.map((entry) => entry.file).toList(), [
        'arial.ttf',
        'arialbd.ttf',
        'cambria.ttc',
        'msyh.ttc',
        r'C:\Program Files\Fonts\NotoSansCJKjp.otf',
      ]);
      expect(entries.first.name, 'Arial (TrueType)');
      expect(entries.last.name, 'Noto Sans CJK JP (OpenType)');
    });

    test('空输出 / 只有键名头时返回空列表', () {
      expect(SystemFontsService.parseWindowsFontRegistryOutput(''), isEmpty);
      expect(
        SystemFontsService.parseWindowsFontRegistryOutput(
          r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
          '\n',
        ),
        isEmpty,
      );
    });
  });

  group('SystemFontsService.parseWindowsFontRegistryName', () {
    test('去掉结尾的类型后缀（TrueType / OpenType / 集合 / Type 1）', () {
      expect(
        SystemFontsService.parseWindowsFontRegistryName('Arial Bold (TrueType)'),
        ['Arial Bold'],
      );
      expect(
        SystemFontsService.parseWindowsFontRegistryName('思源黑体 (OpenType)'),
        ['思源黑体'],
      );
      expect(
        SystemFontsService.parseWindowsFontRegistryName(
          'Some Font (TrueType Collection)',
        ),
        ['Some Font'],
      );
      expect(
        SystemFontsService.parseWindowsFontRegistryName('Old Face (Type 1)'),
        ['Old Face'],
      );
    });

    test('& 拆 TTC 多家族', () {
      expect(
        SystemFontsService.parseWindowsFontRegistryName(
          'Microsoft YaHei & Microsoft YaHei UI (TrueType)',
        ),
        ['Microsoft YaHei', 'Microsoft YaHei UI'],
      );
    });

    test('无后缀名保留原样；只剩后缀返回空', () {
      expect(
        SystemFontsService.parseWindowsFontRegistryName('Bahnschrift'),
        ['Bahnschrift'],
      );
      expect(
        SystemFontsService.parseWindowsFontRegistryName('(TrueType)'),
        isEmpty,
      );
    });
  });

  group('SystemFontsService.listFamilies（真实环境守卫）', () {
    test('Linux 且有 fc-list 时能枚举到字体（否则跳过）', () async {
      if (!Platform.isLinux) return;
      final probe = await Process.run('which', ['fc-list']);
      if (probe.exitCode != 0) return;

      SystemFontsService.debugResetCache();
      final families = await SystemFontsService.listFamilies();
      expect(families, isNotEmpty);
      expect(families, equals(List<String>.of(families)..sort(
            (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
          )));
    });

    test('Windows 能枚举到字体（其它平台跳过）', () async {
      if (!Platform.isWindows) return;

      SystemFontsService.debugResetCache();
      final families = await SystemFontsService.listFamilies();
      expect(families, isNotEmpty);
      expect(families, equals(List<String>.of(families)..sort(
            (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
          )));
      // 文件解析取的是真家族名：注册表值名里的样式后缀不应出现在列表里。
      expect(families.where((name) => name.endsWith(' (TrueType)')), isEmpty);
    });
  });
}
