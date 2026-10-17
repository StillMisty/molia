/// 播放页封面堆叠的尺寸预算：纯函数（输入可用宽高，输出封面边长与堆叠尺寸）。
///
/// 唯一口径：堆叠的横向 / 纵向因子与「可用区 → 封面边长」的换算都只在这里，
/// 硬不变量是 `stackWidth ≤ availableWidth` 且 `stackHeight ≤ availableHeight`
/// （邻位封面的旋转包围盒与卡面阴影都算进横向因子）。
library;

import 'dart:math';

/// 堆叠横向因子（相对中心封面边长）：邻位封面边长 0.78、位移 ±0.30 边长、
/// 旋转 0.05rad，单侧绘制半宽 = 0.30 + 0.78 × (cos0.05 + sin0.05) / 2
/// ≈ 0.709，两侧合计 ≈ 1.418；再加卡面柔和阴影（blur 24，实测可见外扩
/// 约 13dp @ art 320）≈ 0.08 → 1.50。
const double coverDeckHorizontalFactor = 1.50;

/// 堆叠纵向因子：中心封面切歌时最多旋转 0.05rad（包围盒 ≈ 1.049 边长），
/// 邻位封面更小不参与；余量给阴影（含 10dp 下偏移）。
const double coverDeckVerticalFactor = 1.06;

/// 一次封面尺寸预算：中心封面边长 + 承载三封面堆叠的容器尺寸
/// （旋转与阴影余量已含在堆叠尺寸里，堆叠尺寸必须由宿主原样采用）。
typedef CoverDeckMetrics = ({
  double artDimension,
  double stackWidth,
  double stackHeight,
});

/// 按可用宽高（已扣除标题/进度排等留白）算封面边长与堆叠尺寸。
///
/// 两轴同时约束 —— `art ≤ 可用宽 / 横向因子`、`art ≤ 可用高 / 纵向因子`，
/// 取小者，因此堆叠一定落在可用区内（宿主给的可用区就是绘制区的边界）。
/// 可用高为 [double.infinity] 时只受宽度约束；两轴都无界（未约束的宿主）
/// 时无处安放，返回 0 而不是无穷。
CoverDeckMetrics coverDeckMetricsFor({
  required double availableWidth,
  required double availableHeight,
}) {
  final double maxWidth = max(0.0, availableWidth);
  final double maxHeight =
      availableHeight.isFinite ? max(0.0, availableHeight) : double.infinity;
  final double byWidth = maxWidth / coverDeckHorizontalFactor;
  final double byHeight = maxHeight / coverDeckVerticalFactor;
  double artDimension = min(byWidth, byHeight);
  if (!artDimension.isFinite) artDimension = 0;
  // 除法/乘法往返有 1 ulp 误差（400 / 1.06 × 1.06 = 400.00000000000006）：
  // 「堆叠不越出可用区」是硬不变量，按可用区夹一次，不靠调用方的容忍度。
  return (
    artDimension: artDimension,
    stackWidth: min(artDimension * coverDeckHorizontalFactor, maxWidth),
    stackHeight: min(artDimension * coverDeckVerticalFactor, maxHeight),
  );
}
