import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/builtin/channel/channels.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_profiles.dart';
import 'package:molia/sources/source_routing.dart';

/// 能力路由矩阵：每个 key × 能力都必须由 [SourceRouting] 给出与画像
/// 能力位一致的答案；管理器只按路线类型执行，不再自己按 key 分支。
void main() {
  LxSourceDecl decl(String key, List<String> actions, {String? name}) =>
      LxSourceDecl(
        key: key,
        name: name ?? key,
        actions: actions,
        qualitys: const ['320k'],
      );

  SourceRouting routingOf(SourceProfiles profiles) =>
      SourceRouting(profiles: profiles);

  /// 每条路线的类型名，便于断言选择结果。
  List<String> kindsOf(List<SourceRoute> routes) => [
    for (final route in routes)
      switch (route) {
        BuiltinSourceRoute() => 'builtin',
        ScriptSourceRoute() => 'script',
        AnyListenSourceRoute() => 'anyListen',
        UnavailableSourceRoute() => 'unavailable',
      },
  ];

  group('内置渠道（无脚本）', () {
    final profiles = SourceProfiles.build();
    final routing = routingOf(profiles);

    test('搜索 / 取链：只有原生取链的 bili 可用，其余按搜索门不可用', () {
      for (final key in SongChannels.keys) {
        final channel = SongChannels.forKey(key)!;
        final expected = channel.resolve != null && channel.search != null;
        expect(
          routing.supports(key, SourceCapability.search),
          expected,
          reason: '$key: 搜索与画像 searchable 同门',
        );
        expect(
          routing.supports(key, SourceCapability.resolve),
          channel.resolve != null,
          reason: key,
        );
      }
      expect(
        routing.routesFor('kw', SourceCapability.search).single,
        isA<UnavailableSourceRoute>().having(
          (route) => route.reason,
          'reason',
          SourceUnavailableReason.searchGateClosed,
        ),
      );
    });

    test('歌词 / 封面：全部走渠道原生实现，和画像能力位一致', () {
      for (final key in SongChannels.keys) {
        final channel = SongChannels.forKey(key)!;
        expect(
          routing.supports(key, SourceCapability.lyric),
          channel.lyric != null,
          reason: '$key 歌词',
        );
        expect(
          routing.supports(key, SourceCapability.picture),
          channel.pic != null,
          reason: '$key 封面',
        );
      }
    });

    test('评论 / 专辑 / 歌手 / 歌词搜索：路线存在 ⇔ 渠道声明适配器', () {
      for (final key in SongChannels.keys) {
        final channel = SongChannels.forKey(key)!;
        final profile = profiles.forKey(key)!;
        expect(
          routing.supports(key, SourceCapability.comments),
          channel.comments != null,
          reason: key,
        );
        expect(
          routing.supports(key, SourceCapability.album),
          channel.album != null,
          reason: key,
        );
        // 歌手详情只看适配器；画像能力位额外叠了搜索门（UI 入口）。
        expect(
          routing.supports(key, SourceCapability.artist),
          channel.artist != null,
          reason: key,
        );
        expect(
          profile.capabilities.artist,
          channel.artist != null && profile.searchable,
          reason: '$key 歌手搜索门',
        );
        expect(
          routing.supports(key, SourceCapability.lyricSearch),
          channel.lyricSearch != null && profile.searchable,
          reason: key,
        );
      }
    });
  });

  group('脚本声明合并', () {
    final declarations = <String, LxSourceDecl>{
      'wy': decl('wy', ['musicUrl', 'lyric', 'pic'], name: '脚本网易'),
      'kg': decl('kg', ['search'], name: '脚本酷狗'),
      'custom': decl('custom', ['search', 'musicUrl', 'lyric', 'pic']),
      'resolve-only': decl('resolve-only', ['musicUrl']),
    };
    final profiles = SourceProfiles.build(activeSources: declarations);
    final routing = routingOf(profiles);

    test('内置 key：脚本补取链 → 搜索走内置、取链走脚本', () {
      expect(kindsOf(routing.routesFor('wy', SourceCapability.search)), [
        'builtin',
      ]);
      expect(kindsOf(routing.routesFor('wy', SourceCapability.resolve)), [
        'script',
      ]);
    });

    test('歌词 / 封面：脚本覆盖在前，渠道原生回退在后', () {
      expect(kindsOf(routing.routesFor('wy', SourceCapability.lyric)), [
        'script',
        'builtin',
      ]);
      expect(kindsOf(routing.routesFor('wy', SourceCapability.picture)), [
        'script',
        'builtin',
      ]);
    });

    test('只有 search 的脚本不能给内置渠道开启搜索（取链门仍关闭）', () {
      expect(kindsOf(routing.routesFor('kg', SourceCapability.search)), [
        'unavailable',
      ]);
      expect(
        (routing.routesFor('kg', SourceCapability.search).single
                as UnavailableSourceRoute)
            .reason,
        SourceUnavailableReason.searchGateClosed,
      );
    });

    test('脚本扩展源：搜索 / 取链 / 歌词 / 封面走脚本，其余不可用', () {
      expect(kindsOf(routing.routesFor('custom', SourceCapability.search)), [
        'script',
      ]);
      expect(kindsOf(routing.routesFor('custom', SourceCapability.resolve)), [
        'script',
      ]);
      expect(kindsOf(routing.routesFor('custom', SourceCapability.lyric)), [
        'script',
      ]);
      expect(kindsOf(routing.routesFor('custom', SourceCapability.picture)), [
        'script',
      ]);
      for (final capability in const [
        SourceCapability.comments,
        SourceCapability.album,
        SourceCapability.artist,
        SourceCapability.lyricSearch,
      ]) {
        expect(
          routing.supports('custom', capability),
          isFalse,
          reason: '$capability',
        );
      }
    });

    test('仅取链脚本源：不进渠道，但取链路线存在', () {
      expect(
        routing.supports('resolve-only', SourceCapability.search),
        isFalse,
      );
      expect(
        routing.supports('resolve-only', SourceCapability.resolve),
        isTrue,
      );
      expect(
        profiles.forKey('resolve-only')!.visible,
        isFalse,
        reason: '不能搜索也没有发现页',
      );
    });

    test('未知 key：统一返回 unknownSource 路线', () {
      final route = routing
          .routesFor('missing', SourceCapability.search)
          .single;
      expect(
        route,
        isA<UnavailableSourceRoute>().having(
          (value) => value.reason,
          'reason',
          SourceUnavailableReason.unknownSource,
        ),
      );
      expect(route.available, isFalse);
    });
  });

  group('any-listen', () {
    test('可用：所有能力都路由到 any-listen 适配器', () {
      final profiles = SourceProfiles.build(anyListenUsable: true);
      final routing = routingOf(profiles);
      final profile = profiles.forKey(AnyListenSource.sourceKey)!;
      for (final capability in SourceCapability.values) {
        final route = routing
            .routesFor(AnyListenSource.sourceKey, capability)
            .single;
        expect(route, isA<AnyListenSourceRoute>(), reason: '$capability');
        expect(
          route.available,
          capability.gateOf(profile.capabilities),
          reason: '$capability 与画像能力位同源',
        );
      }
    });

    test('不可用：路线仍指向适配器，但能力门为 false（由适配器裁决）', () {
      final routing = routingOf(SourceProfiles.build());
      final route = routing
          .routesFor(AnyListenSource.sourceKey, SourceCapability.search)
          .single;
      expect(route, isA<AnyListenSourceRoute>());
      expect(route.available, isFalse);
    });
  });

  test('路由与画像消费同一份脚本声明（不会漂移）', () {
    final declarations = <String, LxSourceDecl>{
      'custom': decl('custom', ['search', 'musicUrl', 'lyric', 'pic']),
    };
    final profiles = SourceProfiles.build(activeSources: declarations);
    final routing = SourceRouting(profiles: profiles);

    expect(identical(routing.declarations, profiles.declarations), isTrue);
    expect(routing.declarations.keys, contains('custom'));
    expect(
      routing.routesFor('custom', SourceCapability.search).single,
      isA<ScriptSourceRoute>().having(
        (route) => route.declaration.key,
        'declaration',
        'custom',
      ),
    );
  });

  test('primaryFor 总返回路线（未知 key 也是 UnavailableSourceRoute）', () {
    final routing = routingOf(SourceProfiles.build());
    final route = routing.primaryFor('missing', SourceCapability.search);
    expect(route, isA<UnavailableSourceRoute>());
  });

  test('能力位为真 ⇒ 至少一条 available 路线（全部 key × 能力）', () {
    final scenarios = <Map<String, LxSourceDecl>>[
      const {},
      {
        'wy': decl('wy', ['musicUrl', 'lyric', 'pic']),
        'kg': decl('kg', ['search']),
        'custom': decl('custom', ['search', 'musicUrl', 'lyric', 'pic']),
      },
    ];
    for (final active in scenarios) {
      final profiles = SourceProfiles.build(
        activeSources: active,
        anyListenUsable: true,
      );
      final routing = routingOf(profiles);
      for (final profile in profiles.channels) {
        final channel = SongChannels.forKey(profile.key);
        for (final capability in SourceCapability.values) {
          if (capability == SourceCapability.artist) {
            // 歌手详情只认适配器；画像的 `artist` 能力位额外叠了搜索门。
            expect(
              routing.supports(profile.key, capability),
              channel?.artist != null,
              reason: '${profile.key} 歌手详情路线',
            );
            expect(
              profile.capabilities.artist,
              channel?.artist != null && profile.searchable,
              reason: '${profile.key} 歌手搜索门',
            );
            continue;
          }
          expect(
            routing.supports(profile.key, capability),
            capability.gateOf(profile.capabilities),
            reason: '${profile.key} × $capability 能力位与路线不一致',
          );
        }
      }
    }
  });
}
