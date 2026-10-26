/// 数据链路 perf 场景（opt-in，`--dart-define=MOLIA_PERF_SCENARIO_DATA=true`）。
///
/// 目的：在没有 UI 点击坐标 / 不依赖截图的情况下，用真实组合根跑一遍
/// 「搜索 → 点首条 → 起播 → 取词」，把 `molia.perf` 的端到端时延打出来。
/// 正常包不编译这段逻辑（const 判断在编译期折叠），也不改任何默认行为。
///
/// 场景数据来源：`tool/agent/seed.sh linux|android mock-source` 注入的本地
/// LX 脚本（`MOLIA_PERF_SOURCE` 默认为 `mock`，见 seed.sh）。音源初始化是
/// 首帧后的正常链路，本场景只等它 ready，不重复调用 `init()`（会重复订阅）。
///
/// 环境变量（均为 `--dart-define` 编译期常量）：
/// - `MOLIA_PERF_SCENARIO_DATA=true`：启用；
/// - `MOLIA_PERF_SOURCE=mock`：音源 key（空 = 第一个可搜索音源）；
/// - `MOLIA_PERF_KEYWORD=周杰伦`：搜索词；
/// - `MOLIA_PERF_HOLD_SECONDS=3`：场景完成后保持进程的时长（CPU 采样用）。
library;

import 'dart:async';
import 'dart:io' show exit;

import 'package:logging/logging.dart';

import '../../providers/search_provider.dart';
import '../bootstrap/catalog_stack.dart';
import '../bootstrap/lyrics_stack.dart';
import '../bootstrap/playback_stack.dart';
import 'data_path_trace.dart';

const bool _enabled =
    bool.fromEnvironment('MOLIA_PERF_SCENARIO_DATA', defaultValue: false);
const String _sourceKey = String.fromEnvironment('MOLIA_PERF_SOURCE');
const String _keyword = String.fromEnvironment(
  'MOLIA_PERF_KEYWORD',
  defaultValue: '周杰伦',
);
const int _holdSeconds = int.fromEnvironment(
  'MOLIA_PERF_HOLD_SECONDS',
  defaultValue: 3,
);
const int _startDelaySeconds = int.fromEnvironment(
  'MOLIA_PERF_START_DELAY_SECONDS',
  defaultValue: 0,
);

final _logger = Logger('molia.perf');

/// 首帧后调用；未启用时立即返回（零开销）。
Future<void> runDataPathScenario({
  required CatalogStack catalog,
  required PlaybackStack playback,
  required LyricsStack lyrics,
}) async {
  if (!_enabled) return;
  DataPathTrace.event('scenario.start', fields: () => {
        'keyword': _keyword,
        'source': _sourceKey,
      });
  try {
    await _run(catalog: catalog, playback: playback, lyrics: lyrics);
  } catch (e, stackTrace) {
    _logger.warning('scenario 失败: $e\n$stackTrace');
    DataPathTrace.event('scenario.failed', fields: () => {'error': '$e'});
  } finally {
    DataPathTrace.event('scenario.done');
    // 给 logger handler / 文件写入留出落盘时间，再结束进程（场景是独立
    // release 进程，不是用户日常路径）。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}

Future<void> _run({
  required CatalogStack catalog,
  required PlaybackStack playback,
  required LyricsStack lyrics,
}) async {
  // 音源初始化在 post_frame_init 的正常链路里；这里只等，不重复 init。
  final sourceReady = await _waitFor(
    () => catalog.sourceManager.hasActiveSource,
    timeout: const Duration(seconds: 90),
  );
  DataPathTrace.event('scenario.source', fields: () => {
        'ready': sourceReady ? 1 : 0,
        'active': catalog.sourceManager.activeSources.length,
        'engine': catalog.sourceManager.engineReady ? 1 : 0,
      });
  if (!sourceReady) return;

  // CPU 采样用：先保持一段空闲窗口，再开始搜索 / 播放。
  if (_startDelaySeconds > 0) {
    await Future<void>.delayed(Duration(seconds: _startDelaySeconds));
  }

  final search = SearchProvider(
    playback.playbackProvider,
    catalogService: catalog.catalogService,
    sourceRegistry: catalog.sourceRegistry,
  );
  try {
    final options =
        search.sourceChannels.where((o) => o.capabilities.search).toList();
    if (options.isEmpty) {
      _logger.warning('scenario: 没有可搜索音源');
      return;
    }
    final option = _sourceKey.isEmpty
        ? options.first
        : options.firstWhere(
            (o) => o.key == _sourceKey,
            orElse: () => options.first,
          );
    search.selectSource(option.key);
    DataPathTrace.event('scenario.search.begin', fields: () => {
          'source': option.key,
          'keyword': _keyword,
        });

    final searchWatch = Stopwatch()..start();
    search.updateSearchQuery(_keyword);
    final searched = await _waitFor(
      () => !search.isSearching && search.searchResults.isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    final items = search.filteredResults;
    DataPathTrace.event('scenario.search.done', fields: () => {
          'ok': searched ? 1 : 0,
          'ms': searchWatch.elapsedMilliseconds,
          'results': items.length,
          'failure': search.failure?.kind.name ?? '',
        });
    if (items.isEmpty) return;

    // 点第一条：走 SearchProvider → PlaybackProvider → 真实播放后端。
    search.playItem(items.first);
    final playbackWatch = Stopwatch()..start();
    final playing = await _waitFor(
      () =>
          playback.playbackProvider.snapshot.current != null &&
          !playback.playbackProvider.isLoading &&
          playback.playbackProvider.isPlaying,
      timeout: const Duration(seconds: 45),
    );
    DataPathTrace.event('scenario.play.done', fields: () => {
          'ok': playing ? 1 : 0,
          'ms': playbackWatch.elapsedMilliseconds,
          'track': playback.playbackProvider.snapshot.current?.id.uri ?? '',
          'error': playback.playbackProvider.snapshot.error?.kind.name ?? '',
        });

    // 取词：真实链路（原生 lyric action → 缓存 → 网络回退）。
    final current = playback.playbackProvider.snapshot.current;
    if (current != null) {
      final lyricsWatch = Stopwatch()..start();
      await lyrics.lyricsProvider.load(current);
      final state = lyrics.lyricsProvider.state;
      DataPathTrace.event('scenario.lyrics.done', fields: () => {
            'ms': lyricsWatch.elapsedMilliseconds,
            'status': state.status.name,
            'lines': state.lines.length,
            'provider': state.providerName ?? '',
          });
    }

    if (_holdSeconds > 0) {
      await Future<void>.delayed(Duration(seconds: _holdSeconds));
    }
  } finally {
    search.dispose();
  }
}

/// 轮询等待条件成立；不做微任务空转，步进 50ms（场景不在启动关键路径）。
Future<bool> _waitFor(
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return condition();
}
