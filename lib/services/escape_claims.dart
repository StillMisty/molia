/// 页面级 Esc 占用登记表（桌面壳层与页面 / 弹层的协作协议）。
///
/// **为什么需要**：`HardwareKeyboard` 的处理器**全部执行且返回值不短路**
/// （SDK 原文：All registered handlers will be invoked in order regardless of
/// their return value）。壳层可配置快捷键（`app/desktop/desktop_shortcuts.dart`）
/// 与页面级处理器（如收藏页多选）会同时收到同一次 Esc，无法靠返回值裁决；
/// 壳层一旦执行 Esc 命中的命令（默认绑定「关闭队列面板」），同一次按键就被
/// 两个作用域消费。登记表把「此刻的 Esc 归谁」提前告诉壳层：有登记方时壳层
/// 让位（处理器返回 false、不执行命令），按键交给登记方处理。
///
/// **语义**：登记方声明「此刻的 Esc 由我处理」。登记是常驻的（initState 登记、
/// dispose 注销），[any] 在 Esc 到来时**现算**——不缓存状态，隐藏页 / 已关闭
/// 弹层的残留登记不会误伤壳层命令。
///
/// **优先级**：页面级 / 弹层 Esc 优先于壳层可配置命令（Esc 是原始键语义；
/// 用户把别的命令绑到 Esc 时同样让位）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

abstract final class EscapeClaims {
  static final Set<bool Function()> _claims = {};

  /// 登记一个占用判定：返回 true 表示此刻的 Esc 应由登记方处理。
  ///
  /// 判定必须与登记方自己的按键处理器**同源**（同一条件方法），否则会出现
  /// 「壳层让位但登记方不处理」的按键黑洞，或两边都不让位的双重消费。
  static void add(bool Function() claim) => _claims.add(claim);

  /// 注销登记；未登记时为无操作（dispose 里可无条件调用）。
  static void remove(bool Function() claim) => _claims.remove(claim);

  /// 此刻是否有登记方接管 Esc（每次读取现算全部判定）。
  static bool get any => _claims.any((claim) => claim());

  /// 清空全部登记：仅测试收尾用，防止用例间残留。
  @visibleForTesting
  static void reset() => _claims.clear();
}
