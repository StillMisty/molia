import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/covers/cover_image_fetcher.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/cover_viewer.dart';
import 'package:provider/provider.dart';

import '../support/fake_save_as.dart';
import '../support/notification_recorder.dart';

class _FakeCoverSource implements CoverOriginalSource {
  Uint8List? bytes = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]);
  int calls = 0;

  @override
  Future<Uint8List?> read(String url, {bool allowNetwork = true}) async {
    calls++;
    return bytes;
  }
}

/// 封面原图查看器：contain 展示、保存原图、更换封面意图。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  // 本地路径不真实存在：只验证查看器布局与交互，图片走错误回退，避免
  // testWidgets 的 fake async 里等真实文件 I/O。
  const localCover = 'file:///tmp/molia-cover-viewer-test.jpg';

  Future<void> pumpViewer(
    WidgetTester tester, {
    required String url,
    bool allowEdit = false,
    CoverOriginalSource? source,
    FakeSaveAs? saveAs,
    RecordingNotificationService? notifications,
    void Function(CoverViewerAction?)? onResult,
  }) async {
    final effectiveNotifications =
        notifications ?? RecordingNotificationService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          if (saveAs != null) Provider<SaveAs>.value(value: saveAs),
          Provider<NotificationService>.value(value: effectiveNotifications),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => M3EButton.filled(
                  onPressed: () async {
                    final action = await showCoverViewer(
                      context,
                      coverUrl: url,
                      title: l10n.coverLabel,
                      fileNameBase: 'Song',
                      allowEdit: allowEdit,
                      source: source,
                    );
                    onResult?.call(action);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('原图查看：contain 展示，只读入口没有更换按钮', (tester) async {
    await pumpViewer(tester, url: localCover);

    expect(find.byKey(const Key('coverViewerPage')), findsOneWidget);
    final image = tester.widget<AppNetworkImage>(
      find.byKey(const Key('coverViewerImage')),
    );
    expect(image.fit, BoxFit.contain);
    expect(image.memCacheHeight, isNull, reason: '双轴会拉伸；查看器只给宽度');
    expect(find.byKey(const Key('coverViewerSaveButton')), findsOneWidget);
    expect(find.byKey(const Key('coverViewerEditButton')), findsNothing);
  });

  testWidgets('保存原图：写入 covers/，文件名 / MIME / 字节来自原图', (tester) async {
    final source = _FakeCoverSource();
    final saveAs = FakeSaveAs();
    final notifications = RecordingNotificationService();

    await pumpViewer(
      tester,
      url: 'https://example.com/cover.jpg',
      source: source,
      saveAs: saveAs,
      notifications: notifications,
    );
    await tester.tap(find.byKey(const Key('coverViewerSaveButton')));
    await tester.pumpAndSettle();

    expect(source.calls, 1);
    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsCoversDirName);
    expect(call.fileName, 'Song.jpg');
    expect(call.mimeType, 'image/jpeg');
    expect(call.bytes, source.bytes);
    expect(notifications.last, contains('已保存到'));
  });

  testWidgets('原图读取失败：提示封面加载失败', (tester) async {
    final source = _FakeCoverSource()..bytes = null;
    final notifications = RecordingNotificationService();

    await pumpViewer(
      tester,
      url: 'https://example.com/cover.jpg',
      source: source,
      saveAs: FakeSaveAs(),
      notifications: notifications,
    );
    await tester.tap(find.byKey(const Key('coverViewerSaveButton')));
    await tester.pumpAndSettle();

    expect(notifications.last, l10n.coverLoadFailed);
  });

  testWidgets('歌曲信息入口：更换封面返回 editCover 并关闭查看器', (tester) async {
    CoverViewerAction? result;

    await pumpViewer(
      tester,
      url: localCover,
      allowEdit: true,
      onResult: (value) => result = value,
    );
    expect(find.byKey(const Key('coverViewerEditButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('coverViewerEditButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsNothing);
    expect(result, CoverViewerAction.editCover);
  });
}
