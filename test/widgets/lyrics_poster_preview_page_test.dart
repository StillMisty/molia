import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/domain/models/poster_lyric_line.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/lyrics_poster_preview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('海报预览直接渲染位图，不再走 PNG 字节中转', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<CustomCoverStore>.value(value: CustomCoverStore()),
          Provider<NotificationService>.value(value: NotificationService()),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const LyricsPosterPreviewPage(
            lyrics: 'Hello\nWorld',
            posterLyricLines: [
              PosterLyricLine(text: 'Hello'),
              PosterLyricLine(text: 'World'),
            ],
            trackTitle: 'Title',
            artistName: 'Artist',
          ),
        ),
      ),
    );
    await tester.pump();

    // 渲染走真实引擎的 Picture.toImage：testWidgets 的假异步不会驱动
    // 光栅回调，必须用 runAsync 让引擎把任务跑完。
    for (var i = 0; i < 40; i++) {
      if (find.byType(RawImage).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    final preview = find.byType(RawImage);
    expect(preview, findsOneWidget);
    final image = tester.widget<RawImage>(preview).image;
    expect(image, isNotNull);
    expect(image!.width, 1440);
    expect(find.byKey(const Key('posterShareButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
