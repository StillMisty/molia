/// 播放页的外部请求通道（壳 → 播放页）+ 壳层可见的播放页状态。
///
/// 与 `ShellReselectSignal` 同一形态：壳层的入口（底栏重复点击、顶栏曲目区、
/// 返回键等）没有与播放页共享的界面状态，只能表达一次意图。区别是请求带
/// 目标（切到某页 / 展开 / 收起），且**每次都通知**——「已经在该 tab 上」
/// 也要让页面确认（页面可能刚挂载、用户也可能手动切走后再触发一次）。
/// 消费时机（请求先于挂载 / 已挂载 / 尚未布局）由 `lib/pages/nowplaying.dart`
/// 负责。
library;

import 'package:flutter/foundation.dart';

/// 播放页内容页序：队列 / 歌词 / 歌曲信息。
///
/// 移动端圆点、桌面端 tab 与外部请求共用同一份顺序——三处各写一遍必然漂移
/// （移动端默认停在歌词页就是这里定义的 [nowPlayingLyricsTabIndex]）。
const int nowPlayingQueueTabIndex = 0;
const int nowPlayingLyricsTabIndex = 1;
const int nowPlayingInfoTabIndex = 2;

/// 播放页的外部请求通道（壳 → 播放页）。
///
/// 由组合根创建并注入 `NowPlaying`；调用方只发请求，不读界面状态。
/// 展开态 / 布局能力（`expanded` / `miniCapable`）由
/// `lib/app/shell/shell_presentation.dart::ShellPresentation` 持有；页面通过
/// `NowPlaying.onExpansionChanged` / `onMiniCapableChanged` 回写该模块。
///
/// 壳层仍需 [activeTab]：桌面 Esc 要先判断播放页右栏是否停在队列。
class NowPlayingController extends ChangeNotifier {
  int? _requestedTab;
  int _tabRequestVersion = 0;

  /// 待消费的展开 / 收起意图；null = 没有请求。
  bool? _requestedExpansion;

  /// 播放页当前内容 tab（桌面右栏 / 移动 PageView 落定后的值）。
  final ValueNotifier<int> activeTab = ValueNotifier<int>(
    nowPlayingLyricsTabIndex,
  );

  /// 最近一次被请求的页（[nowPlayingQueueTabIndex] 等）；从未请求时为 null。
  int? get requestedTab => _requestedTab;

  /// tab 请求版本：每次 [showQueueTab] / [showLyricsTab] / [showInfoTab] 自增。
  ///
  /// 展开 / 收起请求与 tab 请求共用同一个 [ChangeNotifier]：页面按这个版本
  /// 判断「这次通知到底有没有新的 tab 请求」，避免收起播放器时重放上一次 tab。
  int get tabRequestVersion => _tabRequestVersion;

  /// 待消费的展开 / 收起意图；null = 没有请求。
  ///
  /// 意图而不是状态：页面可能尚未挂载完，重复请求不叠加。
  bool? get requestedExpansion => _requestedExpansion;

  /// 请求切到队列页。
  void showQueueTab() => _request(nowPlayingQueueTabIndex);

  /// 请求切到歌词页。
  void showLyricsTab() => _request(nowPlayingLyricsTabIndex);

  /// 请求切到歌曲信息页。
  void showInfoTab() => _request(nowPlayingInfoTabIndex);

  /// 请求展开播放页（窄版式）；无迷你态的版式由页面忽略并回写
  /// 展开态 = false。
  void expand() => _requestExpansion(true);

  /// 请求收起播放页（窄版式，收起高度为 0）；无迷你态的版式由页面忽略。
  void collapse() => _requestExpansion(false);

  /// 页面消费一次展开 / 收起意图；无待处理请求时返回 null。
  bool? takeExpansionRequest() {
    final value = _requestedExpansion;
    if (value == null) return null;
    _requestedExpansion = null;
    return value;
  }

  void _requestExpansion(bool value) {
    // 与旧 collapse 的「重复请求不叠加」同一口径：同一方向的意图还在排队时
    // 再发一次没有新信息，页面按第一次的请求执行。
    if (_requestedExpansion == value) return;
    _requestedExpansion = value;
    notifyListeners();
  }

  /// 请求是动作不是状态：重复请求同一页也要通知，订阅方自行决定是否已到位。
  void _request(int index) {
    _requestedTab = index;
    _tabRequestVersion++;
    notifyListeners();
  }

  @override
  void dispose() {
    activeTab.dispose();
    super.dispose();
  }
}
