import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/provider_tree.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_discover_api.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// Provider 树首帧渠道同步：`DiscoverProvider` 的 create 发生在 build 期，
/// 不能同步调用会 notifyListeners 的 `SearchProvider.setActiveSource`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('eager DiscoverProvider 首帧同步不触发 build 期标脏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = FakeLibraryRepository();
    final playback = buildTestPlaybackProvider(
      backend: FakePlaybackBackend(),
      libraryRepository: repository,
    );
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    final search = SearchProvider(playback);
    addTearDown(() async {
      search.dispose();
      library.dispose();
      playback.dispose();
      await repository.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SearchProvider>.value(value: search),
          ChangeNotifierProvider<DiscoverProvider>(
            lazy: false,
            create: (_) {
              final discover = DiscoverProvider(
                playbackProvider: playback,
                libraryProvider: library,
                sources: {'wy': FakeDiscoverSource()},
                initialChannelKey: 'wy',
              );
              // 与生产组合根同一条延后同步路径。
              scheduleInitialChannelSync(discover, search);
              return discover;
            },
          ),
        ],
        child: const SizedBox.shrink(),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(search.activeSourceKey, 'wy', reason: '首帧后仍要完成渠道同步');
  });
}
