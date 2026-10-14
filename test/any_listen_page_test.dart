import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/pages/any_listen_page.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/source_manager.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 高视口挂载：页面为设置行分组（含说明/字段/开关/按钮），600dp 默认高度
  /// 会把按钮挤出视口，点击无法命中。
  Future<void> pumpPage(WidgetTester tester, AnyListenPage page) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  /// 页面测试统一走 SourcesProvider（独立例：fresh manager；manager 例：
  /// 复用同一 manager 断言状态）。
  SourcesProvider mountProvider(SourceManager manager) {
    final provider = SourcesProvider(manager);
    addTearDown(provider.dispose);
    addTearDown(manager.dispose);
    return provider;
  }

  testWidgets('独立打开：渲染表单且不提示错误', (tester) async {
    final provider = mountProvider(SourceManager());
    await pumpPage(tester, AnyListenPage(provider: provider));

    expect(find.text('any-listen 接入'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('访问令牌（可选）'), findsOneWidget);
    expect(find.text('启用 any-listen 音源'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('连接测试'), findsOneWidget);
  });

  testWidgets('保存：校验地址、写入 any_listen_ 前缀的 prefs', (tester) async {
    final provider = mountProvider(SourceManager());
    await pumpPage(tester, AnyListenPage(provider: provider));

    // 启用但不填地址：保存时给出提示且不落盘
    await tester.tap(find.text('启用 any-listen 音源'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('启用前请填写服务器地址'), findsOneWidget);

    // 填写地址后保存成功
    await tester.enterText(find.byType(M3ETextField).first, '127.0.0.1:9500/');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('any_listen_server_url'), 'http://127.0.0.1:9500');
    expect(prefs.getBool('any_listen_enabled'), isTrue);
  });

  testWidgets('连接测试：缺少地址时给出可读提示（不发请求）', (tester) async {
    final provider = mountProvider(SourceManager());
    await pumpPage(tester, AnyListenPage(provider: provider));

    await tester.tap(find.text('连接测试'));
    await tester.pump();
    expect(find.text('请先填写服务器地址'), findsOneWidget);
  });

  testWidgets('传入 manager 时保存同步到 SourceManager 并刷新可见性', (tester) async {
    final manager = SourceManager();
    final provider = mountProvider(manager);

    await pumpPage(tester, AnyListenPage(provider: provider));

    await tester.enterText(
      find.byType(M3ETextField).first,
      'http://127.0.0.1:9500',
    );
    await tester.tap(find.text('启用 any-listen 音源'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(manager.anyListenAvailable, isTrue);
    expect(
      manager.anyListenConfig,
      const AnyListenConfig(
        serverUrl: 'http://127.0.0.1:9500',
        enabled: true,
      ),
    );
  });
}
