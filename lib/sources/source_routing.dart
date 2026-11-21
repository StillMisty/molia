/// 音源能力路由：一个 key × 一个能力 → 谁来实现（或不可用）。
///
/// 这是 `SourceManager` 唯一的路由决策点。管理器不再写
/// `sourceKey == any_listen` / `SongChannels.isSupported` / 脚本 action 分支，
/// 只按 [SourceRoute] 的类型执行对应适配器。
///
/// 输入只有两份事实：
/// - [SourceProfile]：由 [SourceProfiles.build] 从渠道自述、激活脚本声明与
///   any-listen 可用性合成（能力位 / 身份 / 可见性）；
/// - 激活脚本声明 `LxSourceDecl`：脚本 action 仍是脚本能力的唯一事实。
///
/// 路由与画像必须同源：`profile.capabilities` 为真的能力，这里一定给出
/// 至少一条 `available` 的路线；反之能力位为假时不会凭空产生路线。
/// 唯一例外是 any-listen——它的“是否可用”由适配器在调用时裁决（配置可能
/// 在构造后变化），路由仍给出适配器路线并携带 `available` 供 UI / 测试读。
///
/// 规则由渠道注册表与脚本声明表达，不按平台 key 分支：新增渠道只改自己的
/// `channel/{key}_channel.dart`，新增 action 只改脚本解析。
library;

import '../domain/models/source.dart' show SourceCapabilities;
import 'builtin/channel/channels.dart';
import 'lx/lx_script_info.dart';
import 'source_profiles.dart';

/// 需要路由的能力（与 [SourceCapabilities] 的字段一一对应）。
///
/// `artist` 同时承载歌手搜索与歌手详情：画像的能力位（适配器存在且搜索
/// 路由可用）是 UI 入口门，详情路由只看适配器是否存在（已保存曲目在没有
/// 激活脚本时仍应能打开歌手页）。
enum SourceCapability {
  search,
  resolve,
  lyric,
  picture,
  comments,
  album,
  artist,
  lyricSearch;

  /// 本能力在画像里的门（能力位 → 路由门）。
  bool gateOf(SourceCapabilities capabilities) => switch (this) {
    SourceCapability.search => capabilities.search,
    SourceCapability.resolve => capabilities.resolveUrl,
    SourceCapability.lyric => capabilities.lyrics,
    SourceCapability.picture => capabilities.artwork,
    SourceCapability.comments => capabilities.comment,
    SourceCapability.album => capabilities.collection,
    SourceCapability.artist => capabilities.artist,
    SourceCapability.lyricSearch => capabilities.lyricSearch,
  };
}

/// 不可用原因：管理器据此给出与既有实现一致的错误文案。
enum SourceUnavailableReason {
  /// 画像里没有这个 key（脚本已下架 / 从未声明）。
  unknownSource,

  /// key 存在，但没有任何实现（渠道自述缺适配器 / 脚本没声明该 action）。
  missingAdapter,

  /// 实现存在，但搜索路由门关闭（内置渠道没有可取链路径）。
  searchGateClosed,
}

/// 一次路由答案：实现者 + 是否通过能力门。
sealed class SourceRoute {
  const SourceRoute({
    required this.key,
    required this.capability,
    required this.profile,
    required this.available,
  });

  final String key;
  final SourceCapability capability;
  final SourceProfile profile;

  /// 是否通过能力门（`profile.capabilities` 的同源答案）。
  ///
  /// false 不代表没有实现：any-listen 的配置由适配器在调用时校验。
  final bool available;
}

/// 内置渠道路线：适配器在该渠道自己的声明文件里。
final class BuiltinSourceRoute extends SourceRoute {
  const BuiltinSourceRoute({
    required super.key,
    required super.capability,
    required super.profile,
    required this.channel,
  }) : super(available: true);

  final SongChannel channel;
}

/// 脚本路线：curve 由激活脚本的 action 声明决定。
final class ScriptSourceRoute extends SourceRoute {
  const ScriptSourceRoute({
    required super.key,
    required super.capability,
    required super.profile,
    required this.declaration,
  }) : super(available: true);

  final LxSourceDecl declaration;
}

/// any-listen 路线：能力门由画像给出，实际可用性由适配器裁决。
final class AnyListenSourceRoute extends SourceRoute {
  const AnyListenSourceRoute({
    required super.key,
    required super.capability,
    required super.profile,
    required super.available,
  });
}

/// 不可用路线（带原因，管理器负责措辞）。
final class UnavailableSourceRoute extends SourceRoute {
  const UnavailableSourceRoute({
    required super.key,
    required super.capability,
    required super.profile,
    required this.reason,
    this.declaration,
  }) : super(available: false);

  final SourceUnavailableReason reason;

  /// 脚本声明（能力缺失时用于错误文案里的展示名）。
  final LxSourceDecl? declaration;
}

/// 按画像 + 脚本声明回答路由问题。
///
/// 每次读取都是当前快照（输入已在各自的 ChangeNotifier 里维护），刻意不
/// 缓存：避免「路由缓存了、画像变了」的第二份失效逻辑。
class SourceRouting {
  const SourceRouting({required this.profiles, this.declarations = const {}});

