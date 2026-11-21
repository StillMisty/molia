import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/desktop_shell.dart';
import 'package:molia/services/app_branding_service.dart';
import 'package:molia/services/window/window_chrome.dart';
import 'package:molia/widgets/molia_mark.dart';

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

  /// 把鼠标移到品牌区中心并等隐式动画落定；返回的手势由调用方持有到用例结束。
  Future<TestGesture> hoverBrand(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(DesktopShell.searchEntryKey)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return gesture;
  }

  testWidgets('1280 宽：胶囊 40dp 包住标志与应用名，hover 有底色', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(1280, 900),
    );

    final capsule = find.byKey(DesktopShell.brandCapsuleKey);
    expect(capsule, findsOneWidget, reason: '品牌胶囊应挂稳定 Key');
    expect(
      tester.getSize(capsule).height,
      DesktopShell.brandCapsuleHeight,
      reason: '胶囊高 40dp，不占满整条工具行',
    );

    final icon = find.descendant(of: capsule, matching: find.byType(MoliaMark));
    final title = find.descendant(of: capsule, matching: find.text('Molia'));
    expect(icon, findsOneWidget);
    expect(title, findsOneWidget, reason: '宽窗应显示应用名');
    final capsuleRect = tester.getRect(capsule);
    expectContains(capsuleRect, tester.getRect(icon), reason: 'LOGO 应完整落在胶囊内');
    expectContains(
      capsuleRect,
      tester.getRect(title),
      reason: '应用名应完整落在胶囊内（不被胶囊边缘裁切）',
    );

    // 外层命中区仍撑满标题槽（ShellAppBar 的工具行内容高 44dp），胶囊在
    // 里层垂直居中：可点高度不因视觉胶囊 40dp 而缩水。
    final brandRect = tester.getRect(find.byKey(DesktopShell.searchEntryKey));
    expect(
      brandRect.height,
      greaterThanOrEqualTo(DesktopShell.brandCapsuleHeight),
    );
    expect(
      capsuleRect.center.dy,
      closeTo(brandRect.center.dy, 0.01),
      reason: '胶囊应在工具行里垂直居中',
    );

    await hoverBrand(tester);
    expect(tester.getSize(capsule).height, DesktopShell.brandCapsuleHeight);
    final container = tester.widget<AnimatedContainer>(capsule);
    final color = (container.decoration! as BoxDecoration).color!;
    expect(color.a, greaterThan(0), reason: 'hover 后胶囊底色不能还是全透明');
  });

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

  testWidgets('480 宽：标题槽不足时只显示 LOGO 胶囊', (tester) async {
    // 最小窗口 480：真实 Linux / Windows 顶栏还有设置 + 窗口三键，标题槽
    // 被挤到放不下应用名。显式打开自绘标题栏，让这条退化路径不依赖测试宿主
    // 平台（macOS 默认没有窗口三键）。
    WindowChrome.debugUsesCustomTitleBarOverride = true;
    addTearDown(() => WindowChrome.debugUsesCustomTitleBarOverride = null);

    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(480, 900),
    );

    expect(tester.takeException(), isNull, reason: '窄窗不能出现 RenderFlex 溢出');

    final capsule = find.byKey(DesktopShell.brandCapsuleKey);
    expect(capsule, findsOneWidget);
    expect(
      find.descendant(of: capsule, matching: find.byType(MoliaMark)),
      findsOneWidget,
      reason: '窄窗仍保留 LOGO',
    );
    expect(
      find.descendant(of: capsule, matching: find.text('Molia')),
      findsNothing,
      reason: '窄窗退化为仅 LOGO，不挤右侧动作',
    );
    expect(
      tester.getSize(capsule).width,
      closeTo(48, 0.01),
      reason: '仅 LOGO 时胶囊 = 左右 12dp 内边距 + 24dp 标志',
    );

    // 右侧仍保留一段窗口拖动区。
    expect(
      tester.getSize(find.byKey(DesktopShell.titleDragAreaKey)).width,
      greaterThanOrEqualTo(96),
    );
  });
}
