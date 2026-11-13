/// 弹层 / 侧滑关闭后的焦点归还。
///
/// 打开前记住 `FocusManager.primaryFocus`，关闭后等路由退场帧结束再请求
/// 焦点；节点已销毁（页面被卸载）时静默跳过。搜索遮罩的「逐帧重试」只
/// 服务它自己的输入框，这里是通用弹层 / 侧滑的统一合同。
library;

import 'package:flutter/widgets.dart';

Future<T?> withFocusRestore<T>(Future<T?> Function() open) async {
  final previous = FocusManager.instance.primaryFocus;
  try {
    return await open();
  } finally {
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          if (previous.context == null) return;
          previous.requestFocus();
        } catch (_) {
          // 焦点节点随页面销毁：没有可归还的目标。
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }
}