  final SourceProfiles profiles;

  /// 当前激活脚本声明的源（脚本 action 的唯一事实）。
  final Map<String, LxSourceDecl> declarations;

  /// 该 key × 能力的实现路线，按执行顺序排列。
  ///
  /// 多条路线的唯一场景是「脚本优先 + 内置回退」（歌词 / 封面）：脚本声明
  /// 是覆盖层，失败或未声明时继续走渠道原生实现。搜索 / 取链始终单路线。
  List<SourceRoute> routesFor(String key, SourceCapability capability) {
    final profile = profiles.forKey(key);
    if (profile == null) {
      return [
        UnavailableSourceRoute(
          key: key,
          capability: capability,
          profile: _unknownProfile(key),
          reason: SourceUnavailableReason.unknownSource,
        ),
      ];
    }
    if (profile.kind == SourceKind.anyListen) {
      return [
        AnyListenSourceRoute(
          key: key,
          capability: capability,
          profile: profile,
          available: capability.gateOf(profile.capabilities),
        ),
      ];
    }

    final channel = SongChannels.forKey(key);
    final declaration = declarations[key];
    final routes = <SourceRoute>[];

    switch (capability) {
      case SourceCapability.search:
        if (channel != null) {
          if (!profile.searchable) {
            return [
              UnavailableSourceRoute(
                key: key,
                capability: capability,
                profile: profile,
                reason: SourceUnavailableReason.searchGateClosed,
                declaration: declaration,
              ),
            ];
          }
          routes.add(_builtin(profile, channel, capability));
        } else if (declaration != null) {
          if (!declaration.canSearch) {
            return [_missing(profile, declaration, capability)];
          }
          routes.add(_script(profile, declaration, capability));
        }
      case SourceCapability.resolve:
        if (channel?.resolve != null) {
          routes.add(_builtin(profile, channel!, capability));
        } else if (declaration?.canResolveUrl ?? false) {
          routes.add(_script(profile, declaration!, capability));
        }
      case SourceCapability.lyric:
        if (declaration?.canFetchLyric ?? false) {
          routes.add(_script(profile, declaration!, capability));
        }
        if (channel?.lyric != null) {
          routes.add(_builtin(profile, channel!, capability));
        }
      case SourceCapability.picture:
        if (declaration?.canFetchPic ?? false) {
          routes.add(_script(profile, declaration!, capability));
        }
        if (channel?.pic != null) {
          routes.add(_builtin(profile, channel!, capability));
        }
      case SourceCapability.comments:
        if (channel?.comments != null) {
          routes.add(_builtin(profile, channel!, capability));
        }
      case SourceCapability.album:
        if (channel?.album != null) {
          routes.add(_builtin(profile, channel!, capability));
        }
      case SourceCapability.artist:
        // 详情只认适配器：画像的 `artist` 还叠了搜索门（UI 入口），已保存
        // 曲目的歌手 id 在无激活脚本时仍可直接取详情。
        if (channel?.artist != null) {
          routes.add(_builtin(profile, channel!, capability));
        }
      case SourceCapability.lyricSearch:
        if (channel?.lyricSearch != null && profile.searchable) {
          routes.add(_builtin(profile, channel!, capability));
        }
    }

    if (routes.isEmpty) {
      return [
        if (declaration != null)
          _missing(profile, declaration, capability)
        else
          UnavailableSourceRoute(
            key: key,
            capability: capability,
            profile: profile,
            reason: SourceUnavailableReason.missingAdapter,
          ),
      ];
    }
    return routes;
  }

  /// 第一条路线（不判断能力门）；没有实现时返回 null。
  SourceRoute? primaryFor(String key, SourceCapability capability) =>
      routesFor(key, capability).firstOrNull;

  /// 该 key 是否具备能力（与 `profile.capabilities` 同源）。
  bool supports(String key, SourceCapability capability) => routesFor(
    key,
    capability,
  ).any((route) => route.available && route is! UnavailableSourceRoute);

  BuiltinSourceRoute _builtin(
    SourceProfile profile,
    SongChannel channel,
    SourceCapability capability,
  ) => BuiltinSourceRoute(
    key: profile.key,
    capability: capability,
    profile: profile,
    channel: channel,
  );

  ScriptSourceRoute _script(
    SourceProfile profile,
    LxSourceDecl declaration,
    SourceCapability capability,
  ) => ScriptSourceRoute(
    key: profile.key,
    capability: capability,
    profile: profile,
    declaration: declaration,
  );

  UnavailableSourceRoute _missing(
    SourceProfile profile,
    LxSourceDecl declaration,
    SourceCapability capability,
  ) => UnavailableSourceRoute(
    key: profile.key,
    capability: capability,
    profile: profile,
    reason: SourceUnavailableReason.missingAdapter,
    declaration: declaration,
  );

  /// 未知 key 的占位画像：只用于让 [SourceRoute] 形状统一。
  ///
  /// 它不会进 `profiles`，`available` 恒 false，调用方只读 `reason`。
  static SourceProfile _unknownProfile(String key) => SourceProfile(
    key: key,
    displayName: key,
    kind: SourceKind.lx,
    capabilities: const SourceCapabilities(),
  );
}
