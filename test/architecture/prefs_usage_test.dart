import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 设备本地设置持久化棘轮（stage 1）：
///
/// - 新代码访问 `SharedPreferences` 只准经过 `lib/data/settings/` 里的
///   `DeviceSettings`（统一键表 / JSON 路径 / 模块级串行写 / 失败策略）；
/// - 迁移前已有的直连文件登记为白名单，只减不增；条目不再直连视为陈旧条目，
///   同样失败，防止白名单长期掩盖新违规。
///
/// 匹配前先去掉注释（行注释 / 文档注释 / 块注释）再压掉空白：折行调用
/// （`Shared\nPreferences`）与别名调用（`sp.SharedPreferences`）都会命中。
/// 规则与 `module_layout_test.dart` 的体积 / 依赖棘轮互补：那条管文件布局，
/// 这条管「设备本地键的存储入口」。
///
/// 白名单只剩**不是设置**的设备本地状态：缓存 / 索引 / 会话 / 同步记账 /
/// AI 历史 / 发件箱。它们要么是可重算的派生数据、要么有独立协议与清扫逻辑，
/// 收进 `DeviceSettings` 只会把「设置」边界搅浑；真正的设置项已全部迁移。
const Set<String> _legacyPrefsWhitelist = {
  // 同步记账 / 本地会话：有各自的合并协议与版本，不是用户可编辑的设置。
  'lib/data/sync/sync_state_store.dart',
  'lib/services/playback_session_store.dart',
  'lib/services/playback_observer.dart',
  'lib/services/scrobble/scrobble_outbox.dart',
  'lib/services/scrobble/scrobble_preferences.dart',
  // 缓存 / 索引 / 一次性迁移标记：可重算或只写一次，不进设置 UI。
  'lib/services/ai/ai_recommendation_store.dart',
  'lib/services/artwork_palette_seed_store.dart',
  'lib/services/covers/custom_cover_store.dart',
  'lib/services/lyrics_cache.dart',
  'lib/services/lyrics_service.dart',
  'lib/services/local_cover_identity_sweep.dart',
  // UI 状态（顺序 / 浏览形态）：等待单独收拢，当前不在 stage 2 清单里。
  'lib/providers/library_collections.dart',
};

/// 直连存储的类名；`SharedPreferencesAsync` / `SharedPreferencesWithCache`
/// 都包含这个 token。
const String _prefsToken = 'SharedPreferences';

/// 设备本地设置的唯一模块入口（消息里点名，避免只说「不要用」）。
const String _modulePath = 'lib/data/settings/device_settings.dart';

const String _moduleDir = 'lib/data/settings/';

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('设备本地设置只经 $_modulePath 访问 SharedPreferences（白名单只减不增）', () {
    final offenders = <String>[];
    final stillUsing = <String>{};
    for (final path in files.where((path) => !path.startsWith(_moduleDir))) {
      if (!_usesSharedPreferences(File(path).readAsStringSync())) continue;
      stillUsing.add(path);
      if (!_legacyPrefsWhitelist.contains(path)) offenders.add(path);
    }
    final stale = _legacyPrefsWhitelist.difference(stillUsing).toList()..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          '设备本地键请用 `$_modulePath` 的 `DeviceSettings`（键名 / 默认值 / '
          'JSON 字段形状登记在 `lib/data/settings/device_settings_keys.dart`）：'
          '它提供统一的 JSON 路径、模块级串行写与读写失败策略；新增直连会绕开'
          '这些约束：\n${offenders.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: '白名单条目已不再直连 SharedPreferences，请删除：\n${stale.join('\n')}',
    );
  });

  group('扫描器', () {
    test('注释里的提及不算违规', () {
      expect(
        _usesSharedPreferences('// SharedPreferences.getInstance()'),
        isFalse,
      );
      expect(_usesSharedPreferences('/// 不要用 SharedPreferences'), isFalse);
      expect(
        _usesSharedPreferences('/* SharedPreferencesAsync */\nvoid f() {}'),
        isFalse,
      );
    });

    test('别名调用与折行调用都算违规', () {
      expect(
        _usesSharedPreferences(
          "import 'package:shared_preferences/shared_preferences.dart' as sp;\n"
          'final prefs = sp.SharedPreferences.getInstance();',
        ),
        isTrue,
      );
      expect(
        _usesSharedPreferences(
          'final prefs = Shared\n  Preferences\n  .getInstance();',
        ),
        isTrue,
      );
    });

    test('Async / WithCache 变体都算违规', () {
      expect(
        _usesSharedPreferences('final p = SharedPreferencesAsync();'),
        isTrue,
      );
      expect(
        _usesSharedPreferences(
          'final p = SharedPreferencesWithCache.create();',
        ),
        isTrue,
      );
    });

    test('构造参数直接依赖 SharedPreferences 算违规，依赖 DeviceSettings 不算', () {
      expect(
        _usesSharedPreferences(
          'class Store { Store({required SharedPreferences prefs}); }',
        ),
        isTrue,
        reason: '迁移后的 store 不应再拿到 prefs 句柄',
      );
      expect(
        _usesSharedPreferences(
          'class Store { Store({DeviceSettings? settings}); }',
        ),
        isFalse,
      );
    });
  });
}

/// 去掉注释并压掉所有空白后匹配 [prefsToken]。
bool _usesSharedPreferences(String source) =>
    _stripDartComments(source)
        .replaceAll(RegExp(r'\s+'), '')
        .contains(_prefsToken);

/// 去掉 `//` / `///` / `/* */` 注释，保留字符串字面量内容与换行。
///
/// 不是完整的 Dart lexer：只需要避免注释里的讨论造成误报，以及不把字符串
/// 里的 `//`（如 URL）当成注释吞掉后面的代码。普通单行 / 双行字符串足以
/// 覆盖本仓代码；三引号字符串按普通字符串处理。
String _stripDartComments(String source) {
  final out = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final current = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';

    if (current == '/' && next == '/') {
      while (index < source.length && source[index] != '\n') {
        index++;
      }
      continue;
    }
    if (current == '/' && next == '*') {
      index += 2;
      while (index + 1 < source.length &&
          !(source[index] == '*' && source[index + 1] == '/')) {
        index++;
      }
      index = index + 1 < source.length ? index + 2 : source.length;
      out.write(' ');
      continue;
    }
    if (current == "'" || current == '"') {
      final quote = current;
      out.write(current);
      index++;
      while (index < source.length) {
        final char = source[index];
        out.write(char);
        index++;
        if (char == r'\' && index < source.length) {
          out.write(source[index]);
          index++;
          continue;
        }
        if (char == quote) break;
        // 未闭合的普通字符串：停在行尾，避免把后续代码全部当成字符串。
        if (char == '\n') break;
      }
      continue;
    }
    out.write(current);
    index++;
  }
  return out.toString();
}

List<String> _libFiles() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => _normalize(file.path))
      .where((path) => path.endsWith('.dart'))
      .toList()
    ..sort();
}

String _normalize(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  final out = <String>[];
  for (final part in parts) {
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      out.add(part);
    }
  }
  return out.join('/');
}
