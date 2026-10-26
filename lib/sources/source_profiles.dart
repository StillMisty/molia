/// 音源画像（SourceProfiles）：一次回答「这个源能做什么」。
///
/// 之前同一份「源 × 能力」事实散在四处：`BuiltinPlatforms`（内置平台适配器）、
/// 激活脚本的 `LxSourceDecl`（action 声明）、`AnyListenSource.isUsable`、以及
/// `SourceManager.channels` / `_isBuiltinSearchable` 各自再算一遍的可见性与
/// 路由门。加一个平台要在能力位、渠道、搜索门、歌词/封面派发之间反复对齐。
///
/// 本模块把这些输入组合成每个 key 一份不可变 [SourceProfile]：
/// - 身份：key / 显示名 / kind；
/// - 偏好：`enabled`（停用开关）与派生 `visible`（进不进渠道列表）；
/// - 能力：`SourceCapabilities` 是唯一答案，`searchable` / `canResolveUrl`
///   直接读能力位，不再维护第二份布尔值；
/// - 排序：渠道顺序由 `SourcePreferences.sourceOrder` 决定，未登记的 key
///   保持原有相对顺序追加。
///
/// 能力位由「适配器是否存在 + 脚本声明 + any-listen 可用性」推导：
/// 内置平台的搜索必须同时有搜索适配器与「原生取链或脚本可取链」，
/// 与 `searchWithMeta` 的路由门同一条规则；歌词 / 封面只认注册表里的
/// 原生适配器（或脚本声明的 lyric / pic action）。因此能力位为真时，
/// 对应路由一定存在实现。
library;

import '../domain/models/source.dart' as domain;
import 'any_listen/any_listen_source.dart';
import 'builtin/builtin_platforms.dart';
import 'lx/lx_script_info.dart';

/// 搜索结果来源类型（sources 层；领域层另有同义的 `domain.SourceKind`）。
enum SourceKind { builtin, lx, anyListen }

/// 一个音源的完整画像：身份 + 用户偏好 + 能力矩阵。
class SourceProfile {
  /// 规范 key（内置平台 / 脚本声明 key / any_listen）。
  final String key;

  /// 展示名（内置平台用注册表显示名，脚本源用脚本声明名）。
  final String displayName;

  final SourceKind kind;

  /// 用户是否启用该渠道（false = 已停用，仅从列表/搜索隐藏，不影响已保存
  /// 曲目的内部路由）。
  final bool enabled;

  /// 是否有内置「发现」入口（热榜 / 歌单 / 热搜）。
  final bool discoverable;

  /// 能力矩阵是唯一事实：`searchable` / `canResolveUrl` 都是它的派生视图。
  final domain.SourceCapabilities capabilities;

  const SourceProfile({
    required this.key,
    required this.displayName,
    required this.kind,
    required this.capabilities,
    this.enabled = true,
    this.discoverable = false,
  });

  /// 是否可搜索（与 `SourceManager.searchWithMeta` 的路由门同一条）。
  bool get searchable => capabilities.search;

  /// 是否能取到可播流（原生取链或脚本 musicUrl）。
  bool get canResolveUrl => capabilities.resolveUrl;

  /// 是否进入渠道列表：可搜索或有发现页。停用项仍在列表里（enabled=false），
  /// 这样音源页可以重新启用。
  bool get visible => searchable || discoverable;

  /// 画像 → 领域渠道形状（全应用唯一的渠道投影）。
  ///
  /// [order] 由消费方按列表下标给出（渠道列表 / 可搜索列表 / 注册表），
  /// 其余字段逐项取自本画像；sources 层与 domain 层的 `SourceKind` 映射
  /// 只在这里发生一次。
  domain.SourceDescriptor toDescriptor({int order = 0}) =>
      domain.SourceDescriptor(
        key: key,
        displayName: displayName,
        kind: switch (kind) {
          SourceKind.builtin => domain.SourceKind.builtin,
          SourceKind.lx => domain.SourceKind.lx,
          SourceKind.anyListen => domain.SourceKind.anyListen,
        },
        capabilities: capabilities,
        enabled: enabled,
        discoverable: discoverable,
        order: order,
      );

