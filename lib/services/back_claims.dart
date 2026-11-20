/// 页面级返回占用登记表（壳层 PopScope 与页面 / 弹层 PopScope 的协作协议）。
///
/// **为什么需要**：`ModalRoute.onPopInvokedWithResult` 会把一次返回广播给
/// 路由上**所有**已登记的 `PopScope`，回调返回值不参与裁决
/// （`routes.dart` 里是 `for (final popEntry in _popEntries) ...`）。页面级
/// 拦截（收藏多选 / 搜索 / 排序）把 `canPop` 设为 false 时，壳层自己的
/// `PopScope` 仍会收到一次 `didPop == false`；如果壳层这时照常执行「展开
/// 播放器 → 收起 / 非家目的地 → 回上一页」，同一次返回就被页面和壳层双重
/// 消费。
///
/// **语义**：登记方声明「此刻的返回由我处理」。登记常驻，[any] 在返回到来
/// 时现算——隐藏页 / 已退出状态的残留登记不会误伤壳层。
///
/// **优先级**：页面级返回优先于壳层的层级返回（系统返回 = 先退当前页面的
/// 临时状态，再退目的地）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

abstract final class BackClaims {
  static final Set<bool Function()> _claims = {};

  /// 登记一个占用判定：返回 true 表示此刻的返回应由登记方处理。
  ///
  /// 判定必须与登记方 `PopScope.canPop == false` 的条件同源，否则会出现
  /// 「壳层让位但页面不处理」的返回黑洞，或两边都不让位的双重消费。
  static void add(bool Function() claim) => _claims.add(claim);

  /// 注销登记；未登记时为无操作（dispose 里可无条件调用）。
  static void remove(bool Function() claim) => _claims.remove(claim);

  /// 此刻是否有登记方接管返回（每次读取现算全部判定）。
  static bool get any => _claims.any((claim) => claim());

  /// 清空全部登记：仅测试收尾用，防止用例间残留。
  @visibleForTesting
  static void reset() => _claims.clear();
}
