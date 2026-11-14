import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/poster/poster_style_settings.dart';
import 'package:molia/widgets/poster_style_sheet.dart';

Widget _host(Widget child) {
  return M3EMaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: const [Locale('zh')],
    data: M3EThemeData.fromMaterial(ThemeData.light()),
    theme: ThemeData.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('样式弹层：字体 / 取色来源 / 封面三行', (tester) async {
    var fontPicks = 0;
    var coverPicks = 0;
    await tester.pumpWidget(
      _host(
        PosterStyleSheet(
          fontLabel: '字体',
          fontValue: '跟随应用字体',
          onPickFont: () => fontPicks++,
          colorSource: PosterColorSource.appTheme,
          hasArtwork: false,
          onColorSourceChanged: (_) {},
          customColorLabel: '自定义色',
          customColorHex: '#2196F3',
          customColor: 0xFF2196F3,
          onPickCustomColor: () {},
          coverLabel: '封面',
          coverValue: '默认封面',
          onPickCover: () => coverPicks++,
        ),
      ),
    );

    expect(find.text('字体'), findsOneWidget);
    expect(find.text('跟随应用字体'), findsOneWidget);
    expect(find.text('取色来源'), findsOneWidget);
    expect(find.text('封面'), findsOneWidget);
    expect(find.text('默认封面'), findsOneWidget);
    expect(find.byKey(const Key('posterStyleCustomColor')), findsNothing);

    await tester.tap(find.byKey(const Key('posterStyleFont')));
    expect(fontPicks, 1);
    await tester.tap(find.byKey(const Key('posterStyleCover')));
    expect(coverPicks, 1);
  });

  testWidgets('自定义取色时出现色块与 Hex', (tester) async {
    await tester.pumpWidget(
      _host(
        PosterStyleSheet(
          fontLabel: '字体',
          fontValue: '系统默认',
          onPickFont: () {},
          colorSource: PosterColorSource.custom,
          hasArtwork: true,
          onColorSourceChanged: (_) {},
          customColorLabel: '自定义色',
          customColorHex: '#2196F3',
          customColor: 0xFF2196F3,
          onPickCustomColor: () {},
          coverLabel: '封面',
          coverValue: '跟随歌曲',
        ),
      ),
    );

    expect(find.byKey(const Key('posterStyleCustomColor')), findsOneWidget);
    expect(find.text('#2196F3'), findsOneWidget);
  });

  testWidgets('样式弹层不承载保存 / 分享动作', (tester) async {
    await tester.pumpWidget(
      _host(
        PosterStyleSheet(
          fontLabel: '字体',
          fontValue: '跟随应用字体',
          onPickFont: () {},
          colorSource: PosterColorSource.appTheme,
          hasArtwork: false,
          onColorSourceChanged: (_) {},
          customColorLabel: '自定义色',
          customColorHex: '#2196F3',
          customColor: 0xFF2196F3,
          onPickCustomColor: () {},
          coverLabel: '封面',
          coverValue: '默认封面',
        ),
      ),
    );

    expect(find.text('分享'), findsNothing);
    expect(find.text('保存图片'), findsNothing);
  });
}
