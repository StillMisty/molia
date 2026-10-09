import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// 歌词/队列切换：小圆点指示器（选中态拉伸），无图标/文字。
///
/// 圆点占位极小，紧凑布局下也放得下；与 PageView 页码双向同步。
/// 点击未激活圆点切换页面；点击已激活圆点触发 [onActiveTap]（播放页用于
/// 展开/收起播放器）。
class LyricsQueueDots extends StatefulWidget {
  final List<PageData> pages;
  final PageController pageController;

  /// 点击「已激活」圆点的回调；为空时点击已激活圆点无动作。
  final VoidCallback? onActiveTap;

  const LyricsQueueDots({
    super.key,
    required this.pages,
    required this.pageController,
    this.onActiveTap,
  });

  @override
  State<LyricsQueueDots> createState() => _LyricsQueueDotsState();
}

class _LyricsQueueDotsState extends State<LyricsQueueDots> {
  late int currentPage = widget.pageController.initialPage;

  @override
  void initState() {
    super.initState();
    widget.pageController.addListener(_onPageChange);
  }

  @override
  void dispose() {
    widget.pageController.removeListener(_onPageChange);
    super.dispose();
  }

  void _onPageChange() {
    final page = widget.pageController.page?.round() ?? currentPage;
    if (page != currentPage) {
      setState(() {
        currentPage = page;
      });
    }
  }

  void _selectPage(int index) {
    if (index == currentPage) {
      // 再点已激活圆点：交给宿主（播放页 = 展开/收起切换）。
      widget.onActiveTap?.call();
      return;
    }
    HapticFeedback.lightImpact();
    widget.pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < widget.pages.length; index++)
          // 标题仅作为 tooltip/无障碍描述保留（不占视觉空间）。
          Tooltip(
            message: widget.pages[index].title,
            child: GestureDetector(
              // translucent：圆点浮在内容上，点击选中响应、同时让横向滑动
              // 继续传给下方 PageView（opaque 会把翻页手势吃掉）。
              behavior: HitTestBehavior.translucent,
              onTap: () => _selectPage(index),
              child: SizedBox(
                width: 36,
                height: 28,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    width: index == currentPage ? 18 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      // 选中点用 primary 强调；未选中是「非激活」指示，
                      // 用中性 onSurfaceVariant（不抢强调色）。
                      color: index == currentPage
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 队列/歌词页的页面数据。
class PageData {
  final String title;
  final IconData icon;
  final Widget page;

  PageData({
    required this.title,
    required this.icon,
    required this.page,
  });
}
