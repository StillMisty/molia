import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/app_shell.dart';

/// 壳层页面分层的几何不变量：**隐藏页（未参与过渡 / 出场过渡已结束）
/// 必须 scale == 1**。
///
/// 顶栏⇄播放页飞行在点击那一刻同步抓取锚点（`localToGlobal` 含祖先变换），
/// 隐藏页残留的非 1 缩放会让飞行副本落在错误的位置/尺寸上，交接瞬间真身
/// 跳变（回归：「飞过头再复位」）。
void main() {
  test('出场过渡结束：微缩归零（不再残留 0.97）', () {
    // 回归：出场页停在 outgoing 分支、静置在 0.97 时，点顶栏封面进播放页，
    // 副本会飞向缩小后的矩形，交接时真身弹回。
    final settled = shellPageLayerPresentation(
      selected: false,
      outgoing: true,
      progress: 1.0,
    );
    expect(settled.opacity, 0.0);
    expect(settled.scale, 1.0);
  });

  test('出场过渡中：保留淡出 + 微缩观感', () {
    final mid = shellPageLayerPresentation(
      selected: false,
      outgoing: true,
      progress: 0.35,
    );
    expect(mid.opacity, lessThan(1.0));
    expect(mid.opacity, greaterThan(0.0));
    expect(mid.scale, lessThan(1.0));
    expect(mid.scale, greaterThanOrEqualTo(0.97));
  });

  test('入场完成：opacity 1、scale 1', () {
    final done = shellPageLayerPresentation(
      selected: true,
      outgoing: false,
      progress: 1.0,
    );
    expect(done.opacity, 1.0);
    expect(done.scale, 1.0);
  });

  test('入场中：只淡入不微缩', () {
    final mid = shellPageLayerPresentation(
      selected: true,
      outgoing: false,
      progress: 0.5,
    );
    expect(mid.opacity, greaterThan(0.0));
    expect(mid.opacity, lessThanOrEqualTo(1.0));
    expect(mid.scale, 1.0);
  });

  test('未参与过渡：完全隐藏且几何为 1', () {
    final idle = shellPageLayerPresentation(
      selected: false,
      outgoing: false,
      progress: 0.5,
    );
    expect(idle.opacity, 0.0);
    expect(idle.scale, 1.0);
  });

  test('壳层顶栏关闭自动返回键（路由局部历史不应冒出返回箭头）', () {
    // 回归：M3E 下拉菜单打开时会往当前路由加一条 LocalHistoryEntry
    // （系统返回先关菜单），ModalRoute.canPop 因此变真，默认的
    // automaticallyImplyLeading 会在顶栏画出一个返回箭头。
    // 两套骨架的顶栏本体已收进 ShellAppBar（唯一显式配置处）。
    final source = File('lib/app/shell_app_bar.dart').readAsStringSync();
    expect(
      source,
      contains('automaticallyImplyLeading: false'),
      reason: '壳层是根页面，顶栏不参与返回；请保留该显式配置',
    );
  });
}
