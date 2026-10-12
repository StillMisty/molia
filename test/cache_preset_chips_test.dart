import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/cache_management_page.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';

/// 回归：缓存上限弹层的预设 chip 换行时必须有行距。
///
/// `Wrap` 的 `runSpacing` 缺省为 0，两行 chip 竖直贴边会被看成「叠在一起」。
/// 本测试在会触发换行的弹层宽度下量取每个 chip 的实际矩形，断言水平区间
/// 相交（同列换行）的 chip 之间垂直间距 ≥ 8。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late CacheService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('cache_chip_test_');
    service = CacheService(
      prefs: await SharedPreferences.getInstance(),
      storage: IoCacheStorage(
        audioDirOverride: '${tempRoot.path}/audio_cache',
        artworkDirOverride: '${tempRoot.path}/artwork_cache',
      ),
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  testWidgets('缓存上限预设 chip 换行后行距 8px，不相互贴边', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      Provider<CacheService>.value(
        value: service,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData()),
          theme: ThemeData(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: const CacheManagementPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Size limit'));
    await tester.pumpAndSettle();

    // 只量弹层里的预设 chip（页面其余部分没有 chip）。
    final rects = <Rect>[
      for (final element in find.byType(M3EChip).evaluate())
        tester.getRect(find.byWidget(element.widget)),
    ];
    expect(
      rects.length,
      5,
      reason: '预设应有 5 个 chip（256MB / 512MB / 1GB / 2GB / 不限）',
    );

    var wrapped = false;
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final a = rects[i];
        final b = rects[j];
        final xOverlap = a.left < b.right && b.left < a.right;
        if (!xOverlap) continue;
        final gap = a.bottom <= b.top
            ? b.top - a.bottom
            : (b.bottom <= a.top ? a.top - b.bottom : 0.0);
        if (gap > 0) wrapped = true;
        expect(gap, greaterThanOrEqualTo(8.0),
            reason: '同列 chip 换行后行距缺失：$a 与 $b');
      }
    }
    expect(wrapped, isTrue, reason: '该弹层宽度应触发预设 chip 换行，否则本测试无效');
  });
}
