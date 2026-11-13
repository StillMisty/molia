import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/onboarding_flow.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/onboarding_store.dart';
import 'package:molia/sources/source_manager.dart' hide SourceKind;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

class _FakeSources extends SourcesProvider {
  _FakeSources() : super(SourceManager(settings: testSettingsRegistry()));

  bool ready = false;
  String quality = '320k';
  final List<(String, bool)> channelCalls = [];
  final List<String> qualityCalls = [];

  static const List<SourceDescriptor> _channels = [
    SourceDescriptor(key: 'kw', displayName: '酷我音乐', kind: SourceKind.builtin),
    SourceDescriptor(key: 'tx', displayName: 'QQ 音乐', kind: SourceKind.builtin),
  ];

  @override
  bool get initialized => ready;

  @override
  List<SourceDescriptor> get channels => _channels;

  @override
  String get preferredQuality => quality;

  @override
  Future<void> setChannelEnabled(String key, bool enabled) async {
    channelCalls.add((key, enabled));
  }

  @override
  Future<void> setPreferredQuality(String quality) async {
    this.quality = quality;
    qualityCalls.add(quality);
  }
}

class _FakeDataSaver extends DataSaverService {
  bool _enabled = false;
  final List<bool> calls = [];

  @override
  bool get enabled => _enabled;

  @override
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    calls.add(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSources sources;
  late _FakeDataSaver dataSaver;
  late int finished;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sources = _FakeSources();
    dataSaver = _FakeDataSaver();
    finished = 0;
  });

  tearDown(() {
    sources.dispose();
    dataSaver.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    double textScale = 1.0,
    bool disableAnimations = false,
  }) async {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourcesProvider>.value(value: sources),
          ChangeNotifierProvider<DataSaverService>.value(value: dataSaver),
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
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: disableAnimations),
              child: OnboardingFlow(onFinished: () async => finished++),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('四屏可前进后退，跳过始终可见', (tester) async {
    await pump(tester);
    expect(find.text('音乐留在本机'), findsOneWidget);
    expect(find.textContaining('第三方音源脚本'), findsOneWidget);
    expect(find.byKey(const Key('onboardingSkip')), findsOneWidget);
    expect(find.byKey(const Key('onboardingBack')), findsNothing);

    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();
    expect(find.text('选择音源渠道'), findsOneWidget);
    expect(find.byKey(const Key('onboardingBack')), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();
    expect(find.text('音质与省流'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();
    expect(find.text('可选功能'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboardingBack')));
    await tester.pump();
    expect(find.text('音质与省流'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboardingSkip')));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('渠道未就绪时禁用，就绪后绑定现有 provider', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();

    expect(find.textContaining('正在准备渠道'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('onboardingChannel-kw')),
      findsNothing,
    );

    sources.ready = true;
    sources.notifyListeners();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('onboardingChannel-kw')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<M3ESwitch>(
            find.byKey(const ValueKey<String>('onboardingChannel-kw')),
          )
          .value,
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('onboardingChannel-kw')),
    );
    await tester.pump();
    expect(sources.channelCalls, [('kw', false)]);
  });

  testWidgets('音质与省流直接写现有服务，不镜像状态', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('onboardingNext')));
    await tester.pump();

    await tester.tap(find.text('192K'));
    await tester.pump();
    expect(sources.qualityCalls, ['192k']);

    await tester.tap(find.byKey(const Key('onboardingDataSaver')));
    await tester.pump();
    expect(dataSaver.calls, [true]);
    expect(find.textContaining('仅在移动数据下生效'), findsOneWidget);
  });

  testWidgets('没有登录 / 密钥输入框', (tester) async {
    await pump(tester);
    for (var i = 0; i < 3; i++) {
      expect(find.byType(EditableText), findsNothing);
      await tester.tap(find.byKey(const Key('onboardingNext')));
      await tester.pump();
    }
    expect(find.byType(EditableText), findsNothing);
    expect(find.textContaining('不需要登录'), findsOneWidget);
  });

  testWidgets('200% 字号 + 减弱动效下四屏不溢出', (tester) async {
    await pump(tester, textScale: 2.0, disableAnimations: true);
    for (var i = 0; i < 4; i++) {
      expect(tester.takeException(), isNull);
      if (i < 3) {
        await tester.tap(find.byKey(const Key('onboardingNext')));
        await tester.pump();
      }
    }
  });

  test('完成标记持久化且设备本地', () async {
    final store = OnboardingStore();
    expect(await store.isCompleted(), isFalse);
    await store.markCompleted();
    expect(await OnboardingStore().isCompleted(), isTrue);
  });
}
