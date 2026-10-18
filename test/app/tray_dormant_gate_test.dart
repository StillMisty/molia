import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/tray_dormant_gate.dart';
import 'package:molia/services/app_presence.dart';

/// 托盘休眠门：隐藏时整棵子树卸载，恢复时重建。
///
/// 真实应用里这个门包住整个 MaterialApp（见 `app_shell.dart`），因此「子树
/// 卸载」等价「导航 / 常驻页面全部释放」；这里用带构建计数的假子树验证
/// 卸载与重建语义，不拉起完整壳层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 存在态单例跨用例共享：每个用例收尾复位。
  tearDown(AppPresence.instance.markVisible);

  testWidgets('托盘隐藏卸载子树；恢复后重建（新元素）', (tester) async {
    var builds = 0;
    await tester.pumpWidget(MaterialApp(
      home: TrayDormantGate(
        color: const Color(0xFF123456),
        child: _CountedSubtree(onBuild: () => builds++),
      ),
    ));
    expect(builds, 1);

    AppPresence.instance.markTrayHidden();
    await tester.pump();
    expect(builds, 1, reason: '休眠期间子树不重建、元素已卸载');

    AppPresence.instance.markVisible();
    await tester.pump();
    expect(builds, 2, reason: '恢复是重建新元素（旧页面状态由持久化回位）');
  });

  testWidgets('最小化不休眠：子树保持挂载', (tester) async {
    var builds = 0;
    await tester.pumpWidget(MaterialApp(
      home: TrayDormantGate(
        color: const Color(0xFF123456),
        child: _CountedSubtree(onBuild: () => builds++),
      ),
    ));

    AppPresence.instance.markMinimized();
    await tester.pump();

    expect(builds, 1);
  });
}

class _CountedSubtree extends StatelessWidget {
  const _CountedSubtree({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}
