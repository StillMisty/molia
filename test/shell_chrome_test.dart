import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/window_controls.dart';
import 'package:molia/app/shell_chrome.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/services/window/window_chrome.dart';

/// 壳层 chrome spec（`ShellChrome`）的钉子：目的地映射 / 索引回调 /
/// 顶栏槽位（两套骨架共用同一份，见 `lib/app/shell_chrome.dart`）。
void main() {
  final l10n = lookupAppLocalizations(const Locale('zh'));

  ShellChrome build({
    List<ShellDestination>? destinations,
    ShellDestination selectedDestination = ShellDestination.favorites,
    ValueChanged<ShellDestination>? onDestinationSelected,
    VoidCallback? onOpenSettings,
  }) {
    final list = destinations ?? ShellDestination.values;
    return ShellChrome(
      destinations: list,
      selectedDestination: selectedDestination,
      selectedIndex: list.indexOf(selectedDestination),
      l10n: l10n,
      onDestinationSelected: onDestinationSelected ?? (_) {},
      onOpenSettings: onOpenSettings ?? () {},
    );
  }

  test('标签 / 图标映射与 nav_destination_style 同源（顺序 = 传入目的地顺序）', () {
    final chrome = build(
      destinations: const [
        ShellDestination.library,
        ShellDestination.nowPlaying,
        ShellDestination.favorites,
      ],
      selectedDestination: ShellDestination.library,
    );

    expect(
      [for (final destination in chrome.railDestinations()) destination.label],
      [l10n.libraryLabel, l10n.nowPlayingLabel, l10n.favoritesLabel],
    );
    expect(
      [for (final destination in chrome.barDestinations()) destination.label],
      [l10n.libraryLabel, l10n.nowPlayingLabel, l10n.favoritesLabel],
    );

    // 未选中空心 / 选中实心成对（收藏半对是圆角字形）。
    final favorites = chrome.railDestinations()[2];
    expect((favorites.icon as Icon).icon, Icons.favorite_border_rounded);
    expect((favorites.selectedIcon! as Icon).icon, Icons.favorite_rounded);
    expect(chrome.labelFor(ShellDestination.library), l10n.libraryLabel);
  });

  test('索引回调：索引 → 目的地（导航轨 / 底栏共用同一条路径）', () {
    final selected = <ShellDestination>[];
    final chrome = build(
      destinations: const [
        ShellDestination.library,
        ShellDestination.favorites
      ],
      onDestinationSelected: selected.add,
    );

    chrome.selectDestinationAt(0);
    chrome.selectDestinationAt(1);

    expect(selected, [ShellDestination.library, ShellDestination.favorites]);
  });

  testWidgets(
    '顶栏槽：统一 titleSpacing / 无返回键 / 拖动区 + 共享尾部动作',
    (tester) async {
    var settingsOpened = 0;
    final chrome = build(onOpenSettings: () => settingsOpened++);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Builder(
          builder: (context) => Scaffold(
            appBar: chrome.appBar(
              context: context,
              title: const Text('页面标题'),
              actions: const [Text('骨架自己的动作')],
            ),
          ),
        ),
      ),
    );

    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.titleSpacing, ShellChrome.appBarTitleSpacing);
    expect(bar.automaticallyImplyLeading, isFalse, reason: '壳层是根页面，不出返回键');
    expect(find.text('页面标题'), findsOneWidget);
    expect(find.text('骨架自己的动作'), findsOneWidget, reason: '前置动作不丢');
    expect(find.byType(WindowDragArea), findsOneWidget, reason: '顶栏整体是拖动区');

    // 尾部动作：设置按钮（走壳层回调）+ 平台支持的窗口控件。
    await tester.tap(find.byIcon(Icons.settings_rounded));
    expect(settingsOpened, 1);
    expect(
      find.byType(WindowControls),
      WindowChrome.isSupported ? findsOneWidget : findsNothing,
    );
  });
}
