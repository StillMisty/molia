import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/builtin/builtin_platforms.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_profiles.dart';

/// 音源画像矩阵：平台 × 能力 × 脚本 / any-listen / 停用，都从
/// [SourceProfiles.build] 的同一份输入推导；能力位必须与注册表 / 路由门
/// 一致，不允许出现「能力为真但路由必然失败」的条目。
void main() {
  const musicKeys = ['tx', 'wy', 'kg', 'kw', 'mg'];

  LxSourceDecl decl(
    String key,
    List<String> actions, {
    String? name,
  }) =>
      LxSourceDecl(
        key: key,
        name: name ?? key,
        actions: actions,
        qualitys: const ['320k'],
      );

  group('无脚本矩阵', () {
    final profiles = SourceProfiles.build();

    test('六平台能力位逐项等于注册表适配器（不再按「内置平台」一刀切）', () {
      expect(BuiltinPlatforms.keys, ['tx', 'wy', 'kg', 'kw', 'mg', 'bili']);

      for (final key in BuiltinPlatforms.keys) {
        final platform = BuiltinPlatforms.maybeOf(key)!;
        final profile = profiles.forKey(key)!;

        expect(profile.key, key, reason: key);
        expect(profile.displayName, platform.displayName, reason: key);
        expect(profile.kind, SourceKind.builtin, reason: key);
        expect(profile.enabled, isTrue, reason: key);
        expect(profile.discoverable, platform.discover != null, reason: key);

        // 搜索 = 搜索适配器存在 &&（原生取链 || 脚本可取链）；无脚本时只有
        // 原生取链的 bili 可搜索。
        expect(
          profile.capabilities.search,
          platform.resolve != null,
          reason: '$key: 搜索必须同时有搜索适配器与取链路径',
        );
        expect(profile.capabilities.pagination, profile.capabilities.search,
            reason: key);
        expect(profile.canResolveUrl, platform.resolve != null, reason: key);
        expect(profile.capabilities.lyrics, platform.lyric != null,
            reason: '$key: 歌词只认注册表里的原生取词适配器');
        expect(profile.capabilities.artwork, platform.pic != null,
            reason: '$key: 封面只认注册表里的原生取图适配器');
        expect(profile.capabilities.comment, platform.comments != null,
            reason: key);
        expect(profile.capabilities.collection, platform.album != null,
            reason: key);
        expect(
          profile.capabilities.artist,
          platform.artist != null && platform.resolve != null,
          reason: '$key: 歌手能力与搜索路由同门',
        );
        expect(
          profile.capabilities.lyricSearch,
          platform.lyricSearch != null && platform.resolve != null,
          reason: '$key: 按歌词搜歌与搜索路由同门',
        );
      }

      for (final key in musicKeys) {
        final profile = profiles.forKey(key)!;
        expect(profile.searchable, isFalse, reason: '$key 仍需要脚本取链');
        expect(profile.capabilities.lyrics, isTrue, reason: key);
        expect(profile.capabilities.artwork, isTrue, reason: key);
      }

      final bili = profiles.forKey('bili')!;
      expect(bili.searchable, isTrue);
      expect(bili.canResolveUrl, isTrue);
      expect(bili.capabilities.lyrics, isTrue, reason: 'CC 字幕歌词');
      expect(bili.capabilities.artwork, isTrue);
      expect(bili.capabilities.comment, isTrue);
      expect(bili.capabilities.artist, isTrue);
      expect(bili.capabilities.collection, isFalse, reason: 'B 站没有专辑');
      expect(bili.capabilities.lyricSearch, isFalse, reason: 'B 站没有按歌词搜歌');
    });

    test('渠道 / 可搜索列表：发现平台保留入口，any-listen 不可用时不出现', () {
      expect(
        profiles.channels.map((profile) => profile.key).toList(),
        ['bili', 'tx', 'wy', 'kg', 'kw', 'mg'],
        reason: '可搜索平台在前，仅发现的平台按规范顺序追加',
      );
      expect(
        profiles.searchable.map((profile) => profile.key).toList(),
        ['bili'],
      );

      final anyListen = profiles.forKey(AnyListenSource.sourceKey)!;
      expect(anyListen.kind, SourceKind.anyListen);
      expect(anyListen.capabilities, const domain.SourceCapabilities());
      expect(anyListen.visible, isFalse);
      expect(profiles.channels, isNot(contains(anyListen)));

      expect(profiles.forKey('not-imported'), isNull);
    });
  });

  test('toDescriptor：画像 → 渠道形状的唯一投影（kind / discoverable / enabled / order）',
      () {
    final projected = SourceProfiles.build(
      activeSources: {
        'custom': decl('custom', ['search', 'musicUrl'])
      },
      anyListenUsable: true,
      disabledChannels: const {'custom'},
    );

    final custom = projected.forKey('custom')!.toDescriptor(order: 2);
    expect(custom.key, 'custom');
    expect(custom.displayName, 'custom');
    expect(custom.kind, domain.SourceKind.lx);
    expect(custom.capabilities, projected.forKey('custom')!.capabilities);
    expect(custom.enabled, isFalse, reason: '停用是画像事实，投影原样带出');
    expect(custom.discoverable, isFalse);
    expect(custom.order, 2, reason: 'order 由消费方按列表下标传入');

    final bili = projected.forKey('bili')!.toDescriptor();
    expect(bili.kind, domain.SourceKind.builtin);
    expect(bili.discoverable, isTrue, reason: '内置发现平台仍保留发现入口');
    expect(bili.enabled, isTrue);

    final anyListen =
        projected.forKey(AnyListenSource.sourceKey)!.toDescriptor(order: 1);
    expect(anyListen.kind, domain.SourceKind.anyListen);
    expect(anyListen.order, 1);
  });

  group('脚本声明合并', () {
    final active = <String, LxSourceDecl>{
      // 内置 key 的脚本声明只补取链 / 取词 / 取图能力，不另建一个同名 LX 源。
      'wy': decl('wy', ['musicUrl', 'lyric', 'pic'], name: '脚本里的网易'),
      // 只有搜索 action、没有 musicUrl：searchWithMeta 会拒绝，能力位必须为 false。
      'kg': decl('kg', ['search'], name: '脚本里的酷狗'),
      'custom': decl('custom', ['search', 'musicUrl', 'lyric', 'pic']),
      'resolve-only': decl('resolve-only', ['musicUrl']),
      // 脚本误用 any-listen key 不应覆盖适配器身份。
      'any_listen': decl('any_listen', ['search', 'musicUrl']),
    };
    final profiles = SourceProfiles.build(activeSources: active);

    test('内置平台只留一份画像：身份取注册表，脚本只补能力', () {
      final wy = profiles.forKey('wy')!;
      expect(wy.kind, SourceKind.builtin);
      expect(wy.displayName, '网易音乐');
      expect(wy.searchable, isTrue, reason: '脚本 musicUrl 让搜索路由成立');
      expect(wy.capabilities.pagination, isTrue);
      expect(wy.canResolveUrl, isTrue);
      expect(wy.capabilities.lyrics, isTrue);
      expect(wy.capabilities.artwork, isTrue);
      expect(wy.capabilities.artist, isTrue);
      expect(wy.capabilities.lyricSearch, isTrue);

      final kg = profiles.forKey('kg')!;
      expect(kg.kind, SourceKind.builtin);
      expect(
        kg.searchable,
        isFalse,
        reason: '只有脚本 search、没有可取链：searchWithMeta 会拒绝，能力位不能为真',
      );
      expect(kg.canResolveUrl, isFalse);
      expect(kg.discoverable, isTrue, reason: '仍有发现入口');

      final anyListen = profiles.forKey(AnyListenSource.sourceKey)!;
      expect(anyListen.kind, SourceKind.anyListen,
          reason: '脚本声明同名 key 不改变 any-listen 身份');
      expect(anyListen.capabilities.search, isFalse,
          reason: 'any-listen 未配置时脚本声明不能代替它');
    });

    test('脚本扩展源按 action 声明能力；仅取链源不进渠道但可取链', () {
      final custom = profiles.forKey('custom')!;
      expect(custom.kind, SourceKind.lx);
      expect(custom.searchable, isTrue);
      expect(custom.canResolveUrl, isTrue);
      expect(custom.capabilities.lyrics, isTrue);
      expect(custom.capabilities.artwork, isTrue);
      expect(custom.capabilities.comment, isFalse);
      expect(custom.capabilities.collection, isFalse);
      expect(custom.capabilities.artist, isFalse);
      expect(custom.capabilities.lyricSearch, isFalse);

      final resolveOnly = profiles.forKey('resolve-only')!;
      expect(resolveOnly.searchable, isFalse);
      expect(resolveOnly.canResolveUrl, isTrue);
      expect(resolveOnly.visible, isFalse);
      expect(
        profiles.channels.map((profile) => profile.key),
        isNot(contains('resolve-only')),
        reason: '不能搜索也没有发现页：渠道列表不出现，但旧曲目仍可内部取链',
      );
    });

    test('渠道顺序：脚本可搜索源 → 内置可搜索平台 → 仅发现平台', () {
      expect(
        profiles.channels.map((profile) => profile.key).toList(),
        ['custom', 'wy', 'bili', 'tx', 'kg', 'kw', 'mg'],
      );
      expect(
        profiles.searchable.map((profile) => profile.key).toList(),
        ['custom', 'wy', 'bili'],
      );
    });
  });

  group('偏好：停用与排序', () {
    final active = <String, LxSourceDecl>{
      'wy': decl('wy', ['musicUrl']),
      'custom': decl('custom', ['search', 'musicUrl']),
    };
    final profiles = SourceProfiles.build(
      activeSources: active,
      disabledChannels: const {'custom', 'tx'},
      sourceOrder: const ['tx', 'bili'],
    );

    test('停用项仍在渠道列表（可重新启用），但不进可搜索列表', () {
      expect(
        profiles.channels.map((profile) => profile.key).toList(),
        ['tx', 'bili', 'custom', 'wy', 'kg', 'kw', 'mg'],
        reason: '顺序表优先，未列出的保持候选相对顺序',
      );
      expect(profiles.forKey('custom')!.enabled, isFalse);
      expect(profiles.forKey('tx')!.enabled, isFalse);
      expect(
        profiles.searchable.map((profile) => profile.key).toList(),
        ['bili', 'wy'],
        reason: 'custom 被停用、tx 无搜索能力',
      );
    });
  });

  group('any-listen', () {
    test('可用时全能力、排在可搜索内置平台之后；停用只影响搜索列表', () {
      final usable = SourceProfiles.build(anyListenUsable: true);
      final anyListen = usable.forKey(AnyListenSource.sourceKey)!;
      expect(anyListen.displayName, AnyListenSource.displayName);
      expect(anyListen.enabled, isTrue);
      expect(anyListen.searchable, isTrue);
      expect(anyListen.canResolveUrl, isTrue);
      expect(anyListen.capabilities.pagination, isTrue);
      expect(anyListen.capabilities.lyrics, isTrue);
      expect(anyListen.capabilities.artwork, isTrue);
      expect(anyListen.capabilities.comment, isFalse);
      expect(anyListen.capabilities.collection, isFalse);
      expect(
        usable.channels.map((profile) => profile.key).toList(),
        ['bili', AnyListenSource.sourceKey, 'tx', 'wy', 'kg', 'kw', 'mg'],
      );
      expect(
        usable.searchable.map((profile) => profile.key).toList(),
        ['bili', AnyListenSource.sourceKey],
      );

      final disabled = SourceProfiles.build(
        anyListenUsable: true,
        disabledChannels: const {AnyListenSource.sourceKey},
      );
      expect(
        disabled.channels.map((profile) => profile.key),
        contains(AnyListenSource.sourceKey),
      );
      expect(disabled.forKey(AnyListenSource.sourceKey)!.enabled, isFalse);
      expect(
        disabled.searchable.map((profile) => profile.key).toList(),
        ['bili'],
      );
    });
  });

  test('能力为真 ⇒ 路由实现存在（每个内置平台 × 有/无脚本）', () {
    final scenarios = <String, Map<String, LxSourceDecl>>{
      '无脚本': const {},
      '混用脚本': {
        'wy': decl('wy', ['musicUrl']),
        'kg': decl('kg', ['search']),
        'custom': decl('custom', ['search', 'musicUrl', 'lyric', 'pic']),
      },
    };

    for (final entry in scenarios.entries) {
      final profiles = SourceProfiles.build(activeSources: entry.value);
      for (final key in BuiltinPlatforms.keys) {
        final platform = BuiltinPlatforms.maybeOf(key)!;
        final script = entry.value[key];
        final scriptResolve = script?.canResolveUrl ?? false;
        final profile = profiles.forKey(key)!;
        final reason = '${entry.key} / $key';

        if (profile.searchable) {
          expect(platform.search, isNotNull, reason: '$reason: 可搜索必须有搜索适配器');
          expect(platform.resolve != null || scriptResolve, isTrue,
              reason: '$reason: 可搜索必须有原生或脚本取链');
        }
        if (profile.canResolveUrl) {
          expect(platform.resolve != null || scriptResolve, isTrue,
              reason: '$reason: 可取链必须有原生或脚本实现');
        }
        if (profile.capabilities.lyrics) {
          expect(platform.lyric != null || (script?.canFetchLyric ?? false),
              isTrue,
              reason: '$reason: 歌词能力必须有原生适配器或脚本 lyric');
        }
        if (profile.capabilities.artwork) {
          expect(platform.pic != null || (script?.canFetchPic ?? false), isTrue,
              reason: '$reason: 封面能力必须有原生适配器或脚本 pic');
        }
        if (profile.capabilities.comment) {
          expect(platform.comments, isNotNull, reason: '$reason: 评论');
        }
        if (profile.capabilities.collection) {
          expect(platform.album, isNotNull, reason: '$reason: 专辑');
        }
        if (profile.capabilities.artist) {
          expect(platform.artist, isNotNull, reason: '$reason: 歌手适配器');
          expect(profile.searchable, isTrue, reason: '$reason: 歌手依赖搜索路由');
        }
        if (profile.capabilities.lyricSearch) {
          expect(platform.lyricSearch, isNotNull, reason: '$reason: 歌词搜索适配器');
          expect(profile.searchable, isTrue, reason: '$reason: 歌词搜索依赖搜索路由');
        }
      }
    }
  });
}
