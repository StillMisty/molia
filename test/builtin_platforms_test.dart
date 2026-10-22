import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/album_source.dart';
import 'package:molia/sources/builtin/artist_source.dart';
import 'package:molia/sources/builtin/builtin_platforms.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/comment_source.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/builtin/lyric_search.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/settings_test_support.dart';

/// 内置平台能力矩阵：平台只允许在 [BuiltinPlatforms] 声明一次，
/// 各 facade / SourceManager 的能力位必须从同一份注册表推导。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const expectedKeys = ['tx', 'wy', 'kg', 'kw', 'mg'];

  test('平台键只在注册表声明一次：规范顺序 / 显示名 / isSupported', () {
    expect(BuiltinPlatforms.keys, expectedKeys);
    expect(
      BuiltinPlatforms.searchCandidates.map((platform) => platform.key),
      expectedKeys,
      reason: '音源页/搜索解析与发现页共用同一顺序',
    );
    expect(BuiltinPlatforms.keySet, expectedKeys.toSet());
    for (final key in expectedKeys) {
      final platform = BuiltinPlatforms.maybeOf(key);
      expect(platform, isNotNull, reason: key);
      expect(platform!.key, key, reason: key);
      expect(platform.displayName, isNotEmpty, reason: key);
      expect(BuiltinPlatforms.isSupported(key), isTrue, reason: key);
      expect(BuiltinSearch.isBuiltin(key), isTrue, reason: key);
      expect(BuiltinSearch.displayName(key), platform.displayName, reason: key);
    }
    expect(BuiltinPlatforms.isSupported('lx_custom'), isFalse);
    expect(BuiltinPlatforms.isSupported('any_listen'), isFalse);

    // 既有 facade 的别名必须指向同一份注册表，而不是各自复制键表。
    expect(BuiltinSearch.platforms.keys, expectedKeys);
    expect(BuiltinDiscover.sourceKeys, expectedKeys);
    expect(BuiltinDiscover.sources.keys, expectedKeys);
  });

  test('六族支持矩阵与注册表一致（每族都有自己的类型化适配器）', () {
    expect(BuiltinPlatforms.searchKeys, expectedKeys.toSet());
    expect(BuiltinPlatforms.lyricSearchKeys, expectedKeys.toSet());
    expect(BuiltinPlatforms.commentKeys, expectedKeys.toSet());
    expect(BuiltinPlatforms.albumKeys, expectedKeys.toSet());
    expect(BuiltinPlatforms.artistKeys, expectedKeys.toSet());
    expect(BuiltinPlatforms.discoverKeys, expectedKeys.toSet());

    for (final key in expectedKeys) {
      expect(BuiltinPlatforms.searchFor(key), isNotNull, reason: key);
      expect(BuiltinPlatforms.lyricSearchFor(key), isNotNull, reason: key);
      expect(BuiltinPlatforms.commentsFor(key), isNotNull, reason: key);
      expect(BuiltinPlatforms.albumFor(key), isNotNull, reason: key);
      expect(BuiltinPlatforms.artistFor(key), isNotNull, reason: key);
      expect(BuiltinPlatforms.discoverFor(key), isNotNull, reason: key);

      // facade 的能力位不能自己再写一份平台表。
      expect(BuiltinAlbums.isSupported(key),
          BuiltinPlatforms.albumKeys.contains(key),
          reason: key);
      expect(BuiltinArtists.isSupported(key),
          BuiltinPlatforms.artistKeys.contains(key),
          reason: key);
      expect(BuiltinComments.isSupported(key),
          BuiltinPlatforms.commentKeys.contains(key),
          reason: key);
      expect(BuiltinLyricSearch.isSupported(key),
          BuiltinPlatforms.lyricSearchKeys.contains(key),
          reason: key);
      expect(BuiltinDiscover.isSupported(key),
          BuiltinPlatforms.discoverKeys.contains(key),
          reason: key);
    }
  });

  test('SourceManager.capabilitiesFor 与注册表 + 可取链门一致（无脚本）', () {
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);

    for (final key in expectedKeys) {
      final platform = BuiltinPlatforms.maybeOf(key)!;
      final capabilities = manager.capabilitiesFor(key);

      // 内置取词 / 封面是 Dart 原生实现，不依赖脚本声明。
      expect(capabilities.lyrics, isTrue, reason: key);
      expect(capabilities.artwork, isTrue, reason: key);
      expect(capabilities.comment, platform.comments != null, reason: key);
      expect(capabilities.collection, platform.album != null, reason: key);

      // 无激活脚本 → 没有可取链源，搜索 / 歌手 / 歌词搜索的路由门关闭。
      expect(capabilities.search, isFalse, reason: key);
      expect(capabilities.pagination, isFalse, reason: key);
      expect(capabilities.resolveUrl, isFalse, reason: key);
      expect(capabilities.artist, isFalse, reason: key);
      expect(capabilities.lyricSearch, isFalse, reason: key);
    }

    // 非内置平台不应从注册表获得任何内置能力。
    final unknown = manager.capabilitiesFor('lx_custom');
    expect(unknown.search, isFalse);
    expect(unknown.comment, isFalse);
    expect(unknown.collection, isFalse);
    expect(unknown.lyrics, isFalse);
    expect(unknown.artwork, isFalse);
  });
}
