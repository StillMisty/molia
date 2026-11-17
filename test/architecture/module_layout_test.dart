import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Phase 0 模块布局守卫（重构地基）：
/// - 退役的顶层目录不得复活（模型统一在 `lib/domain/models/`，服务在 `lib/services/`）；
/// - `lib/**` 单文件体积棘轮：当前超限文件登记后只允许缩小，不允许新增；
/// - `pages/widgets` 不新增对 `lib/data/**` 的直接依赖；
/// - `lib/utils/**` 保持纯工具：不反向依赖 UI / 状态 / 数据层。
///
/// 白名单只减不增：新增违规必须修复；条目不再违规视为陈旧条目，同样失败，
/// 防止白名单长期掩盖新违规。规则与 `layering_test.dart` 互补（后者管分层方向）。
const List<String> _retiredTopLevelDirs = ['lib/models', 'lib/managers'];

const int _fileSizeLimit = 800;

/// 本任务开始时就已超限的文件（只减不增；降回 ≤800 行后删除条目）。
const Set<String> _sizeWhitelist = {
  'lib/data/library_repository.dart',
  'lib/data/library_write_engine.dart',
  'lib/data/play_statistics_repository.dart',
  'lib/data/sync/pairing/lan_pairing_service.dart',
  'lib/data/sync/sync_round.dart',
  'lib/data/sync/transport/lan_discovery.dart',
  'lib/data/sync/transport/lan_sync_transport.dart',
  'lib/data/sync/transport/webdav_sync_transport.dart',
  'lib/domain/models/ai_dj.dart',
  'lib/domain/models/device_sync.dart',
  'lib/pages/ai_dj_page.dart',
  'lib/pages/annual_report_page.dart',
  'lib/pages/favorites.dart',
  'lib/pages/play_statistics_page.dart',
  'lib/pages/sources_page.dart',
  'lib/playback/local_playback_service.dart',
  'lib/playback/playback_session_coordinator.dart',
  'lib/providers/ai_dj_provider.dart',
  'lib/providers/collection_session.dart',
  'lib/providers/library_provider.dart',
  'lib/providers/playback_provider.dart',
  'lib/services/ai/ai_recommendation_service.dart',
  'lib/services/covers/custom_cover_store.dart',
  'lib/services/download/download_service.dart',
  'lib/services/lyrics_display/lyrics_display_settings.dart',
  'lib/services/window/window_chrome_io.dart',
  'lib/sources/builtin/tx_qrc.dart',
  'lib/sources/lx/lx_engine_native.dart',
  'lib/sources/source_manager.dart',
  'lib/widgets/discover_playlists_tab.dart',
  'lib/widgets/lyrics.dart',
  'lib/widgets/player.dart',
  'lib/widgets/player_cover_deck.dart',
  'lib/widgets/search_results_view.dart',
  'lib/widgets/settings/settings_tiles.dart',
};

/// 生成物 / vendored 数据不参与体积棘轮。
const Set<String> _sizeExcludedFiles = {
  'lib/data/molia_database.steps.dart',
  'lib/utils/html_unescape/src/data/named_chars_all.dart',
};

/// 现存 `pages/widgets -> lib/data` 依赖（只减不增，后续阶段清）。
const Set<String> _uiDataImportWhitelist = {
  'lib/pages/album_page.dart',
  'lib/pages/artist_page.dart',
  'lib/pages/sync_dialogs.dart',
  'lib/pages/sync_log_page.dart',
  'lib/pages/update_settings_page.dart',
  'lib/widgets/lxmc_import.dart',
};

/// 现存不纯的 utils 文件（只减不增，后续阶段清）。
const Set<String> _utilsImpureWhitelist = {
  'lib/utils/data_saver_subtitle.dart',
  'lib/utils/download_failure_label.dart',
  'lib/utils/download_task_label.dart',
  'lib/utils/listened_duration.dart',
  'lib/utils/lyrics_provider_label.dart',
  'lib/utils/poster_render_style.dart',
  'lib/utils/responsive.dart',
  'lib/utils/save_as_label.dart',
  'lib/utils/smart_list_rows.dart',
  'lib/utils/source_quality_label.dart',
  'lib/utils/track_local_data_label.dart',
};

const List<String> _utilsForbiddenPathPrefixes = [
  'lib/widgets/',
  'lib/providers/',
  'lib/services/',
  'lib/data/',
  'lib/pages/',
  'lib/l10n/',
];