  @override
  bool operator ==(Object other) =>
      other is SourceProfile &&
      other.key == key &&
      other.displayName == displayName &&
      other.kind == kind &&
      other.enabled == enabled &&
      other.discoverable == discoverable &&
      other.capabilities == capabilities;

  @override
  int get hashCode =>
      Object.hash(key, displayName, kind, enabled, discoverable, capabilities);

  @override
  String toString() => 'SourceProfile($key)';
}

/// 画像列表 → 渠道描述列表（顺序即列表下标，唯一投影处）。
extension SourceProfileDescriptors on Iterable<SourceProfile> {
  List<domain.SourceDescriptor> toDescriptors() {
    var order = 0;
    return [for (final profile in this) profile.toDescriptor(order: order++)];
  }
}

/// 一次构建的只读画像快照：按 key 查能力 + 已排序的渠道 / 可搜索列表。
///
/// 刻意不做增量缓存：输入（激活脚本、any-listen、偏好）都已在各自的
/// ChangeNotifier 里维护，重复构建只有个位数条目；多一份缓存就多一处失效
/// 逻辑，反而容易与路由漂移。
class SourceProfiles {
  SourceProfiles._(this._byKey, this.channels)
    : searchable = List.unmodifiable(
        channels.where((profile) => profile.enabled && profile.searchable),
      );

  final Map<String, SourceProfile> _byKey;

  /// 渠道列表（含停用项；按用户顺序）。
  final List<SourceProfile> channels;

  /// 可搜索且启用的源（按用户顺序；`SourceRegistry.descriptors` 的输入）。
  final List<SourceProfile> searchable;

  /// 按 key 查画像；未知 key（例如已下架、无激活声明的脚本）返回 null。
  SourceProfile? forKey(String key) => _byKey[key];

  /// 组合当前状态。
  ///
  /// [activeSources] 是当前激活脚本声明的源；[anyListenUsable] 表示远程
  /// 音源「已配置且启用」；[disabledChannels] / [sourceOrder] 来自
  /// `SourcePreferences`。
  factory SourceProfiles.build({
    Map<String, LxSourceDecl> activeSources = const {},
    bool anyListenUsable = false,
    Set<String> disabledChannels = const {},
    List<String> sourceOrder = const [],
  }) {
    final profiles = <String, SourceProfile>{};

    // 1. 每个内置平台一份画像；同名脚本声明只作为该平台的补充（脚本可取链 /
    //    取词 / 取图），不生成第二个同 key 的 LX 源——一个 key 只能有一个答案。
    for (final platform in BuiltinPlatforms.searchCandidates) {
      profiles[platform.key] = _builtinProfile(
        platform,
        activeSources[platform.key],
        disabledChannels,
      );
    }

    // 2. 脚本自定义源；builtin key 与 any_listen 不重复建画像。
    for (final decl in activeSources.values) {
      if (profiles.containsKey(decl.key) ||
          decl.key == AnyListenSource.sourceKey) {
        continue;
      }
      profiles[decl.key] = _lxProfile(decl, disabledChannels);
    }

    // 3. any-listen：不可用时仍保留画像（能力全 false），
    //    这样 capabilitiesFor 与渠道判断不必特判 key。
    profiles[AnyListenSource.sourceKey] = _anyListenProfile(
      anyListenUsable,
      disabledChannels,
    );

    // 4. 渠道候选顺序与迁移前一致：脚本可搜索源 → 内置可搜索平台 →
    //    any-listen → 仅发现的内置平台（避免发现入口排到搜索源前面）。
    //    内置 key 的脚本声明已在第 1 步合并，不在这里重复出现。
    final candidateKeys = <String>[];
    final added = <String>{};
    void add(String key) {
      if (added.add(key)) candidateKeys.add(key);
    }

    for (final decl in activeSources.values) {
      if (BuiltinPlatforms.isSupported(decl.key) ||
          decl.key == AnyListenSource.sourceKey) {
        continue;
      }
      if (profiles[decl.key]!.searchable) add(decl.key);
    }
    for (final platform in BuiltinPlatforms.searchCandidates) {
      if (profiles[platform.key]!.searchable) add(platform.key);
    }
    if (anyListenUsable) add(AnyListenSource.sourceKey);
    for (final platform in BuiltinPlatforms.searchCandidates) {
      if (profiles[platform.key]!.discoverable) add(platform.key);
    }

    final orderedKeys = applyOrder(candidateKeys, sourceOrder);
    return SourceProfiles._(
      Map.unmodifiable(profiles),
      List.unmodifiable([for (final key in orderedKeys) profiles[key]!]),
    );
  }

