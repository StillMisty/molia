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
  });
}