const List<String> _utilsForbiddenPackagePrefixes = [
  'package:material_ui/',
  'package:material_3_expressive/',
];

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('退役顶层目录不存在（lib/models、lib/managers）', () {
    final found = [
      for (final dir in _retiredTopLevelDirs)
        if (Directory(dir).existsSync()) dir,
    ];
    expect(
      found,
      isEmpty,
      reason:
          '这些目录已退役：模型放 lib/domain/models/，服务放 lib/services/。\n'
          '${found.join('\n')}',
    );
  });

  test('lib/** 单文件体积棘轮（≤$_fileSizeLimit 行，白名单只减不增）', () {
    final oversize = <String>[];
    for (final path in files.where((path) => !_isSizeExcluded(path))) {
      if (_lineCount(path) > _fileSizeLimit) {
        oversize.add('$path（${_lineCount(path)} 行）');
      }
    }
    final unexpected = oversize
        .where((entry) => !_sizeWhitelist.contains(entry.split('（').first))
        .toList();

    final stale = <String>[];
    for (final path in _sizeWhitelist) {
      if (!files.contains(path)) {
        stale.add('$path（文件不存在）');
      } else if (_lineCount(path) <= _fileSizeLimit) {
        stale.add('$path（${_lineCount(path)} 行）');
      }
    }

    expect(
      unexpected,
      isEmpty,
      reason:
          '新增超过 $_fileSizeLimit 行的文件；请拆分为更小的模块，'
          '或评审后登记 _sizeWhitelist：\n${unexpected.join('\n')}',
    );
    expect(stale, isEmpty, reason: '体积白名单条目已过期，请删除：\n${stale.join('\n')}');
  });

  test('pages/widgets 不新增对 lib/data/** 的直接依赖（白名单只减不增）', () {
    final offenders = <String>[];
    final stillViolating = <String>{};
    for (final path in files.where(
      (path) =>
          path.startsWith('lib/pages/') || path.startsWith('lib/widgets/'),
    )) {
      for (final ref in _importsOf(path)) {
        final target = _resolve(path, ref);
        if (!target.startsWith('lib/data/')) continue;
        stillViolating.add(path);
        if (!_uiDataImportWhitelist.contains(path)) {
          offenders.add('$path -> $ref');
        }
      }
    }
    final stale = _uiDataImportWhitelist.difference(stillViolating).toList()
      ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          'UI 直接依赖数据层会绕过 provider / 领域端口；请通过 provider 或端口访问：\n'
          '${offenders.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: 'UI → data 白名单条目已不再违规，请删除：\n${stale.join('\n')}',
    );
  });

  test('lib/utils/** 保持纯工具（白名单只减不增）', () {
    final offenders = <String>[];
    final stillViolating = <String>{};
    for (final path in files.where((path) => path.startsWith('lib/utils/'))) {
      for (final ref in _importsOf(path)) {
        if (!_violatesUtilsPurity(path, ref)) continue;
        stillViolating.add(path);
        if (!_utilsImpureWhitelist.contains(path)) {
          offenders.add('$path -> $ref');
        }
      }
    }
    final stale = _utilsImpureWhitelist.difference(stillViolating).toList()
      ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          'lib/utils 不允许依赖 widgets/providers/services/data/pages/l10n '
          '或 material_ui / material_3_expressive；请把 UI 相关逻辑移到消费方：\n'
          '${offenders.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: 'utils 纯度白名单条目已不再违规，请删除：\n${stale.join('\n')}',
    );
  });
}

bool _isSizeExcluded(String path) =>
    path.endsWith('.g.dart') ||
    path.startsWith('lib/l10n/') ||
    _sizeExcludedFiles.contains(path);

int _lineCount(String path) => File(path).readAsLinesSync().length;

bool _violatesUtilsPurity(String path, String ref) {
  final target = _resolve(path, ref);
  return _utilsForbiddenPathPrefixes.any(
        (prefix) => target.startsWith(prefix),
      ) ||
      _utilsForbiddenPackagePrefixes.any(ref.startsWith);
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

final RegExp _importPattern = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

List<String> _importsOf(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  return _importPattern
      .allMatches(file.readAsStringSync())
      .map((match) => match.group(1)!)
      .toList();
}

/// 相对 import / `package:molia` 统一解析为 `lib/...` 路径；
/// 其余 `dart:` / `package:` 原样返回。
String _resolve(String sourcePath, String ref) {
  const packagePrefix = 'package:molia/';
  if (ref.startsWith('dart:') || ref.startsWith('package:')) {
    if (ref.startsWith(packagePrefix)) {
      return _normalize('lib/${ref.substring(packagePrefix.length)}');
    }
    return ref;
  }
  final slash = sourcePath.lastIndexOf('/');
  final dir = slash < 0 ? '' : sourcePath.substring(0, slash);
  return _normalize('$dir/$ref');
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
