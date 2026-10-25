import 'package:flutter_test/flutter_test.dart';

import '../support/perf_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('性能场景装配：收藏首屏可见', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 20,
    );

    expect(find.text('Performance Track 0'), findsOneWidget);
    expect(find.text('Performance Track 19'), findsNothing); // 懒构建
  });
}
