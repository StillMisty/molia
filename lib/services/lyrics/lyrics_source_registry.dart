/// 歌词来源注册表：「有哪些歌词来源」的唯一事实来源。
///
/// 自动回退（`LyricsService` 的并行竞速）与换源页的「歌词」tab 都从这里
/// 派生。新加一个内置渠道时，只要在 `BuiltinPlatforms` 同时登记 `search` +
/// `lyric` 适配器，就会自动出现在手动换源里，不需要再改 UI 或服务。
library;

import '../../sources/builtin/bili_account.dart';
import '../../sources/builtin/builtin_platforms.dart';
import 'builtin_lyric_provider.dart';
import 'kugou_provider.dart';
import 'kuwo_provider.dart';
import 'lrclib_provider.dart';
import 'lyric_provider.dart';
import 'lyrics_source_strategy.dart';
import 'migu_provider.dart';
import 'netease_provider.dart';
import 'qq_provider.dart';

class LyricsSourceRegistry {
  const LyricsSourceRegistry(this.strategies);

  /// 声明顺序即换源页的分组顺序（未置顶时）。
  final List<LyricsSourceStrategy> strategies;

  /// [LyricsService] 的名字搜索回退列表（并行竞速，首个非空即用）。
  List<LyricProvider> get autoProviders => [
        for (final strategy in strategies)
          if (strategy.autoFallback) strategy.provider,
      ];

  /// 换源页「歌词」tab 的来源：`preferredKey` 同源置顶，其余保持声明顺序。
  List<LyricsSourceStrategy> manualSources({String? preferredKey}) {
    final preferred = (preferredKey ?? '').trim();
    if (preferred.isEmpty) return strategies;
    return [
      ...strategies.where((strategy) => strategy.channelKey == preferred),
      ...strategies.where((strategy) => strategy.channelKey != preferred),
    ];
  }

  /// 标准来源集合（渠道顺序取 [BuiltinPlatforms.keys]，LRCLIB 兜底放最后）。
  ///
  /// static final 延迟初始化：只在首次访问时创建 provider（含 Dio），
  /// 组合根构造 [LyricsService] 不额外产生网络请求。
  static final LyricsSourceRegistry standard = LyricsSourceRegistry(
    _standardStrategies(),
  );

  static List<LyricsSourceStrategy> _standardStrategies() {
    // 五个音乐平台沿用各自的专用 provider：搜索后需要平台特有字段
    // （kg 的 hash、mg 的 mrc/lrc/trc URL、tx 的数字 songId 等）才能取词，
    // 通用适配器只透传 raw 满足不了这些取词接口。
    final covered = <String, LyricProvider>{
      'tx': QQProvider(),
      'wy': NetEaseProvider(),
      'kg': KugouProvider(),
      'kw': KuwoProvider(),
      'mg': MiguProvider(),
    };

    final strategies = <LyricsSourceStrategy>[];
    for (final platform in BuiltinPlatforms.searchCandidates) {
      final existing = covered[platform.key];
      if (existing != null) {
        strategies.add(
          LyricsSourceStrategy(channelKey: platform.key, provider: existing),
        );
        continue;
      }

      // 通用渠道：搜索 + 取词适配器缺一不可（没搜索拿不到 raw，没取词
      // 拿到了也没用）。已覆盖的五个音乐平台不会走到这里，未来新增的
      // 平台只要两件套齐全就自动具备歌词换源。
      if (platform.search == null || platform.lyric == null) continue;

      strategies.add(
        LyricsSourceStrategy(
          channelKey: platform.key,
          provider: BuiltinLyricProvider(platform.key),
          // 只进手动换源，不参与自动回退：B 站搜索结果是视频（同名翻唱 /
          // 搬运 / 切片很多），跨平台名字竞速时很容易先返回一条错匹配；
          // 这类平台的歌词也不一定对得上「这首歌」。手动换源里用户看得见
          // 标题与 UP 主，选错了自己换回来，代价可控。
          autoFallback: false,
          unavailable: _unavailableOf(platform.key),
        ),
      );
    }

    strategies.add(
      LyricsSourceStrategy(
        channelKey: 'lrclib',
        provider: LRCLibProvider(),
        // LRCLIB 不是音源渠道，不随渠道停用开关消失。
        isChannel: false,
      ),
    );
    return List.unmodifiable(strategies);
  }

  /// 平台级可用性：目前只有 B 站字幕要求登录（未登录时 `/x/player/v2`
  /// 的 subtitles 恒为空，发请求也是白跑）。
  ///
  /// 返回闭包而不是立即求值：注册表是进程级单例，登录 / 退出 / 同步到达
  /// 都发生在创建之后，每次打开换源页或发起搜索都要重新读当前态。
  static LyricsSourceUnavailable? Function()? _unavailableOf(String key) {
    if (key != 'bili') return null;
    return () => BiliAccountStore.instance.isLoggedIn
        ? null
        : LyricsSourceUnavailable.biliLoginRequired;
  }
}
