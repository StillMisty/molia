/// 播放页「切到某个 tab」的外部请求通道（壳 → 播放页）。
///
/// 与 `ShellReselectSignal` 同一形态：壳层的入口（底栏队列按钮等）没有与
/// 播放页共享的界面状态，只能表达一次意图。区别是请求带目标页，且**每次都
/// 通知**——「已经在该 tab 上」也要让页面确认（页面可能刚挂载、用户也可能
/// 手动切走后再触发一次）。消费时机（请求先于挂载 / 已挂载 / 尚未布局）由
/// `lib/pages/nowplaying.dart` 负责。
library;

import 'package:flutter/foundation.dart';

/// 播放页内容页序：队列 / 歌词 / 歌曲信息。
///
/// 移动端圆点、桌面端 tab 与外部请求共用同一份顺序——三处各写一遍必然漂移
/// （移动端默认停在歌词页就是这里定义的 [nowPlayingLyricsTabIndex]）。
const int nowPlayingQueueTabIndex = 0;
const int nowPlayingLyricsTabIndex = 1;
const int nowPlayingInfoTabIndex = 2;

/// 播放页 tab 切换请求。
///
/// 由组合根创建并注入 `NowPlaying`；调用方只发请求，不读界面状态。
class NowPlayingController extends ChangeNotifier {
  int? _requestedTab;

  /// 最近一次被请求的页（[nowPlayingQueueTabIndex] 等）；从未请求时为 null。
  int? get requestedTab => _requestedTab;

  /// 请求切到队列页。
  void showQueueTab() => _request(nowPlayingQueueTabIndex);

  /// 请求切到歌词页。
  void showLyricsTab() => _request(nowPlayingLyricsTabIndex);

  /// 请求切到歌曲信息页。
  void showInfoTab() => _request(nowPlayingInfoTabIndex);

  /// 请求是动作不是状态：重复请求同一页也要通知，订阅方自行决定是否已到位。
  void _request(int index) {
    _requestedTab = index;
    notifyListeners();
  }
}
