import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/favorite_action.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 收藏动作 / 反馈的唯一实现：两种反馈强度 + 心形契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  const track = Track(
    id: TrackId('kw', 'fav-action'),
    title: 'Favorite action',
    artists: [Artist(name: 'A')],
    album: 'Album',
    duration: Duration(seconds: 30),
    origin: TrackOrigin.builtin,
    payload: {'songmid': 'fav-action'},
  );

  Future<FavoriteToggleOutcome?>? last;

  Future<void> pumpHost(
    WidgetTester tester, {
    required Future<FavoriteToggleOutcome?> Function(BuildContext context)
        action,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
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
              builder: (context) => TextButton(
                onPressed: () => last = action(context),
                child: const Text('toggle'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAndSettle(WidgetTester tester) async {
    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    expect(last, isNotNull);
  }

  testWidgets('confirmation：成功也提示收藏文案', (tester) async {
    await pumpHost(
      tester,
      action: (context) => toggleLibraryFavorite(context, track),
    );
    await tapAndSettle(tester);

    expect(find.text('收藏'), findsOneWidget);
    expect(library.isFavorite(track.id.sourceKey, track.id.id), isTrue);

    await tapAndSettle(tester);
    expect(find.text('取消收藏'), findsOneWidget);
    expect(library.isFavorite(track.id.sourceKey, track.id.id), isFalse);
  });

  testWidgets('confirmation：写失败提示操作失败且不翻转', (tester) async {
    repository.failFavoriteWrites = true;
    await pumpHost(
      tester,
      action: (context) => toggleLibraryFavorite(context, track),
    );
    await tapAndSettle(tester);

    expect(find.text('操作失败'), findsOneWidget);
    expect(find.text('收藏'), findsNothing);
    expect(library.isFavorite(track.id.sourceKey, track.id.id), isFalse);
  });

  testWidgets('failureOnly：成功不弹提示，失败提示操作失败', (tester) async {
    await pumpHost(
      tester,
      action: (context) => toggleLibraryFavorite(
        context,
        track,
        feedback: FavoriteFeedback.failureOnly,
      ),
    );
    await tapAndSettle(tester);

    expect(find.text('收藏'), findsNothing);
    expect(find.text('取消收藏'), findsNothing);
    expect(find.text('操作失败'), findsNothing);
    expect(library.isFavorite(track.id.sourceKey, track.id.id), isTrue);

    repository.failFavoriteWrites = true;
    await tapAndSettle(tester);
    expect(find.text('操作失败'), findsOneWidget);
  });

  test('心形契约：图标 / 文案 / 颜色同源', () {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    const scheme = ColorScheme.light();

    const on = FavoriteHeart(favorite: true);
    expect(on.icon, Icons.favorite_rounded);
    expect(on.label(l10n), '取消收藏');
    expect(on.color(scheme), scheme.primary);

    const off = FavoriteHeart(favorite: false);
    expect(off.icon, Icons.favorite_border_rounded);
    expect(off.label(l10n), '收藏');
    expect(off.color(scheme), scheme.onSurfaceVariant);
  });
}
