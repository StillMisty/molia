import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// AppSearchBar 在系统文字放大时不能把 hint 行框压在 56dp 里裁掉。
///
/// 这里不依赖真实字体：断言约束随 textScaler 增长、1.0× 仍为 56；
/// 真机 CJK 字体的截图验证见 `docs/` / 发布记录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBar(WidgetTester tester, TextScaler scaler) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: AppSearchBar(controller: controller, hintText: '搜索歌单'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1.0× 保持 56dp minHeight', (tester) async {
    await pumpBar(tester, TextScaler.noScaling);

    final bar = tester.widget<M3ESearchBar>(find.byType(M3ESearchBar));
    expect(bar.constraints?.minHeight, 56);
    expect(
      appSearchBarMinHeightOf(tester.element(find.byType(M3ESearchBar))),
      56,
      reason: '全局搜索占位锚点与真实搜索栏同源',
    );
    expect(find.text('搜索歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1.3× minHeight 随实测行高增长，hint 行框同步加高', (tester) async {
    await pumpBar(tester, const TextScaler.linear(1.3));

    final bar = tester.widget<M3ESearchBar>(find.byType(M3ESearchBar));
    expect(bar.constraints?.minHeight, greaterThan(56));
    expect(
      appSearchBarMinHeightOf(tester.element(find.byType(M3ESearchBar))),
      bar.constraints!.minHeight,
      reason: '全局搜索占位锚点必须跟着长高，否则结果面板错位',
    );
    expect(
      tester.getSize(find.byType(M3ESearchBar)).height,
      greaterThanOrEqualTo(bar.constraints!.minHeight),
    );

    final hint = tester.widget<Text>(find.text('搜索歌单'));
    final baseHint = M3ETheme.of(tester.element(find.byType(M3ESearchBar)))
        .searchBarTheme
        .hintStyle(
          M3ETheme.of(tester.element(find.byType(M3ESearchBar))).typeScale,
          M3ETheme.of(tester.element(find.byType(M3ESearchBar))).colorScheme,
        );
    expect(hint.style?.height, greaterThanOrEqualTo(baseHint.height ?? 1));
    expect(tester.takeException(), isNull);
  });
}
