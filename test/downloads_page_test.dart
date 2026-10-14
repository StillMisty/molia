import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/downloads_page.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_download_storage.dart';
import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 可编排的下载服务假件：列表 / 支持位 / 删除动作。
class _FakeDownloadService extends DownloadService {
  _FakeDownloadService()
      : super(
          catalog: CatalogService(registry: FakeSourceRegistry(const {})),
          repository: DownloadsRepository(
            databaseProvider: () => throw UnimplementedError(),
          ),
          storage: FakeDownloadStorage(),
        );

  final List<DownloadedTrack> _records = [];
  bool downloadSupported = true;
  int deleteCalls = 0;

  void seed(List<DownloadedTrack> records) {
    _records
      ..clear()
      ..addAll(records);
    notifyListeners();
  }

  @override
  bool get supported => downloadSupported;

  @override
  List<DownloadedTrack> get downloads => List.of(_records);

  @override
  Future<void> delete(DownloadedTrack record) async {
    deleteCalls++;
    _records.removeWhere((item) => item.key == record.key);
    notifyListeners();
  }
}

DownloadedTrack _record(String songId, {String title = '歌曲', int size = 1024}) =>
    DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: songId,
      title: title,
      artist: '歌手',
      durationMs: 200000,
      filePath: '/downloads/$title.mp3',
      sizeBytes: size,
      downloadedAt: 1,
      raw: {'songId': songId},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late FakeLibraryRepository libraryRepository;
  late LibraryProvider library;
  late _FakeDownloadService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    libraryRepository = FakeLibraryRepository();
    library = LibraryProvider(
      repository: libraryRepository,
      playbackProvider: playback,
    );
    service = _FakeDownloadService();
  });

  tearDown(() {
    library.dispose();
    playback.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadService>.value(value: service),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const DownloadsPage(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('空列表：空态提示', (tester) async {
    await pumpPage(tester);

    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('还没有下载的歌曲'), findsOneWidget);
  });

  testWidgets('列表：汇总行 + 曲目行渲染', (tester) async {
    service.seed([
      _record('1', title: '歌曲一', size: 1024 * 1024),
      _record('2', title: '歌曲二', size: 2 * 1024 * 1024),
    ]);
    await pumpPage(tester);

    expect(find.text('2 首 · 3.0 MB'), findsOneWidget);
    expect(find.text('歌曲一'), findsOneWidget);
    expect(find.text('歌曲二'), findsOneWidget);
    expect(find.text('3:20'), findsNWidgets(2));
  });

  testWidgets('点行播放：队列为本地曲目（local 音源 + 路径 payload）', (tester) async {
    service.seed([
      _record('1', title: '歌曲一'),
      _record('2', title: '歌曲二'),
    ]);
    await pumpPage(tester);

    await tester.tap(find.text('歌曲二'));
    await tester.pump();

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks.map((track) => track.id.uri),
        ['local:kw:1', 'local:kw:2']);
    expect(request.tracks.first.payload['path'], '/downloads/歌曲一.mp3');
    expect(request.tracks.first.origin.name, 'localFile');
    expect(request.startIndex, 1);
    expect(request.context?.name, '已下载');
  });

  testWidgets('左滑删除：确认后删除并移出列表', (tester) async {
    service.seed([_record('1', title: '歌曲一')]);
    await pumpPage(tester);

    await tester.drag(find.text('歌曲一'), const Offset(-260, 0));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();

    expect(find.text('删除下载'), findsWidgets);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(service.deleteCalls, 1);
    expect(find.text('歌曲一'), findsNothing);
    expect(find.text('还没有下载的歌曲'), findsOneWidget);
  });

  testWidgets('存储不可用：显示不支持提示', (tester) async {
    service.downloadSupported = false;
    service.seed([_record('1')]);
    await pumpPage(tester);

    expect(find.text('当前平台不支持下载'), findsOneWidget);
    expect(find.text('歌曲'), findsNothing);
  });
}
