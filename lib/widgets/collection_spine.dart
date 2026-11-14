import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 合集标题前的「书脊」细条：没有自定义封面时的统一前导。
///
/// 为什么不用列表封面占位图标：收藏 / 历史 / 本地歌曲 / 智能列表都没有
/// 独立的封面语义，占位图标会让人误以为那里可以放一张图；细条只承担
/// 「这是一本书 / 一个合集」的视觉锚点，和标题同高、克制、不抢内容。
class CollectionSpine extends StatelessWidget {
  const CollectionSpine({super.key, this.width = 3, this.height = 40});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: M3EShapes.radiusExtraSmall,
      ),
    );
  }
}
