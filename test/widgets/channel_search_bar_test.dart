import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/channel_search_bar.dart';

/// 组合搜索条：单渠道隐藏下拉、多渠道时下拉在输入左侧，窄窗 / 大字体不溢出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SourceDescriptor channel(String key, String name) => SourceDescriptor(
    key: key,
    displayName: name,
    kind: SourceKind.builtin,
    capabilities: const SourceCapabilities(search: true),
  );

  Future<void> pumpBar(
    WidgetTester tester, {
    required List<SourceDescriptor> channels,
    double width = 640,
    TextScaler textScaler = TextScaler.noScaling,
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('单渠道：不渲染渠道下拉，输入占满整条', (tester) async {
    await pumpBar(tester, channels: [channel('kw', '酷我音乐')]);

    expect(find.byKey(ChannelSearchBar.channelDropdownKey), findsNothing);
    expect(find.byType(M3ESearchBar), findsOneWidget);
  });

  testWidgets('多渠道：下拉在输入左侧，窄窗 + 1.5× 字体不溢出', (tester) async {
    await pumpBar(
      tester,
      channels: [channel('kw', '酷我音乐'), channel('tx', 'QQ音乐')],
      width: 360,
      textScaler: const TextScaler.linear(1.5),
    );

    expect(tester.takeException(), isNull);
    final dropdown = find.byKey(ChannelSearchBar.channelDropdownKey);
    expect(dropdown, findsOneWidget);
    final bar = find.byType(M3ESearchBar);
    expect(
      tester.getRect(dropdown).right,
      lessThanOrEqualTo(tester.getRect(bar).left),
      reason: '渠道下拉在搜索输入左侧',
    );
  });
}
