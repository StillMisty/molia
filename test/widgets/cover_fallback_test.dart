import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/cover_fallback.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回退封面：默认封面优先，默认封面自身失败时回到 Molia 标志且不递归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CustomCoverStore store;

  Uint8List pngBytes() {
    final source = image.Image(width: 4, height: 4);
    return Uint8List.fromList(image.encodePng(source));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('molia_cover_fallback_');
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    CustomCoverStore.overrideInstance(store);
  });

  tearDown(() {
    CustomCoverStore.overrideInstance(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget host() => MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => buildFallbackArtwork(context)),
        ),
      );

  testWidgets('未设置默认封面：回退 Molia 标志', (tester) async {
    await tester.runAsync(store.load);
    await tester.pumpWidget(host());

    expect(find.byType(MoliaMark), findsOneWidget);
  });

  testWidgets('已设置默认封面：回退展示默认封面而不是 Molia 标志', (tester) async {
    await tester.runAsync(store.load);
    await tester.runAsync(() => store.setDefaultCover(pngBytes()));
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MoliaMark), findsNothing);
  });

  testWidgets('默认封面文件失效：回到 Molia 标志，不递归', (tester) async {
    await tester.runAsync(store.load);
    await tester.runAsync(() => store.setDefaultCover(pngBytes()));
    File(store.defaultEntry!.path).deleteSync();

    await tester.pumpWidget(host());
    for (var i = 0; i < 40 && find.byType(MoliaMark).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(MoliaMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
