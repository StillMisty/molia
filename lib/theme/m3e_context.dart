import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// `BuildContext` 上的 M3E 类型比例快捷入口。
///
/// 页面里反复写 `M3ETheme.of(context).typeScale.bodyMedium` 既啰嗦又容易
/// 随手改成 `Theme.of(context).textTheme...`（两套字号表，后者不跟随 M3E
/// 的 emphasized 变体）。统一经 [typeScale] 取值，后续排版迁移只改这一处。
///
/// 注意：本阶段只提供入口，不批量替换 `textTheme`；替换按 Phase 6 推进。
extension M3ETypeScaleContext on BuildContext {
  M3ETypeScale get typeScale => M3ETheme.of(this).typeScale;
}
