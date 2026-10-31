/// 简单弹层正文的共享骨架。
///
/// 定时关闭、来源分享、换封面等弹层的正文都是「可滚动的一列控件」；
/// 统一在这里补滚动与底部余量，弹层宿主（底部抽屉 / 对话框）只负责标题栏。
library;

import 'package:material_ui/material_ui.dart';

/// 简单弹层的滚动正文：可选头部 + 一段纵向控件。
///
/// 底部默认留 8：弹层自身的标题栏 / 安全区已占掉一部分，正文再贴底会让
/// 最后一行操作按钮显得被裁切；需要更紧的弹层可用 [padding] 覆盖。
class SimpleModalBody extends StatelessWidget {
  const SimpleModalBody({
    super.key,
    required this.children,
    this.header,
    this.padding,
  });

  /// 正文控件，按顺序纵向排列并撑满可用宽度。
  final List<Widget> children;

  /// 正文之前的头部（如说明文案 / 预览）。
  final Widget? header;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final header = this.header;
    return SingleChildScrollView(
      padding: padding ?? const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [?header, ...children],
      ),
    );
  }
}