  /// 按照 [order] 整理 [keys]：顺序表中出现过的按表排列，未出现的保持
  /// 原相对顺序追加在末尾。新导入的音源自动排在末尾，无需迁移持久化数据。
  static List<String> applyOrder(List<String> keys, List<String> order) {
    final pending = <String>{...keys};
    final result = <String>[];
    for (final key in order) {
      // 忽略顺序表中已不存在或重复的 key。
      if (pending.remove(key)) result.add(key);
    }
    for (final key in keys) {
      if (pending.remove(key)) result.add(key);
    }
    return result;
  }

  static SourceProfile _builtinProfile(
    BuiltinPlatform platform,
    LxSourceDecl? script,
    Set<String> disabledChannels,
  ) {
    final scriptCanResolve = script?.canResolveUrl ?? false;
    // 与 searchWithMeta 的路由门一致：搜索适配器存在，且原生取链或脚本
    // 可取链才允许搜索；缺少搜索适配器时即使有原生取链也不能宣称可搜索。
    final searchable =
        platform.search != null &&
        (platform.resolve != null || scriptCanResolve);
    final canResolve = platform.resolve != null || scriptCanResolve;
    return SourceProfile(
      key: platform.key,
      displayName: platform.displayName,
      kind: SourceKind.builtin,
      enabled: !disabledChannels.contains(platform.key),
      discoverable: platform.discover != null,
      capabilities: domain.SourceCapabilities(
        search: searchable,
        pagination: searchable,
        resolveUrl: canResolve,
        // 歌词 / 封面只认注册表里的原生适配器；脚本声明是并行的回退路径。
        lyrics: platform.lyric != null || (script?.canFetchLyric ?? false),
        artwork: platform.pic != null || (script?.canFetchPic ?? false),
        comment: platform.comments != null,
        collection: platform.album != null,
        // 歌手 / 按歌词搜歌依赖搜索路由：能力位与路由门必须一致，
        // 不允许 UI 显示一个必然失败的入口。
        artist: platform.artist != null && searchable,
        lyricSearch: platform.lyricSearch != null && searchable,
      ),
    );
  }

  static SourceProfile _lxProfile(
    LxSourceDecl decl,
    Set<String> disabledChannels,
  ) {
    return SourceProfile(
      key: decl.key,
      displayName: decl.name.isEmpty ? decl.key : decl.name,
      kind: SourceKind.lx,
      enabled: !disabledChannels.contains(decl.key),
      capabilities: domain.SourceCapabilities(
        search: decl.canSearch,
        pagination: decl.canSearch,
        resolveUrl: decl.canResolveUrl,
        lyrics: decl.canFetchLyric,
        artwork: decl.canFetchPic,
      ),
    );
  }

  static SourceProfile _anyListenProfile(
    bool usable,
    Set<String> disabledChannels,
  ) {
    return SourceProfile(
      key: AnyListenSource.sourceKey,
      displayName: AnyListenSource.displayName,
      kind: SourceKind.anyListen,
      enabled: !disabledChannels.contains(AnyListenSource.sourceKey),
      capabilities: domain.SourceCapabilities(
        search: usable,
        pagination: usable,
        resolveUrl: usable,
        lyrics: usable,
        artwork: usable,
      ),
    );
  }
}
