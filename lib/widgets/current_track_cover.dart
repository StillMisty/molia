import 'package:material_ui/material_ui.dart';

import 'library_cover.dart';

/// 当前曲目封面：封面右下角叠「播放中 / 暂停」角标。
///
/// 角标落在 [size] 方形槽内，不改变行内网格（封面位宽固定，标题与表格列
/// 不会因状态切换左右移动）。角标只是状态图形，状态语义由行文本承载
/// （调用方把「正在播放 / 已暂停」写进行的 semanticLabel），这里排除自身
/// 语义，避免读屏重复播报。
class CurrentTrackCover extends StatelessWidget {
  const CurrentTrackCover({
    super.key,
    required this.url,
    required this.size,
    required this.isPlaying,
  });

  final String? url;
  final double size;
  final bool isPlaying;

  /// 角标直径：40 / 44 封面共用同一档，图标再小一圈。
  static const double badgeSize = 18;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          LibraryCoverThumb(url: url, size: size),
          Positioned(
            right: 0,
            bottom: 0,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: badgeSize,
                  child: Center(
                    child: Icon(
                      isPlaying
                          ? Icons.graphic_eq_rounded
                          : Icons.pause_rounded,
                      size: 12,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
