import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/card_list_surface.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

/// 条件行隐藏时不参与卡片形状计算：隐藏的末行不能让上一条可见行停留在
/// 「内行」4dp 圆角（卡片底部会看起来是断的）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCard(WidgetTester tester, {required bool reveal}) {
    return tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: SettingsSectionCard(
            children: [
              SettingsSwitchTile(
                switchKey: const Key('firstRowSwitch'),
                icon: Icons.wifi_rounded,
                title: '第一行',
                subtitle: '',
                value: true,
                onChanged: (_) {},
              ),
              SettingsReveal(
                visible: reveal,
                child: SettingsSwitchTile(
                  switchKey: const Key('revealedRowSwitch'),
                  icon: Icons.image_rounded,
                  title: '条件行',
                  subtitle: '',
                  value: true,
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  M3ECardPosition positionOf(WidgetTester tester, Key switchKey) {
    final surface = find.ancestor(
      of: find.byKey(switchKey),
      matching: find.byType(CardListSurface),
    );
    return tester.widget<CardListSurface>(surface.first).position;
  }

  testWidgets('隐藏的条件末行不计数：上一行按 single 画', (tester) async {
    await pumpCard(tester, reveal: false);
    await tester.pumpAndSettle();
    expect(
      positionOf(tester, const Key('firstRowSwitch')),
      M3ECardPosition.single,
    );
  });

  testWidgets('条件行可见时按 first / last 分段', (tester) async {
    await pumpCard(tester, reveal: true);
    await tester.pumpAndSettle();
    expect(
      positionOf(tester, const Key('firstRowSwitch')),
      M3ECardPosition.first,
    );
    expect(
      positionOf(tester, const Key('revealedRowSwitch')),
      M3ECardPosition.last,
    );
  });

  testWidgets('值行超长值在 360 宽省略而不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: SettingsSectionCard(
            children: [
              SettingsValueTile(
                icon: Icons.description_rounded,
                title: '文件名模板',
                value: '{artist} - {album} - {title} - {quality} - {source}',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
