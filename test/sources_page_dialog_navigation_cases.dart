import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/pages/sources_page.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/source_manager.dart';
import 'support/settings_test_support.dart';

/// 回归：设置弹层内打开的音源页位于嵌套 Navigator 栈顶，而 `M3EDialog.show`
/// 固定把弹层推入 root Navigator。弹层动作若用页面 context 调 `Navigator.pop`，
/// 弹掉的是嵌套 Navigator 的栈顶（音源页本身），表现为「点下载并导入直接退出
/// 音源页」。本测试复刻该结构并锁死正确行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('链接导入弹层：下载并导入只关弹层，音源页保留并进入免责声明', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late final SourceManager manager;
    await tester.runAsync(() async {
      manager = SourceManager(settings: testSettingsRegistry());
      await manager.init();
      for (final existing in manager.scripts.toList()) {
        await manager.removeScript(existing.id);
      }
    });
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceManager>.value(value: manager),
          ChangeNotifierProvider<SourcesProvider>(
            create: (_) => SourcesProvider(manager),
          ),
        ],
        child: const MaterialApp(home: _NestedHost()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开音源页'));
    await tester.pumpAndSettle();
    expect(find.byType(SourcesPage), findsOneWidget);

    await tester.tap(find.text('从链接导入'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.enterText(
      find.byType(M3ETextField),
      'https://example.com/source.js',
    );
    await tester.tap(find.text('下载并导入'));
    await tester.pumpAndSettle();

    // 音源页必须还在；导入弹层关闭，免责声明确认弹层打开。
    expect(find.byType(SourcesPage), findsOneWidget);
    expect(find.text('继续导入'), findsOneWidget);

    // 取消免责声明：回到音源页，不发起下载。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsNothing);
    expect(find.byType(SourcesPage), findsOneWidget);
  });
}

/// 复刻设置弹层结构：内层 Navigator 承载子页，root Navigator 之上推弹层。
class _NestedHost extends StatelessWidget {
  const _NestedHost();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const _NestedHome(),
      ),
    );
  }
}

class _NestedHome extends StatelessWidget {
  const _NestedHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: M3EButton.filled(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SourcesPage()),
          ),
          child: const Text('打开音源页'),
        ),
      ),
    );
  }
}
