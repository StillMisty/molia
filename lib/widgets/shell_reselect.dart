/// 壳层「重复点击已选中目的地」的一次性意图通道（壳 → 页面）。
///
/// 底栏 / 导航轨的目的地被重复点击时，壳层没有可共享的状态：这只是一次意图。
/// 每个目的地一个实例，随页面注入；页面订阅后按自己的语义响应（资料库 /
/// 收藏 = 回到列表顶部），壳层不消费任何值。
///
/// 播放页不再走这条通道：重复点击由壳层直接切换展开 / 收起（见
/// `app_shell.dart` 的 `_requestPlayerExpansion`），这样共享封面飞行不必再从
/// 页面绕一圈回来。
library;

import 'package:flutter/foundation.dart';

/// 一次「重复点击已选中目的地」的请求通道。
///
/// 用一次性通知而不是可观察状态：订阅方只做动作、不读值。
///
/// 触感归属：重复点击的轻震由壳层统一给出（见 `app_shell.dart`
/// `_onDestinationSelected`），页面侧对这些请求的响应**不再自带触感** ——
/// 一次点击只震一次；页面自己的其它入口（列表项点按等）仍各自负反馈。
class ShellReselectSignal extends ChangeNotifier {
  /// 触发一次重复点击（订阅方自行决定响应；无可响应时保持空操作）。
  void trigger() => notifyListeners();
}

/// 一次「长按壳层目的地」的请求通道。
///
/// 与 [ShellReselectSignal] 同形（一次性通知、订阅方只做动作），只是手势
/// 不同：目前只有收藏目的地接线——长按后切到收藏页并定位当前播放曲目。
///
/// 触感归属：已在本页时由壳层长按处理器给一次轻震；从别的目的地过来时由
/// 切页路径（`_selectDestination`）给，页面侧不再自带触感。
class ShellLongPressSignal extends ChangeNotifier {
  /// 触发一次长按意图（订阅方自行决定响应；无可响应时保持空操作）。
  void trigger() => notifyListeners();
}
