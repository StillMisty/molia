import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/track_artwork.dart';

Uint8List _png(int shade) {
  final source = image.Image(width: 2, height: 2);
  image.fill(source, color: image.ColorRgb8(shade, shade, shade));
  return Uint8List.fromList(image.encodePng(source));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final track = Track(
    id: const TrackId('kw', 'a'),
    title: 'Title',
    origin: TrackOrigin.builtin,
    artwork: Artwork(uri: Uri.parse('https://img.example/original.jpg')),
  );

  late Directory tempDir;
  late CustomCoverStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('molia_track_artwork_');
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    CustomCoverStore.overrideInstance(store);
    await store.load();
  });

  tearDown(() async {
    CustomCoverStore.overrideInstance(null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget host(Track track) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackArtwork(track: track, size: 44),
          ),
        ),
      );

  AppNetworkImage imageOf(WidgetTester tester) =>
      tester.widget<AppNetworkImage>(find.byType(AppNetworkImage));

  testWidgets('自定义封面 revision 后自动换图；恢复后回到原始封面', (tester) async {
    await tester.pumpWidget(host(track));
    expect(imageOf(tester).url, 'https://img.example/original.jpg');
    expect(imageOf(tester).fallbackUrl, isNull);

    await tester.runAsync(() => store.setTrackCover(track.id, _png(10)));
    await tester.pump();

    final customUrl = store.trackCoverUrl(track.id);
    expect(customUrl, isNotNull);
    expect(imageOf(tester).url, customUrl);

    await tester.runAsync(() => store.resetTrackCover(track.id));
    await tester.pump();
    expect(imageOf(tester).url, 'https://img.example/original.jpg');
  });

  testWidgets('默认封面只作为回退：无真实封面时主图为空、回退默认图', (tester) async {
    await tester.runAsync(() => store.setDefaultCover(_png(20)));
    await tester.pumpWidget(host(const Track(
      id: TrackId('kw', 'none'),
      title: 'No artwork',
      origin: TrackOrigin.builtin,
    )));

    final image = imageOf(tester);
    expect(image.url, isNull, reason: '默认封面不是真实主图');
    expect(image.fallbackUrl, store.defaultCoverUrl);
  });

  testWidgets('默认封面 revision 后回退图立即刷新', (tester) async {
    await tester.pumpWidget(host(const Track(
      id: TrackId('kw', 'none'),
      title: 'No artwork',
      origin: TrackOrigin.builtin,
    )));
    expect(imageOf(tester).fallbackUrl, isNull);

    await tester.runAsync(() => store.setDefaultCover(_png(30)));
    await tester.pump();
    expect(imageOf(tester).fallbackUrl, store.defaultCoverUrl);

    await tester.runAsync(store.resetDefaultCover);
    await tester.pump();
    expect(imageOf(tester).fallbackUrl, isNull);
  });
}
