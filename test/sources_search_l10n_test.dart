import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/l10n/app_localizations_zh.dart';

/// 音源管理页 / 搜索结果页 l10n 回归测试。
///
/// 重点保障：
/// - 新增的 sources* / search* 键在中文中齐全（en 为模板）；
/// - 已去除日文/繁体支持（arb 与 supportedLocales 均不再包含）。
/// - 集成测试依赖的中文文案保持不变（zh 环境行为不回归）。
Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final en = _arb('app_en.arb');
  final zh = _arb('app_zh.arb');

  // 音源管理页新增键（en 为模板，其余语言必须有对应翻译）。
  final sourceKeys = en.keys
      .where((key) => key.startsWith('sources') && !key.startsWith('@'))
      .toList();

  // 搜索页新增键。
  const searchKeys = [
    'searchFailed',
    'searchNoSourcesTitle',
    'searchNoSourcesHint',
    'searchNoResultsInSource',
    'searchLoadMore',
    'searchLoadMoreWithTotal',
  ];

  test('音源/搜索新增键在中文中齐全', () {
    expect(sourceKeys, isNotEmpty);
    for (final key in [...sourceKeys, ...searchKeys]) {
      final value = zh[key];
      expect(value, isA<String>(), reason: 'zh 缺少 $key');
      expect((value as String).trim(), isNotEmpty, reason: 'zh 的 $key 为空');
    }
  });

  test('日文/繁体支持已移除', () {
    expect(File('lib/l10n/app_ja.arb').existsSync(), isFalse);
    expect(File('lib/l10n/app_zh_TW.arb').existsSync(), isFalse);
    expect(AppLocalizations.supportedLocales,
        isNot(contains(const Locale('ja'))));
    expect(AppLocalizations.supportedLocales,
        isNot(contains(const Locale('zh', 'TW'))));
  });

  test('集成测试依赖的中文文案保持不变', () {
    expect(zh['sourcesTitle'], '音源管理');
    expect(zh['sourcesImportFromText'], '粘贴脚本导入');
    expect(zh['sourcesContinueImport'], '继续导入');
    expect(zh['sourcesImportAction'], '导入');
    expect(zh['sourcesQuality320k'], '320K');
    expect(zh['sourcesNoScripts'],
        '还没有导入音源脚本。社区音源可在 Github 搜索 “lx-music-source” 获取。');
    expect(zh['sourcesNoSearchableSources'],
        '当前没有可搜索的音源。启用音源脚本后，这里会列出可搜索的平台。');
  });

  test('生成的本地化类包含中文关键文案', () {
    final zhL10n = AppLocalizationsZh();
    expect(zhL10n.sourcesTitle, '音源管理');
    expect(zhL10n.sourcesImportFromText, '粘贴脚本导入');
    expect(zhL10n.sourcesContinueImport, '继续导入');
    expect(zhL10n.sourcesImportAction, '导入');
    expect(zhL10n.sourcesQuality320k, '320K');
    expect(zhL10n.sourcesNoScripts,
        '还没有导入音源脚本。社区音源可在 Github 搜索 “lx-music-source” 获取。');
    expect(zhL10n.sourcesActiveSource('集成测试音源', '1.0.0'),
        '当前音源：集成测试音源 1.0.0');
    expect(zhL10n.searchNoResultsInSource('测试源'), '在「测试源」中没有找到结果');
    expect(zhL10n.searchLoadMoreWithTotal(42), '加载更多（共 42 首）');

    final enL10n = lookupAppLocalizations(const Locale('en'));
    expect(enL10n.sourcesTitle, 'Source Management');
    expect(enL10n.searchNoResultsInSource('Demo'), 'No results found in “Demo”');
  });
}
