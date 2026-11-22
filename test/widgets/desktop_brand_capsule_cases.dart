import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/desktop_shell.dart';
import 'package:molia/services/app_branding_service.dart';

import '../support/perf_app_harness.dart';

/// 桌面顶栏品牌胶囊的几何与长名称适配：胶囊包住 LOGO / 应用名、hover 有底色、
/// 长名称单行省略、窄窗口退化为仅 LOGO。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 矩形内外关系（[Rect.contains] 不含右 / 下边界，胶囊 padding 正好落在
  /// 边界上时会被判成「不包含」）。
  void expectContains(Rect outer, Rect inner, {String? reason}) {
    expect(inner.left, greaterThanOrEqualTo(outer.left), reason: reason);
    expect(inner.top, greaterThanOrEqualTo(outer.top), reason: reason);
    expect(inner.right, lessThanOrEqualTo(outer.right), reason: reason);
    expect(inner.bottom, lessThanOrEqualTo(outer.bottom), reason: reason);
  }

  testWidgets('长名称：单行省略且胶囊宽度不超过上限', (tester) async {
    final previousTitle = AppBrandingService.titleNotifier.value;
    addTearDown(() => AppBrandingService.titleNotifier.value = previousTitle);

    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(1280, 900),
    );

    const longTitle = 'Molia Long Custom Application Name That Must Be Cut';
    AppBrandingService.titleNotifier.value = longTitle;
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '长名称不能撑出 RenderFlex 溢出');

    final capsule = find.byKey(DesktopShell.brandCapsuleKey);
    expect(
      tester.getSize(capsule).width,
      lessThanOrEqualTo(DesktopShell.brandMaxWidth),
      reason: '品牌胶囊必须受最大宽度约束',
    );

    final title = find.descendant(of: capsule, matching: find.text(longTitle));
    expect(title, findsOneWidget);
    final text = tester.widget<Text>(title);
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);

    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(paragraph.didExceedMaxLines, isTrue, reason: '长名称应在胶囊内真正省略，而不是撑宽胶囊');
    expectContains(tester.getRect(capsule), tester.getRect(title));
  });
}
