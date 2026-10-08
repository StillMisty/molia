import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/pages/sources_page.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';

/// M3E-P3-C 回归：音源列表的 `M3EMenu` 操作菜单与 `M3EDialog` 删除确认
/// 仍可通过文本定位并完成「打开 → 选择 → 取消」交互（旧版为
/// PopupMenuButton + AlertDialog）。
///
/// 说明：脚本直接写入仓库（不激活引擎），避免 widget 测试环境缺少
/// quickjs 桥接库导致激活失败。
const _script = '''
/**
 * @name 菜单测试音源
 * @version 1.0.0
 * @author StillMisty
 */
const { EVENT_NAMES, on, send } = globalThis.lx
on(EVENT_NAMES.request, function (payload) {
  if (payload.action === 'search') {
    return Promise.resolve({ isEnd: true, list: [] })
  }
  return Promise.reject(new Error('unsupported'))
})
send(EVENT_NAMES.inited, {
  sources: {
    test: { name: '菜单测试源', type: 'music', actions: ['search'], qualitys: ['128k'] }
  }
})
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('音源列表 trailing 菜单：打开 → 删除 → 确认框可取消', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    late final SourceManager manager;
    await tester.runAsync(() async {
      manager = SourceManager();
      await manager.init();
      for (final existing in manager.scripts.toList()) {
        await manager.removeScript(existing.id);
      }
      // 直接写入仓库，避免触发真实引擎激活（widget 测试无 quickjs 桥接库）。
      await manager.repository.add(LxScriptInfo.parse(_script)!);
    });
    addTearDown(manager.dispose);
    expect(manager.scripts, hasLength(1));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceManager>.value(value: manager),
          ChangeNotifierProvider<SourcesProvider>(
            create: (_) => SourcesProvider(manager),
          ),
        ],
        child: const MaterialApp(home: SourcesPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 打开 trailing 菜单（M3EMenu anchor）。
    final more = find.byIcon(Icons.more_vert_rounded);
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('启用'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    // 点击删除 → M3EDialog 确认框。
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);
    expect(find.text('删除音源脚本'), findsOneWidget);

    // 取消：弹层关闭，脚本保留。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsNothing);
    expect(manager.scripts, hasLength(1));
  });
}
