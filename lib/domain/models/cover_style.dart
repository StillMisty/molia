/// 封面风格：展示层可选的外观处理，不影响真实封面与任何导出 / 系统路径。
///
/// [id] 是持久化与同步的稳定字符串，等于枚举名的 camelCase；新增风格只能
/// 追加，不能改名（旧设备 / 旧备份按 id 解析）。未知 id 一律回退 [original]，
/// 这样未来版本写入的风格在旧版本里表现为「原图」而不是空白封面。
///
/// 本文件是纯 Dart（领域层）：具体像素算法在
/// `services/covers/cover_style_renderer.dart`，这里只表达用户可选项。
library;

/// 封面风格（9 种；[original] 为默认，零处理开销）。
enum CoverStyle {
  /// 原图：不生成任何派生图。
  original('original'),

  /// 渐变素描：铅笔线稿 + 暗部 + 固定彩虹渐变，亮部纸白。
  oneLastKiss('oneLastKiss'),

  /// 纯线稿：黑白高反差线条、纸白底。
  lineArt('lineArt'),

  /// 铅笔素描：线稿 + 石墨暗面 + 纸纹。
  pencil('pencil'),

  /// 浮雕版画：灰阶压印、强侧光。
  emboss('emboss'),

  /// 像素风：低分辨率色块 + 有限配色。
  pixel('pixel'),

  /// 黑白墨印：2–3 阶高反差黑白。
  ink('ink'),

  /// 双色印刷：固定两色 + 轻微套印错位。
  duotone('duotone'),

  /// 胶片颗粒：暖色、颗粒、光晕、暗角。
  film('film');

  const CoverStyle(this.id);

  /// 持久化 / 同步使用的稳定 id。
  final String id;

  /// 真正需要像素处理的风格（[original] = false，可不建缓存 / 不起 isolate）。
  bool get isStylized => this != CoverStyle.original;

  /// 按稳定 id 解析；非法值（缺键 / 旧数据 / 未来版本）回退 [original]。
  static CoverStyle fromId(String? id) {
    for (final style in values) {
      if (style.id == id) return style;
    }
    return CoverStyle.original;
  }
}

/// 封面风格的作用范围。
enum CoverStyleScope {
  /// 仅播放页（默认）：列表 / 顶栏 / 迷你条保持原图。
  player('player'),

  /// 所有歌曲封面：播放页与列表、顶栏、迷你条等歌曲展示面一致。
  all('all');

  const CoverStyleScope(this.id);

  /// 持久化 / 同步使用的稳定 id。
  final String id;

  /// 按稳定 id 解析；非法值回退 [player]（与默认行为一致）。
  static CoverStyleScope fromId(String? id) {
    for (final scope in values) {
      if (scope.id == id) return scope;
    }
    return CoverStyleScope.player;
  }
}
