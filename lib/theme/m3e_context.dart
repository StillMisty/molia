import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// `BuildContext` 上的 M3E 类型比例快捷入口。
///
/// 页面里反复写 `M3ETheme.of(context).typeScale.bodyMedium` 既啰嗦又容易
/// 随手改成 `Theme.of(context).textTheme...`（两套字号表，后者不跟随 M3E
/// 的 emphasized 变体）。统一经 [typeScale] 取值，排版口径只在这里收口。
///
/// 注意：`Theme.of(context).textTheme` 由 `test/architecture/m3e_typography_test.dart`
/// 拦截；主题构建（`lib/theme/app_theme.dart`）是唯一例外。
extension M3ETypeScaleContext on BuildContext {
  M3ETypeScale get typeScale => M3ETheme.of(this).typeScale;

  /// 强调字阶（emphasized）：品牌名 / 播放页标题 / 收藏页大标题等
  /// 「主动强调」的文本用它；普通正文仍走 [typeScale]。
  ///
  /// emphasized 与 baseline 同字号同字高，差异只在字重与字距，所以替换
  /// 不会改变版式高度；应用字体已由 `buildM3EThemeData` 同步到两套字阶。
  M3ETypeScale get emphasizedTypeScale =>
      M3ETheme.of(this).typography.emphasized;
}
