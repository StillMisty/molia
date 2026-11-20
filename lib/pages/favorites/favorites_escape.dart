/// 收藏页桌面键盘语义：Esc 只在「多选 + 页面可见 + 输入框未聚焦」时接管。
///
/// 页面级处理器与壳层 [EscapeClaims] 占用判定必须同源，否则会出现「壳层
/// 让位但本页不处理」的按键黑洞，或壳层与页面双重消费。判定只读传入值 +
/// `BuildContext`，不持有页面状态。
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/shell_page_visibility.dart';

/// 此刻 Esc 是否由收藏页接管。
bool favoritesCanHandleEscape({
  required BuildContext context,
  required bool selecting,
}) {
  if (!selecting) return false;
  // 壳层页面常驻挂载：隐藏页不响应 Esc——按键属于用户当前看到的页面，
  // 不该在别的页面上清掉看不见的多选（未挂壳层的单测按可见处理）。
  if (context.getInheritedWidgetOfExactType<ShellPageVisibility>()?.visible ==
      false) {
    return false;
  }
  // 输入框聚焦时让位（仓库硬约定，与壳层全局快捷键一致）。
  if (FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null) {
    return false;
  }
  return true;
}

/// 此刻系统返回是否由收藏页接管（壳层 `BackClaims` 与页面 `PopScope` 同源）。
///
/// 多选 / 搜索 / 排序是页面的临时状态：返回应先退出它们，而不是让壳层
/// 切目的地。隐藏页不接管（常驻挂载的登记不能截胡别的页面）。
bool favoritesBackClaim({
  required BuildContext context,
  required bool selecting,
  required bool searching,
  required bool reordering,
}) {
  if (!(selecting || searching || reordering)) return false;
  return context
          .getInheritedWidgetOfExactType<ShellPageVisibility>()
          ?.visible !=
      false;
}

/// 桌面 Esc：退出选择模式；不接管时返回 false 放行。
bool handleFavoritesEscapeKey(
  KeyEvent event, {
  required bool Function() canHandleEscape,
  required VoidCallback clearSelection,
}) {
  if (event is! KeyDownEvent) return false;
  if (event.logicalKey != LogicalKeyboardKey.escape) return false;
  if (!canHandleEscape()) return false;
  clearSelection();
  return true;
}
