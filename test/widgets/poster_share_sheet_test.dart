import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:molia/widgets/poster_share_sheet.dart';
import 'package:provider/provider.dart';

import '../support/fake_save_as.dart';
import '../support/notification_recorder.dart';

/// 1×1 透明 PNG：只用于让 `Image.memory` 有合法字节。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Widget _host(
  Widget child, {
  SaveAs? saveAs,
  NotificationService? notifications,
}) {
  return M3EMaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: const [Locale('zh')],
    data: M3EThemeData.fromMaterial(ThemeData.light()),
    theme: ThemeData.light(),
    home: MultiProvider(
      providers: [
        Provider<SaveAs?>.value(value: saveAs),
        Provider<NotificationService?>.value(value: notifications),
      ],
      child: Scaffold(body: child),
    ),
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

PosterShareSheet _sheet({
  Future<Uint8List?> Function()? renderPoster,
  String? copyText,
  PosterFileShare? shareFile,
}) {
  return PosterShareSheet(
    renderPoster: renderPoster ?? () async => _png,
    shareText: 'Trip',
    fileName: 'trip.png',
    saveDialogTitle: '保存图片',
    emptyMessage: '这个列表还没有曲目',
    copyText: copyText,
    shareFile: shareFile,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('统一分享弹层：预览 + 一个主操作 + 次要保存 / 复制', (tester) async {
    await tester.pumpWidget(_host(_sheet(copyText: 'A\nB')));
    await _waitFor(
      tester,
      () => find.byKey(const Key('posterSharePreview')).evaluate().isNotEmpty,
    );

    expect(find.byKey(const Key('posterSharePreview')), findsOneWidget);
    expect(find.byKey(const Key('posterShareAction')), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('复制文本'), findsOneWidget);
    expect(find.text('导出数据'), findsNothing);
  });

  testWidgets('没有复制文本时只保留保存图片', (tester) async {
    await tester.pumpWidget(_host(_sheet()));
    await _waitFor(
      tester,
      () => find.byKey(const Key('posterSharePreview')).evaluate().isNotEmpty,
    );

    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('复制文本'), findsNothing);
  });

  testWidgets('空内容：显示空态且不出现分享按钮', (tester) async {
    await tester.pumpWidget(_host(_sheet(renderPoster: () async => null)));
    await _waitFor(tester, () => find.text('这个列表还没有曲目').evaluate().isNotEmpty);

    expect(find.text('这个列表还没有曲目'), findsOneWidget);
    expect(find.byKey(const Key('posterShareAction')), findsNothing);
  });

  testWidgets('分享：写入临时文件，分享完删除', (tester) async {
    final paths = <String>[];
    final texts = <String>[];
    final sizes = <int>[];
    await tester.pumpWidget(
      _host(
        _sheet(
          shareFile: (path, text) async {
            paths.add(path);
            texts.add(text);
            sizes.add(File(path).lengthSync());
          },
        ),
      ),
    );
    await _waitFor(
      tester,
      () => find.byKey(const Key('posterShareAction')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('posterShareAction')));
    await _waitFor(
      tester,
      () => paths.isNotEmpty && !File(paths.single).existsSync(),
    );

    expect(paths, hasLength(1));
    expect(paths.single, contains('molia_poster_'));
    expect(texts.single, 'Trip');
    expect(sizes.single, greaterThan(0));
    expect(File(paths.single).existsSync(), isFalse, reason: '临时文件用完即删');
  });

  testWidgets('保存图片：写入海报目录并提示位置', (tester) async {
    final saveAs = FakeSaveAs();
    final notifications = RecordingNotificationService();
    await tester.pumpWidget(
      _host(_sheet(), saveAs: saveAs, notifications: notifications),
    );
    await _waitFor(
      tester,
      () =>
          find.byKey(const Key('posterSaveImageAction')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('posterSaveImageAction')));
    await _waitFor(tester, () => saveAs.saves.isNotEmpty);

    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsPostersDirName);
    expect(call.mimeType, 'image/png');
    expect(call.fileName, 'trip.png');
    expect(call.bytes, isNotEmpty);
    expect(notifications.last, contains('posters/'));
  });

  testWidgets('复制文本：写入剪贴板并提示', (tester) async {
    final notifications = RecordingNotificationService();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _host(_sheet(copyText: 'A\nB'), notifications: notifications),
    );
    await _waitFor(
      tester,
      () => find.byKey(const Key('posterCopyTextAction')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('posterCopyTextAction')));
    await tester.pumpAndSettle();

    expect(copied, 'A\nB');
    expect(notifications.last, '文本已复制');
  });
}
