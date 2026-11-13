import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';

/// 路由内封面共享元素：把来源卡片与详情页头部的封面挂到同一个 [Hero]。
///
/// 减弱动效时直接返回 [child]：Hero 飞行属于空间位移 / 尺寸变化，系统要求
/// 减少动态时不应再让封面跨页飞行；两端都走本组件，tag 是否生效始终一致。
class CoverHero extends StatelessWidget {
  const CoverHero({super.key, required this.tag, required this.child});

  /// Hero 标签：必须在同一 Navigator 内唯一（发现页按内容类型 + 平台 id
  /// 拼接，见各 tab 的私有 tag 函数）。
  final Object tag;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduceMotionOf(context)) return child;
    return Hero(tag: tag, child: child);
  }
}
