/// 桌面播放页两栏的宽度预算（纯函数，边界可单测）。
///
/// 为什么单独成文件：左栏宽度同时受「封面 / 控制排最小可用宽」与「右栏
/// 队列 / 歌词信息保底宽」两头夹取，写死在页面里时 900 宽窗口会把右栏压到
/// 324（历史实现）。这里只做矩形运算，页面只消费结果。
library;

/// 左播放器栏的宽度上限：窗口足够宽时保持现状。
const double desktopPlayerColumnMaxWidth = 480;

/// 左栏下限：再窄封面与控制排会挤在一起。
const double desktopPlayerColumnMinWidth = 360;

/// 右栏（队列 / 歌词 / 信息）的保底宽度。
const double desktopSidePaneMinWidth = 420;

/// 按内容宽（窗口宽 − 导航轨）解析左栏宽。
///
/// 内容宽充足时保持 480；不足时优先保右栏 [desktopSidePaneMinWidth]，
/// 左栏收缩到 [desktopPlayerColumnMinWidth]；连两者之和都放不下时退到
/// 360 并夹在内容宽内（不横向溢出）。
double desktopNowPlayingPlayerWidth(double contentWidth) {
  if (contentWidth <= 0) return 0;
  final double preferred = (contentWidth - desktopSidePaneMinWidth)
      .clamp(desktopPlayerColumnMinWidth, desktopPlayerColumnMaxWidth)
      .toDouble();
  return preferred.clamp(0.0, contentWidth).toDouble();
}
