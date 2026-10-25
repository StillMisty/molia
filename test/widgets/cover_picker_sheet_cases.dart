import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/cover_picker_sheet.dart';

import '../support/notification_recorder.dart';

/// 只覆盖弹层用到的查询 / 重置接口：不触碰文件与 prefs，避免 widget test
/// 的 fake async 等待真实 I/O。
class _FakeCoverStore extends CustomCoverStore {
  _FakeCoverStore({this.trackUrl, this.defaultUrl});

  String? trackUrl;
  String? defaultUrl;

  @override
  String? trackCoverUrl(TrackId id) => trackUrl;

  @override
  String? get defaultCoverUrl => defaultUrl;

  @override
  String? customCoverUrlForKey(String key) => trackUrl;

  @override
  Future<void> resetTrackCover(TrackId id) async {
    trackUrl = null;
  }

  @override
  Future<void> resetDefaultCover() async {
    defaultUrl = null;
  }
}

/// 共享封面弹层：标题由 showSimpleModal 提供，重置使用「已恢复」文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  Future<void> pumpHost(
    WidgetTester tester, {
    required CustomCoverStore store,
    required RecordingNotificationService notifications,
    required Future<void> Function(BuildContext context) open,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<CustomCoverStore>.value(value: store),
          Provider<NotificationService>.value(value: notifications),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: M3EButton.filled(
                  onPressed: () => open(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('单曲封面：窄屏弹层标题来自弹层 chrome，重置提示「封面已恢复」', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const trackId = TrackId('kw', 'picker');
    final store = _FakeCoverStore(trackUrl: 'file:///tmp/picker.jpg');
    final notifications = RecordingNotificationService();

    await pumpHost(
      tester,
      store: store,
      notifications: notifications,
      open: (context) => showCoverPickerSheet(context, trackId: trackId),
    );

    expect(find.text(l10n.coverTitle), findsOneWidget, reason: '标题只在弹层 chrome');
    expect(find.text(l10n.coverCustomized), findsOneWidget);
    await tester.tap(find.byKey(const Key('coverPickerResetButton')));
    await tester.pumpAndSettle();

    expect(notifications.last, l10n.coverRestored);
    expect(store.trackUrl, isNull);
  });

  testWidgets('单曲无原始封面：副标题说明回落到默认封面，无重置入口', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = _FakeCoverStore();
    final notifications = RecordingNotificationService();

    await pumpHost(
      tester,
      store: store,
      notifications: notifications,
      open: (context) =>
          showCoverPickerSheet(context, trackId: const TrackId('kw', 'plain')),
    );

    expect(find.text(l10n.coverDefaultTitle), findsOneWidget);
    expect(find.byKey(const Key('coverPickerResetButton')), findsNothing);
  });

  testWidgets('有原始封面：显示「查看原图」并打开原图查看器', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = _FakeCoverStore();
    final notifications = RecordingNotificationService();

    await pumpHost(
      tester,
      store: store,
      notifications: notifications,
      open: (context) => showCoverPickerSheet(
        context,
        trackId: const TrackId('kw', 'picker'),
        originalCoverUrl: 'file:///tmp/picker-cover.jpg',
      ),
    );

    expect(find.byKey(const Key('coverPickerViewButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('coverPickerViewButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsOneWidget);
  });

  testWidgets('默认封面：宽屏弹层标题使用默认封面文案', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = _FakeCoverStore(defaultUrl: 'file:///tmp/default.jpg');
    final notifications = RecordingNotificationService();

    await pumpHost(
      tester,
      store: store,
      notifications: notifications,
      open: (context) => showCoverPickerSheet(context),
    );

    expect(find.text(l10n.coverDefaultTitle), findsOneWidget);
    expect(find.text(l10n.coverDefaultSubtitle), findsOneWidget);
    await tester.tap(find.byKey(const Key('coverPickerResetButton')));
    await tester.pumpAndSettle();

    expect(notifications.last, l10n.coverDefaultRestored);
    expect(store.defaultUrl, isNull);
  });
}
