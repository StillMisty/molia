import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/lyrics_poster_preview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CustomCoverStore store;

  Uint8List pngBytes(int shade) {
    final source = image.Image(width: 8, height: 8);
    image.fill(source, color: image.ColorRgb8(shade, shade, shade));
    return Uint8List.fromList(image.encodePng(source));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('molia_poster_cover_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await store.load();
    CustomCoverStore.overrideInstance(store);
  });

  tearDown(() {
    CustomCoverStore.overrideInstance(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('海报预览：封面行打开共享弹层，自定义后标签立即更新', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final original = File('${tempDir.path}/original.png')
      ..writeAsBytesSync(pngBytes(40));
    const trackId = TrackId('kw', 'poster');
    final themedData = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    );

    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(themedData),
        theme: themedData,
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: LyricsPosterPreviewPage(
          lyrics: '第一行\n第二行',
          trackTitle: 'Title',
          artistName: 'Artist',
          albumCoverUrl: original.uri.toString(),
          trackId: trackId,
        ),
      ),
    );
    await tester.pump();
    // 海报生成包含真实文件 I/O（temp 文件），widget test 的 fake async
    // 不会自动推进它：交替 runAsync / pump，让后台任务与帧都前进。
    final coverButton = find.byKey(const Key('posterCoverPickerButton'));
    for (var i = 0; i < 40 && coverButton.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(coverButton, findsOneWidget);
    expect(find.text('跟随歌曲'), findsOneWidget);

    await tester.runAsync(() => store.setTrackCover(trackId, pngBytes(200)));
    for (var i = 0; i < 40 && find.text('已自定义').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('已自定义'), findsOneWidget);

    await tester.tap(coverButton);
    await tester.pump();
    final chooseButton = find.byKey(const Key('coverPickerChooseButton'));
    for (var i = 0; i < 30 && chooseButton.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chooseButton, findsOneWidget);
    expect(find.byKey(const Key('coverPickerResetButton')), findsOneWidget);
  });
}
