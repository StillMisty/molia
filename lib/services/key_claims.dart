/// 全局快捷键的按键让位登记表（桌面壳层与模态 / 焦点控件的协作协议）。
///
/// **为什么需要**：`HardwareKeyboard` 的处理器**全部执行且返回值不短路**
/// （SDK 原文：All registered handlers will be invoked in order regardless of
/// their return value）。桌面壳层的软件内快捷键（Space 播放、方向键 seek /
/// 音量）会在焦点分发之前收到按键；搜索遮罩 / 搜索结果区里这些键属于行激活
/// 与焦点移动，壳层不能同时消费。登记表把「此刻这些键归谁」提前告诉壳层：
/// 命中登记时壳层让位（处理器返回 false、不执行命令），按键继续走焦点分发。
///
/// **语义**：登记是常驻的（State 生命周期内登记、dispose 注销），[claims]
/// 在按键到来时**现算**——隐藏页 / 已关闭遮罩的残留登记不会误伤全局快捷键。
///
/// **范围**：只登记会被全局快捷键抢走的键（方向键 / Space / Enter /
/// PageUp / PageDown）；Ctrl+F 与 Esc 不登记（Esc 走 `EscapeClaims`）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// 一次登记：哪些键 + 此刻是否生效（判定与登记方自己的处理器同源）。
class KeyClaim {
  KeyClaim({required this.keys, required this.active});

  final Set<LogicalKeyboardKey> keys;
  final bool Function() active;
}

abstract final class KeyClaims {
  static final Set<KeyClaim> _claims = {};

  /// 登记一组按键的让位判定；返回的 token 交给 [remove]。
  static KeyClaim add({
    required Set<LogicalKeyboardKey> keys,
    required bool Function() active,
  }) {
    final claim = KeyClaim(keys: Set.unmodifiable(keys), active: active);
    _claims.add(claim);
    return claim;
  }

  /// 注销登记；未登记时为无操作（dispose 里可无条件调用）。
  static void remove(KeyClaim claim) => _claims.remove(claim);

  /// 此刻是否有登记方接管该键（每次读取现算全部判定）。
  static bool claims(LogicalKeyboardKey key) =>
      _claims.any((claim) => claim.keys.contains(key) && claim.active());

  /// 清空全部登记：仅测试收尾用，防止用例间残留。
  @visibleForTesting
  static void reset() => _claims.clear();
}
