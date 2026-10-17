/// 桌面骨架的队列右面板。
///
/// 宽度 260–480（默认 360）、左缘可拖；内容复用 [QueueDisplay] 并开启
/// `includeCurrent`（顶部补一行「正在播放」，与移动端播放页队列页的差别
/// 只在这里）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/queue.dart';

/// 队列右面板：头部（标题 + 关闭）+ 队列列表 + 左缘拖动条。
class DesktopQueuePanel extends StatefulWidget {
  const DesktopQueuePanel({
    super.key,
    required this.width,
    required this.onWidthChanged,
    required this.onWidthChangeEnd,
    required this.onClose,
  });

  /// 左缘拖动条宽度（6–8dp：够抓，不挤压列表）。
  static const double resizeHandleWidth = 8;

  /// 当前面板宽度（拖动期由宿主逐帧下发，松手持久化）。
  final double width;

  /// 拖动中：即时改宽（宿主负责 clamp）。
  final ValueChanged<double> onWidthChanged;

  /// 拖动结束：把最终宽度落盘。
  final ValueChanged<double> onWidthChangeEnd;

  /// 关闭面板（头部关闭按钮）。
  final VoidCallback onClose;

  @override
  State<DesktopQueuePanel> createState() => _DesktopQueuePanelState();
}

class _DesktopQueuePanelState extends State<DesktopQueuePanel> {
  /// 队列滚动控制器：面板随开关挂载 / 卸载，控制器跟着本 State 生命周期。
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: widget.width,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左缘拖动条：向左拖 = 变宽（面板贴右缘，左缘是自由边）。
          MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  widget.onWidthChanged(widget.width - details.delta.dx),
              onHorizontalDragEnd: (_) => widget.onWidthChangeEnd(widget.width),
              child: const SizedBox(
                width: DesktopQueuePanel.resizeHandleWidth,
              ),
            ),
          ),
          const M3EDivider(axis: M3EDividerAxis.vertical),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.playerBarQueue,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  // includeCurrent：面板没有播放器承载当前曲目，队列要自带
                  // 「正在播放」一行（与播放页版面相反，见 QueueDisplay 文档）。
                  child: QueueDisplay(
                    controller: _scrollController,
                    includeCurrent: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
