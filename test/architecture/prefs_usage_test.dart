import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 设备本地设置持久化棘轮（stage 1）：
///
/// - 新代码访问 `SharedPreferences` 只准经过 `lib/data/settings/` 里的
///   `DeviceSettings`（统一键表 / JSON 路径 / 串行写 / 失败策略）；
/// - 迁移前已有的直连文件登记为白名单，只减不增；条目不再直连视为陈旧条目，
///   同样失败，防止白名单长期掩盖新违规。
///
/// 规则与 `module_layout_test.dart` 的体积 / 依赖棘轮互补：那条管文件布局，
/// 这条管「设备本地键的存储入口」。
const Set<String> _legacyPrefsWhitelist = {
  'lib/data/sync/sync_state_store.dart',
  'lib/providers/collection_mode.dart',
  'lib/providers/library_collections.dart',
  'lib/providers/theme_provider.dart',
  'lib/services/ai/ai_recommendation_store.dart',
  'lib/services/artwork_palette_seed_store.dart',
  'lib/services/cache_service.dart',
  'lib/services/covers/custom_cover_store.dart',
  'lib/services/data_saver_service.dart',
  'lib/services/download/download_settings.dart',
  'lib/services/haptics.dart',
  'lib/services/library/playlist_folder_prefs.dart',
  'lib/services/local_cover_identity_sweep.dart',
  'lib/services/local/music_folders.dart',
  'lib/services/lyrics_cache.dart',
  'lib/services/playback_observer.dart',
  'lib/services/playback_session_store.dart',
  'lib/services/scrobble/scrobble_outbox.dart',
  'lib/services/scrobble/scrobble_preferences.dart',
  'lib/services/update/update_preferences.dart',
  'lib/services/window/tray_settings.dart',
  'lib/services/window/window_bounds_store.dart',
  'lib/services/window/window_settings.dart',
};

/// 直连存储的入口形式；`DeviceSettings` 内部实现是唯一允许的调用点。
const List<String> _forbiddenPatterns = [
  'SharedPreferences.getInstance',
  'SharedPreferencesAsync',
];

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
      final hits = _forbiddenHits(path);
      if (hits.isEmpty) continue;
      stillUsing.add(path);
      if (!_legacyPrefsWhitelist.contains(path)) {
        offenders.add('$path:${hits.first.line}  ${hits.first.pattern}');
      }
    }
    final stale = _legacyPrefsWhitelist.difference(stillUsing).toList()..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          '设备本地键请用 `$_modulePath` 的 `DeviceSettings`（键名 / 默认值登记在 '
          '`lib/data/settings/device_settings_keys.dart`）：它提供统一的 JSON 路径、'
          '串行写与读写失败策略；新增直连会绕开这些约束：\n'
          '${offenders.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: '白名单条目已不再直连 SharedPreferences，请删除：\n${stale.join('\n')}',
    );
  });
}

typedef _ForbiddenHit = ({int line, String pattern});

/// 只拦截代码行：注释里讨论 `SharedPreferences` 是允许的。
List<_ForbiddenHit> _forbiddenHits(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final hits = <_ForbiddenHit>[];
  final lines = file.readAsLinesSync();
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.trimLeft().startsWith('//')) continue;
    for (final pattern in _forbiddenPatterns) {
      if (line.contains(pattern)) {
        hits.add((line: index + 1, pattern: pattern));
        break;
      }
    }
  }
  return hits;
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
