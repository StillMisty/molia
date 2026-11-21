/// 无设备 UI 预览：在 360 / 640 宽渲染真实壳层、播放页展开 / 收起，并在桌面
/// 1280 / 480 宽截顶栏品牌胶囊；写出 PNG 供 agent `read`。
///
/// 运行：`tool/agent/ui_preview.sh`（脚本设置 `UI_PREVIEW_DIR` 并调用
/// `flutter test test/preview/ui_preview.dart`）。默认不写入仓库。
///
/// 为什么放在 `test/preview/` 且不叫 `*_test.dart`：默认 `flutter test` 不应
/// 每次都写截图；显式指定路径才运行。预览的是共享壳层 / 设置弹层，
/// 覆盖 AGENTS 要求的「360 与 640 宽先看比例」。测试引擎用测试字体，中文
/// 可能显示为方块：这张图看比例 / 溢出 / 密度，不用于校对文案。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/desktop_shell.dart';
import 'package:molia/services/window/window_chrome.dart';
import 'package:molia/widgets/molia_mark.dart';

import '../support/perf_app_harness.dart';

const Key _previewKey = Key('uiPreviewBoundary');

/// 加载系统 CJK 字体：测试宿主默认字体只有拉丁字形，中文截图会是一排方块。

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_previewKey),
  );
  // toImage / PNG 编码走真实异步：必须 runAsync，否则 fake-async 会卡住。
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data;
  });
  if (bytes == null) return;
  final dir =
      Platform.environment['UI_PREVIEW_DIR'] ??
      '${Directory.systemTemp.path}/molia-ui-preview';
  Directory(dir).createSync(recursive: true);
  final file = File('$dir/$name.png');
  file.writeAsBytesSync(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('preview: ${file.path}');
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 40}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 点底栏 / 导航轨的播放目的地（Molia 标志图标）。
///
/// 360 走底栏、640 走导航轨；按图标定位，两种骨架都成立。不要在展开后
/// 再按标签找：展开态播放页里没有同名导航文字。
Future<void> _openPlayerDestination(WidgetTester tester) async {
  final bar = find.byType(M3ENavigationBar);
  final rail = find.byType(M3ENavigationRail);
  final nav = bar.evaluate().isNotEmpty ? bar : rail;
  expect(nav, findsOneWidget, reason: '当前宽度应命中底栏或导航轨');
  final mark = find.descendant(of: nav, matching: find.byType(MoliaMark));
  expect(mark, findsWidgets, reason: '播放目的地应使用 MoliaMark');
  await tester.tap(mark.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in const [360.0, 640.0]) {
    testWidgets('UI 预览 ${width.toInt()} 宽', (tester) async {
      // 预览的是手机 / 平板版式：测试宿主机是 Linux，不覆盖平台会带上
      // 桌面窗口三键，360 宽顶栏会出现只在 Linux 测试宿主存在的溢出。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      WindowChrome.debugUsesCustomTitleBarOverride = false;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        WindowChrome.debugUsesCustomTitleBarOverride = null;
      });
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 8,
        size: Size(width, 900),
        wrap: (child) => RepaintBoundary(key: _previewKey, child: child),
      );
      await _pumpFrames(tester);

      // 收藏首屏：顶栏迷你播放器 + 底栏导航 + 合集列表。
      await _capture(tester, 'favorites-${width.toInt()}');

      // 发现页：渠道行 + 图标 tab + 搜索条（共享工具栏的代表）。
      // 360 走底栏、640 走导航轨；按标签定位，两种骨架都成立。
      await tester.tap(find.text('发现').first);
      await _pumpFrames(tester, frames: 60);
      await _capture(tester, 'discover-${width.toInt()}');

      // 设置弹层：首屏分组卡片与共享设置行。
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await _pumpFrames(tester, frames: 60);
      await _capture(tester, 'settings-${width.toInt()}');

      // 关掉设置弹层，回到一级页再进播放页。
      await tester.binding.handlePopRoute();
      await _pumpFrames(tester, frames: 60);

      // 播放页展开：进入一级页的播放目的地总是展开；顶栏让位给品牌位。
      await _openPlayerDestination(tester);
      await _pumpFrames(tester, frames: 120);
      await _capture(tester, 'player-expanded-${width.toInt()}');

      // 播放页收起：系统返回先把播放器收到 0 高度，顶栏播放条回来，
      // 页内不应再有 72dp 迷你条。
      await tester.binding.handlePopRoute();
      await _pumpFrames(tester, frames: 150);
      await _capture(tester, 'player-collapsed-${width.toInt()}');
    });
  }

  // 桌面品牌区：1280 宽 hover 胶囊，480 宽验证只剩 LOGO。
  for (final (width, hover) in const [(1280.0, true), (480.0, false)]) {
    testWidgets('UI 预览桌面品牌 ${width.toInt()} 宽', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      WindowChrome.debugUsesCustomTitleBarOverride = true;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        WindowChrome.debugUsesCustomTitleBarOverride = null;
      });
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 8,
        size: Size(width, 900),
        wrap: (child) => RepaintBoundary(key: _previewKey, child: child),
      );
      await _pumpFrames(tester);

      if (hover) {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await tester.pump();
        await gesture.moveTo(
          tester.getCenter(find.byKey(DesktopShell.searchEntryKey)),
        );
        // hover 底色是 effects 时长过渡：多泵一会儿再截图。
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await _capture(tester, 'desktop-brand-${width.toInt()}');
    });
  }
}
