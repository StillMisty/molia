/// 一个歌词来源的策略声明：渠道 key + 取词实现 + 是否参与自动回退 + 可用性。
///
/// 之前「换源页有哪些来源」和「`LyricsService` 自动回退用哪些 provider」
/// 是两份写死的列表，新增一个内置渠道要同时改 UI 与服务。现在两边都从
/// 同一份 `LyricsSourceRegistry` 派生，本文件只描述单个来源的事实。
library;

import 'lyric_provider.dart';

/// 来源当前不可用的原因（UI 据此显示「怎么办」，而不是静默隐藏）。
enum LyricsSourceUnavailable {
  /// 未登录 B 站：字幕接口未登录时恒为空，必须先登录才有歌词可选。
  biliLoginRequired,
}

/// 单个歌词来源。
class LyricsSourceStrategy {
  const LyricsSourceStrategy({
    required this.channelKey,
    required this.provider,
    this.autoFallback = true,
    this.isChannel = true,
    this.unavailable,
  });

  /// 渠道 key（tx / wy / kg / kw / mg / bili / lrclib）。
  ///
  /// 用于换源页「同源置顶」与分组排序；与 [LyricProvider.name] 可能不同
  /// （QQ 的 channelKey 是 `tx`、provider 名是 `qq`），所以两者分开存。
  final String channelKey;

  /// 实际取词实现。
  final LyricProvider provider;

  /// 是否参与 `LyricsService` 的名字搜索回退（并行竞速）。
  ///
  /// 五个音乐平台 + LRCLIB 为 true；视频站 / 通用平台适配器为 false：
  /// 它们的结果不是「歌曲」实体（B 站结果是一条视频），自动竞速容易在
  /// 音乐平台返回前抢到翻唱 / 搬运的错匹配，只放进手动换源让用户自己选。
  final bool autoFallback;

  /// 是否对应一个音源渠道（LRCLIB 不是渠道，不受渠道停用开关影响）。
  final bool isChannel;

  /// null = 可用；非 null = 当前不可用（如未登录 B 站）。
  ///
  /// 必须是**调用时求值**的闭包，不能捕获登录快照：打开换源页之后用户
  /// 才扫码登录 / 退出，状态也要立即反映到分组提示与发不发请求上。
  final LyricsSourceUnavailable? Function()? unavailable;
}
