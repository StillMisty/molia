/// 曲目交接（播放 / 加入列表）的唯一实现。
///
/// 为什么单独一层：专辑页与歌手页的「播放全部 / 随机播放全部 / 加入列表」
/// 编排逐字节相同，曲目菜单（搜索结果 / 队列）又各写了一遍单曲加入列表。
/// 洗牌顺序、上下文名回退、触感与 `addedAt` 口径散在 3+ 处后，调整队列 /
/// 装载语义必须同时改所有入口。这里把「把一组曲目交给播放 / 资料库」收成
/// 两个意图，调用方只提供数据与上下文名。
///
/// 纯部分（名称归一 / 起播下标 / `PlaylistTrack` 批量转换）是导出的顶层
/// 函数，可脱离 widget 单测；带 context 的编排只读 provider 与既有流程。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../models/play_mode.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import 'add_to_library.dart';

/// 队列上下文名 / 页面标题的统一口径：先取列表自身名称，空则回退入口名。
///
/// 两端都 trim：平台返回的专辑 / 歌手名常带空白，回退名来自入口也可能只有
/// 空格（此时应视为「没有名字」，而不是把空白写进队列上下文）。
String resolveTrackListName({String? name, String? fallbackName}) {
  final primary = name?.trim() ?? '';
  if (primary.isNotEmpty) return primary;
  return fallbackName?.trim() ?? '';
}

/// 起播下标：非洗牌 = 调用方指定的下标（夹到有效范围），洗牌 = 列表内随机。
///
/// 随机源可注入：纯函数配合固定种子即可断言洗牌起播下标，页面不需要自己
/// 持有 `math.Random`。
int resolveTrackStartIndex({
  required int length,
  int startIndex = 0,
  bool shuffle = false,
  math.Random? random,
}) {
  if (length <= 0) return 0;
  if (!shuffle) {
    if (startIndex <= 0) return 0;
    if (startIndex >= length) return length - 1;
    return startIndex;
  }
  return (random ?? math.Random()).nextInt(length);
}

/// 领域曲目批量归一为资料库列表行：同一次「加入列表」共用一个 [addedAt]。
///
/// 列表内同一批行的时间口径必须一致（排序 / 同步比较都读它）；逐条取
/// `DateTime.now()` 会让同批曲目落在不同毫秒。payload 浅拷贝由
/// [PlaylistTrack.fromTrack] 原样透传（取链依赖平台字段）。
List<PlaylistTrack> playlistTracksFrom(
  Iterable<Track> tracks, {
  required int addedAt,
}) =>
    [
      for (final track in tracks)
        PlaylistTrack.fromTrack(track, addedAt: addedAt),
    ];

/// 把一组曲目交给播放或资料库的句柄。
///
/// 无状态；[random] 只在洗牌起播时使用（null = 每次现建随机源）。
final class TrackHandoff {
  const TrackHandoff({this._random});

  /// 洗牌起点的随机源（测试注入固定种子；生产不传）。
  final math.Random? _random;

  /// 从 [tracks] 的 [startIndex] 起播；[shuffle] 先落随机模式再装载队列。
  ///
  /// 空列表是合法的「无事可做」：页面空态 / 加载间隙都可能触发，不触感、
  /// 不装载。上下文名经 [resolveTrackListName] 归一，空串不写进队列。
  Future<void> play(
    BuildContext context,
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    String? contextName,
    String? fallbackContextName,
  }) async {
    if (tracks.isEmpty) return;
    // 先快照：洗牌前要等一次模式写入，期间分页列表可能已被替换。
    final queue = List<Track>.of(tracks);
    final playback = context.read<PlaybackProvider>();
    final name = resolveTrackListName(
      name: contextName,
      fallbackName: fallbackContextName,
    );
    HapticsService.lightImpact();
    // 洗牌排列在装载时按当前模式生成：顺序必须先是模式、后是队列。
    if (shuffle) await playback.setPlayMode(PlayMode.shuffle);
    await playback.playDomainTracks(
      queue,
      resolveTrackStartIndex(
        length: queue.length,
        startIndex: startIndex,
        shuffle: shuffle,
        random: _random,
      ),
      contextName: name.isEmpty ? null : name,
    );
  }

  /// 把 [tracks] 加入资料库：统一目标选择流程（收藏 / 历史 / 自建列表）。
  ///
  /// 返回是否真正选择目标并写入成功（取消 / 无 provider / 空列表为 false）。
  /// 空列表不打开弹层：弹层出现再无事发生会被误读成入口坏了。
  Future<bool> addToLibrary(
    BuildContext context,
    List<Track> tracks, {
    bool includeFavorites = true,
    bool includeHistory = true,
  }) {
    if (tracks.isEmpty) return Future.value(false);
    return addPlaylistTracksToLibrary(
      context,
      // 同一次加入的所有曲目共用一个时间戳：列表内同批行的时间口径一致。
      playlistTracksFrom(
        tracks,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      includeFavorites: includeFavorites,
      includeHistory: includeHistory,
    );
  }

  /// 已规范化的列表行走同一个目标选择流程。
  ///
  /// 发现域的曲目有自己的形状（`DiscoverTrack` 与歌单导入共用
  /// `PlaylistTrack` 转换），但「选择目标 → 写入 → 反馈」不应再抄一份；
  /// 这个入口只负责流程，转换仍留在拥有该曲目形状的模块里。
  Future<bool> addPlaylistTracksToLibrary(
    BuildContext context,
    List<PlaylistTrack> tracks, {
    bool includeFavorites = true,
    bool includeHistory = true,
  }) async {
    if (tracks.isEmpty) return false;
    final library = context.read<LibraryProvider?>();
    if (library == null) return false;
    return addTracksToLibraryTarget(
      context,
      provider: library,
      tracks: tracks,
      includeFavorites: includeFavorites,
      includeHistory: includeHistory,
    );
  }
}
