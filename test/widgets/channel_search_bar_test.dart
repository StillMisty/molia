import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/channel_search_bar.dart';
import 'package:molia/widgets/discover_layout.dart';

/// 组合搜索条：单层胶囊、渠道下拉占搜索图标位、单渠道回退标准搜索栏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SourceDescriptor channel(String key, String name) => SourceDescriptor(
    key: key,
    displayName: name,
    kind: SourceKind.builtin,
    capabilities: const SourceCapabilities(search: true),
  );

  Future<({TextEditingController controller, FocusNode focusNode})> pumpBar(
    WidgetTester tester, {
    required List<SourceDescriptor> channels,
    double width = 640,
    TextScaler textScaler = TextScaler.noScaling,
    bool autofocus = false,
    VoidCallback? onEscape,
  }) async {
    tester.view.physicalSize = Size(width, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
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
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: Scaffold(
              body: Center(
                child: ChannelSearchBar(
                  controller: controller,
                  focusNode: focusNode,
                  hintText: '搜索',
                  channels: channels,
                  selectedKey: channels.first.key,
                  onChannelSelected: (_) {},
                  autofocus: autofocus,
                  onEscape: onEscape,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller: controller, focusNode: focusNode);
  }

  Finder itemCard(String label) => find
      .ancestor(of: find.text(label).last, matching: find.byType(M3ECard))
      .first;

  testWidgets('单渠道：不渲染渠道下拉，保留标准搜索栏与搜索图标', (tester) async {
    await pumpBar(tester, channels: [channel('kw', '酷我音乐')]);

    expect(find.byKey(ChannelSearchBar.channelDropdownKey), findsNothing);
    expect(find.byType(M3ESearchBar), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.text('酷我音乐'), findsNothing, reason: '单渠道没有 chip');
  });

  testWidgets('多渠道：单层胶囊、无第二层搜索栏与搜索图标', (tester) async {
    await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
      width: 640,
    );

    final dropdown = find.byKey(ChannelSearchBar.channelDropdownKey);
    expect(dropdown, findsOneWidget);
    expect(
      find.byType(M3ESearchBar),
      findsNothing,
      reason: '不再嵌套 AppSearchBar',
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChannelSearchBar),
        matching: find.byIcon(Icons.search_rounded),
      ),
      findsNothing,
      reason: 'dropdown 占据搜索图标位置',
    );
    expect(
      tester.getRect(dropdown).right,
      lessThanOrEqualTo(tester.getRect(find.byType(TextField)).left),
    );
  });

  testWidgets('渠道 chip：secondaryContainer 填充、无描边、四周内缩', (tester) async {
    await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
    );
    final context = tester.element(find.byType(ChannelSearchBar));
    final scheme = M3ETheme.of(context).colorScheme;
    final barRect = tester.getRect(find.byType(M3ECard).first);
    final selectedText = find.text('酷我音乐');
    final chipFinder = find
        .ancestor(of: selectedText, matching: find.byType(Material))
        .first;
    final chip = tester.widget<Material>(chipFinder);
    final chipRect = tester.getRect(chipFinder);
    final text = tester.widget<Text>(selectedText);

    expect(chip.color, scheme.secondaryContainer);
    expect(text.style?.color, scheme.onSecondaryContainer);
    expect(
      chip.shape,
      isA<RoundedRectangleBorder>().having(
        (shape) => shape.side,
        'side',
        BorderSide.none,
      ),
    );
    expect(chipRect.left - barRect.left, greaterThanOrEqualTo(5));
    expect(chipRect.top - barRect.top, greaterThanOrEqualTo(5));
    expect(barRect.bottom - chipRect.bottom, greaterThanOrEqualTo(5));
    expect(
      chipRect.height,
      closeTo(barRect.height - 12, 0.5),
      reason: '1× 下 chip 填满搜索条减掉上下 6dp 的剩余高度',
    );
    final selectorWidth = discoverChannelSelectorWidth(context);
    expect(
      barRect.left + selectorWidth - chipRect.right,
      greaterThanOrEqualTo(3),
      reason: 'chip 在左侧选择区内右侧留约 4dp',
    );
  });

  testWidgets('渠道 chip：1.5× 字体与长名称仍不贴边、不裁切', (tester) async {
    const longName = '一个非常非常长、窄搜索条里必须省略而不能换行的渠道名称';
    await pumpBar(
      tester,
      channels: [channel('long', longName), channel('kw', '酷我音乐')],
      width: 360,
      textScaler: const TextScaler.linear(1.5),
    );

    expect(tester.takeException(), isNull);
    final barRect = tester.getRect(find.byType(M3ECard).first);
    final chipFinder = find
        .ancestor(of: find.text(longName), matching: find.byType(Material))
        .first;
    final chipRect = tester.getRect(chipFinder);
    expect(chipRect.top - barRect.top, greaterThanOrEqualTo(5));
    expect(barRect.bottom - chipRect.bottom, greaterThanOrEqualTo(5));
    expect(chipRect.left - barRect.left, greaterThanOrEqualTo(5));
    expect(
      chipRect.height,
      lessThan(barRect.height),
      reason: '放大字体后 chip 仍完整落在搜索条内',
    );
  });

  testWidgets('清除键：清空文本、触发 onChanged 并保留焦点', (tester) async {
    final handles = await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(handles.controller.text, 'hello');

    final clear = find.descendant(
      of: find.byType(ChannelSearchBar),
      matching: find.byIcon(Icons.close_rounded),
    );
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await tester.pump();

    expect(handles.controller.text, isEmpty);
    expect(handles.focusNode.hasFocus, isTrue);
  });

  testWidgets('Esc：自定义输入框仍把按键交给 onEscape', (tester) async {
    var escaped = 0;
    await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
      autofocus: true,
      onEscape: () => escaped++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(escaped, 1);
  });

  testWidgets('渠道下拉：长名称单行、选中项与未选中项行高一致', (tester) async {
    const longName = '一个非常非常长、窄弹窗里必须省略而不能换行的渠道名称';
    await pumpBar(
      tester,
      channels: [channel('long', longName), channel('kw', '酷我音乐')],
      width: 360,
      textScaler: const TextScaler.linear(1.5),
    );

    await tester.tap(find.byKey(ChannelSearchBar.channelDropdownKey));
    await tester.pumpAndSettle();

    final longText = tester.widget<Text>(find.text(longName).last);
    expect(longText.maxLines, 1);
    expect(longText.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(itemCard(longName)).height,
      tester.getSize(itemCard('酷我音乐')).height,
      reason: '选中项多一个 check icon 不能改变行高',
    );
  });

  testWidgets('窄窗 + 1.5× 字体不溢出', (tester) async {
    await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
      width: 360,
      textScaler: const TextScaler.linear(1.5),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(ChannelSearchBar.channelDropdownKey), findsOneWidget);
  });
}
