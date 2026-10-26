import 'package:material_ui/material_ui.dart';

/// 系统「减弱动效」偏好（`MediaQuery.disableAnimations`）。
///
/// effects（透明度 / 颜色等）没有 spatial 弹簧可依赖，统一在这里判一次，
/// 避免每个组件各写一遍 `MediaQuery.maybeOf` 后出现漏判（开着减弱动效
/// 仍有半秒淡入）。
bool reduceMotionOf(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// effects 动画的实际时长：减弱动效时归零（`Duration.zero` 即硬切）。
///
/// 只收口时长、不吞曲线：调用点仍显式写出 M3E 曲线，读代码时能直接看出
/// 正常态的运动配方，减弱动效只改「跑多久」。
Duration effectDurationOf(BuildContext context, Duration duration) =>
    reduceMotionOf(context) ? Duration.zero : duration;
