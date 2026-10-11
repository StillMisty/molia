import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'any_listen/any_listen_config.dart';
import 'any_listen/any_listen_errors.dart';
import 'any_listen/any_listen_source.dart';
import 'builtin/builtin_search.dart';
import 'builtin/discover_source.dart';
import 'builtin/kg_lyric.dart';
import 'builtin/kg_pic.dart';
import 'builtin/kw_lyric.dart';
import 'builtin/kw_pic.dart';
import 'builtin/lyric_result.dart';
import 'builtin/mg_lyric.dart';
import 'builtin/tx_lyric.dart';
import 'builtin/wy_lyric.dart';
import 'builtin/wy_music_detail.dart';
import 'lx/lx_engine_supervisor.dart';
import 'lx/lx_engine_types.dart';
import 'lx/lx_script_info.dart';
import 'lx/lx_script_repository.dart';
import 'lx/lx_script_update.dart';
import 'lx/lx_search_parse.dart';
import 'source_search_result.dart';
import 'source_track.dart';
import '../data/cache/request_cache.dart';
import '../domain/models/source.dart';

// UI（音源页）白名单仅允许直连 source_manager，这里把在线更新流程的
// 返回/异常类型随管理器一起导出，避免扩大分层豁免。
export 'lx/lx_engine_types.dart' show LxEngineException;
export 'lx/lx_script_update.dart'
    show ScriptUpdateCheck, ScriptUpdateError, ScriptUpdateException;

/// 搜索结果来源类型。
enum SourceKind { builtin, lx, anyListen }

class SourceOption {
  final String key;
  final String name;
  final SourceKind kind;
  final bool canSearch;

  /// 是否具备内置「发现」能力（热榜 / 歌单 / 热搜：wy/tx/kg/kw/mg）。
  final bool discoverable;

  /// 是否启用（停用后不出现在资料页渠道选择与搜索结果中）。
  final bool enabled;

  const SourceOption({
    required this.key,
    required this.name,
    required this.kind,
    required this.canSearch,
    this.discoverable = false,
    this.enabled = true,
  });
}

/// 音源管理器：
/// - 管理已导入的 LX 音源脚本（导入 / 删除 / 激活）；
/// - 聚合内置平台搜索、脚本扩展搜索与 any-listen 远程音源；
/// - 统一对外提供取链 / 歌词 / 封面能力。
///
/// 该抽象与 any-listen 的接入隔离：上层只依赖 [SourceManager] 的
/// search / resolveUrl / fetchLyric / fetchPic 能力；any-listen 通过
/// [AnyListenSource] 适配为 [SourceKind.anyListen]。仅当「已配置且启用」
/// 时才出现在 [searchableSources]，未配置/连接失败时对现有功能零影响。
class SourceManager extends ChangeNotifier {
  static const _prefsQualityKey = 'lx_default_quality';
  static const _prefsSourceOrderKey = 'lx_source_order';
  static const _prefsDisabledChannelsKey = 'lx_channel_disabled';
  static const _supportedQualitys = kLxQualityOrder;

  final LxScriptRepository repository = LxScriptRepository();

  /// 引擎自愈包装：超时/isolate 退出后自动按退避重启。
  /// 构造参数仅用于测试注入（默认创建真实 supervisor，行为不变）。
  final LxEngineSupervisor _engine;
  final AnyListenSource _anyListenSource = AnyListenSource();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 内置平台原生歌词/封面回退缓存（脚本不可用 / 未声明时的内置实现；
  /// 5 分钟 TTL，key 为 `{track.id}:lyric|pic`）。
  final RequestCache _builtinLyricCache =
      RequestCache(maxEntries: 64, ttl: const Duration(minutes: 5));
  final RequestCache _builtinPicCache =
      RequestCache(maxEntries: 128, ttl: const Duration(minutes: 5));

  SourceManager({LxEngineSupervisor? engine})
      : _engine = engine ?? LxEngineSupervisor() {
    _engine.onStateChanged = _onEngineStateChanged;
  }

  bool _initialized = false;
  String? _activatingId;
  String? _activeError;
  Map<String, LxSourceDecl> _activeSources = {};
  String _preferredQuality = '320k';
  LxUpdateAlert? _lastUpdateAlert;
  List<String> _sourceOrder = const [];
  Set<String> _disabledChannels = {};

  bool get initialized => _initialized;
  bool get isActivating => _activatingId != null;
  String? get activeError => _activeError;
  Map<String, LxSourceDecl> get activeSources =>
      Map.unmodifiable(_activeSources);
  List<LxScriptInfo> get scripts => repository.scripts;
  LxScriptInfo? get activeScript => repository.activeScript;
  bool get engineReady => _engine.isRunning;
  String get preferredQuality => _preferredQuality;
  LxUpdateAlert? get lastUpdateAlert => _lastUpdateAlert;

  /// 用户自定义的渠道顺序（持久化于 shared_preferences；同时决定渠道路由
  /// 之外的展示顺序与搜索音源顺序）。
  List<String> get sourceOrder => List.unmodifiable(_sourceOrder);

  /// 已停用的渠道集合（持久化；停用只影响列表/选择，不影响已保存曲目的取链）。
  Set<String> get disabledChannels => Set.unmodifiable(_disabledChannels);

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  bool get hasActiveSource =>
      !kIsWeb && _engine.isRunning && _activeSources.isNotEmpty;

  /// any-listen 适配器（搜索 / 取链 / 歌词 / 封面 / 连接测试）。
  AnyListenSource get anyListenSource => _anyListenSource;

  /// any-listen 当前配置。
  AnyListenConfig get anyListenConfig => _anyListenSource.config;

  /// any-listen 是否「已配置且启用」；只有此时才出现在 [searchableSources]。
  bool get anyListenAvailable => _anyListenSource.isUsable;

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序排列）。
  ///
  /// 资料页的渠道选择与「音源管理」的渠道排序都消费该列表；脚本扩展源 /
  /// any-listen 只有搜索能力，内置发现平台无论是否有脚本都保留发现入口。
  List<SourceOption> get channels {
    final candidates = <SourceOption>[
      for (final option in _searchableCandidates)
        SourceOption(
          key: option.key,
          name: option.name,
          kind: option.kind,
          canSearch: option.canSearch,
          discoverable: BuiltinDiscover.isSupported(option.key),
          enabled: !_disabledChannels.contains(option.key),
        ),
    ];
    final existing = candidates.map((o) => o.key).toSet();
    // 未出现在可搜索列表中的内置发现平台（无脚本也可浏览热榜/歌单）。
    for (final key in BuiltinDiscover.sourceKeys) {
      if (existing.contains(key)) continue;
      candidates.add(SourceOption(
        key: key,
        name: BuiltinSearch.displayName(key),
        kind: SourceKind.builtin,
        canSearch: false,
        discoverable: true,
        enabled: !_disabledChannels.contains(key),
      ));
    }

    final orderedKeys =
        applySourceOrder(candidates.map((o) => o.key).toList(), _sourceOrder);
    final byKey = {for (final option in candidates) option.key: option};
    return [for (final key in orderedKeys) byKey[key]!];
  }

  /// 可供搜索/播放的音源列表（仅启用项；按用户自定义顺序排列）。
  List<SourceOption> get searchableSources => [
        for (final option in channels)
          if (option.enabled && option.canSearch) option,
      ];

  /// 未排序的可搜索候选：脚本扩展搜索源 → 内置平台（需脚本支持取链）→
  /// any-listen（仅「已配置且启用」时出现）。
  List<SourceOption> get _searchableCandidates {
    final candidates = <SourceOption>[];
    for (final decl in _activeSources.values) {
      if (decl.canSearch) {
        candidates.add(SourceOption(
          key: decl.key,
          name: decl.name,
          kind: SourceKind.lx,
          canSearch: true,
        ));
      }
    }
    for (final entry in BuiltinSearch.platforms.entries) {
      final decl = _activeSources[entry.key];
      if (decl != null && decl.canResolveUrl) {
        candidates.add(SourceOption(
          key: entry.key,
          name: entry.value,
          kind: SourceKind.builtin,
          canSearch: true,
        ));
      }
    }
    // any-listen 远程音源：仅当已配置且启用时出现；新 key 未出现在顺序表中
    // 时自动排在末尾。
    if (_anyListenSource.isUsable) {
      candidates.add(const SourceOption(
        key: AnyListenSource.sourceKey,
        name: AnyListenSource.displayName,
        kind: SourceKind.anyListen,
        canSearch: true,
      ));
    }
    return candidates;
  }

  /// 音源能力：与路由的实际 gating 一致（registry / 领域适配器共用）。
  ///
  /// - builtin：出现在 [searchableSources] 的前提是已有可取链脚本，因此
  ///   `resolveUrl` 与脚本声明一致；歌词/封面为 Dart 原生实现（脚本未声明
  ///   `lyric`/`pic` action 时也可用）；
  /// - lx：按脚本声明的 action；
  /// - any-listen：已配置且启用时全部可用。
  SourceCapabilities capabilitiesFor(String key) {
    if (key == AnyListenSource.sourceKey) {
      final usable = _anyListenSource.isUsable;
      return SourceCapabilities(
        search: usable,
        pagination: usable,
        resolveUrl: usable,
        lyrics: usable,
        artwork: usable,
      );
    }
    final decl = _activeSources[key];
    // 内置平台（kw/kg/tx/wy/mg）的搜索/分页由 Dart 移植实现（BuiltinSearch），
    // 能力跟随「脚本可取链」，与 channels/_searchableCandidates 的 canSearch
    // 保持一致；脚本声明的 canSearch 只描述脚本扩展源自身的社区搜索 action。
    // 两处不一致会静默拒绝渠道→搜索源同步（搜索停留在上一次选中的源，
    // 与展示渠道不符）。
    final builtin = BuiltinSearch.isBuiltin(key);
    final builtinSearchable = builtin && (decl?.canResolveUrl ?? false);
    return SourceCapabilities(
      search: builtinSearchable || (decl?.canSearch ?? false),
      pagination: builtinSearchable || (decl?.canSearch ?? false),
      resolveUrl: decl?.canResolveUrl ?? false,
      lyrics: builtin || (decl?.canFetchLyric ?? false),
      artwork: builtin || (decl?.canFetchPic ?? false),
    );
  }

  /// 按照 [order] 整理 [keys]，返回完整排序结果：
  /// 在顺序表中出现过的按表排列，未出现的保持原相对顺序追加在末尾。
  ///
  /// 这样新导入的音源会自动排在末尾，无需迁移已有的持久化数据。
  @visibleForTesting
  static List<String> applySourceOrder(List<String> keys, List<String> order) {
    final pending = <String>{...keys};
    final result = <String>[];
    for (final key in order) {
      // 忽略顺序表中已不存在或重复的 key
      if (pending.remove(key)) result.add(key);
    }
    for (final key in keys) {
      if (pending.remove(key)) result.add(key);
    }
    return result;
  }

  /// supervisor 状态回调：重启成功后用引擎当前声明的源刷新 [activeSources]，
  /// 修复“引擎死了源列表还在”（超时 kill 后脚本重新执行，声明可能变化）。
  void _onEngineStateChanged(LxEngineState state) {
    if (state != LxEngineState.ready) return;
    _activeSources = Map<String, LxSourceDecl>.from(_engine.sources);
    _activeError = null;
    notifyListeners();
  }

  Future<void> init() async {
    await repository.init();
    await _loadPreferences();
    // 只读本地配置，不发起网络请求；失败时 AnyListenSource 维持默认（未配置）。
    await _anyListenSource.init();

    _subscriptions.add(_engine.logs.listen((entry) {
      if (kDebugMode) debugPrint('[LX:${entry.level}] ${entry.message}');
    }));
    _subscriptions.add(_engine.updateAlerts.listen((alert) {
      _lastUpdateAlert = alert;
      // 运行期上报的更新地址记入当前激活脚本，供「立即更新」使用。
      unawaited(_recordUpdateUrl(alert));
      notifyListeners();
    }));

    _initialized = true;
    notifyListeners();

    final activeId = repository.activeId;
    if (activeId != null && !kIsWeb) {
      try {
        await activate(activeId);
      } catch (_) {
        // 激活失败时保留错误信息供 UI 展示
      }
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final quality = prefs.getString(_prefsQualityKey);
      if (quality != null && _supportedQualitys.contains(quality)) {
        _preferredQuality = quality;
      }
      final order = prefs.getStringList(_prefsSourceOrderKey);
      if (order != null) {
        _sourceOrder = order;
      }
      final disabled = prefs.getStringList(_prefsDisabledChannelsKey);
      if (disabled != null) {
        _disabledChannels = disabled.toSet();
      }
    } catch (_) {}
  }

  /// 重新读取渠道偏好（顺序 / 停用 / 音质）。跨设备同步应用远端设置后
  /// 由组合根调用；先重置为默认再加载，保证远端「清空」也能生效。
  Future<void> reloadPreferences() async {
    _preferredQuality = '320k';
    _sourceOrder = const [];
    _disabledChannels = <String>{};
    await _loadPreferences();
    notifyListeners();
  }

  /// 脚本被外部（跨设备同步）增删改后刷新引擎状态：
  /// 有激活脚本则重新激活（重新执行脚本、收集声明的源），否则停用引擎。
  Future<void> refreshScriptsFromStorage() async {
    final activeId = repository.activeId;
    if (activeId == null) {
      if (_activeSources.isNotEmpty) {
        await _engine.dispose();
        _activeSources = {};
      }
      notifyListeners();
      return;
    }
    try {
      await activate(activeId);
    } catch (_) {
      // 激活失败保留错误信息供 UI 展示（activate 已写入 _activeError）。
    }
  }

  Future<void> setPreferredQuality(String quality) async {
    if (!_supportedQualitys.contains(quality)) return;
    _preferredQuality = quality;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsQualityKey, quality);
    } catch (_) {}
  }

  /// 覆盖音源顺序（去重后持久化）。
  Future<void> setSourceOrder(List<String> keys) async {
    final cleaned = <String>[];
    for (final key in keys) {
      if (key.isEmpty || cleaned.contains(key)) continue;
      cleaned.add(key);
    }
    if (listEquals(_sourceOrder, cleaned)) return;
    _sourceOrder = cleaned;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsSourceOrderKey, cleaned);
    } catch (_) {}
  }

  /// 将渠道（含内置发现平台）在渠道列表中上移/下移 [delta] 位
  /// （-1 上移，1 下移；停用项同样参与排序）。
  Future<void> moveChannel(String key, int delta) async {
    if (delta == 0) return;
    final keys = channels.map((o) => o.key).toList();
    final index = keys.indexOf(key);
    if (index < 0) return;
    final target = index + delta;
    if (target < 0 || target >= keys.length) return;
    keys.removeAt(index);
    keys.insert(target, key);
    await setSourceOrder(keys);
  }

  /// 启用 / 停用渠道（持久化）。停用后该渠道不再出现在资料页渠道选择
  /// 与搜索结果中；已保存内容仍可通过内部路由取链播放。
  Future<void> setChannelEnabled(String key, bool enabled) async {
    if (key.isEmpty) return;
    final changed =
        enabled ? _disabledChannels.remove(key) : _disabledChannels.add(key);
    if (!changed) return;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsDisabledChannelsKey,
        _disabledChannels.toList(),
      );
    } catch (_) {}
  }

  /// 清空自定义渠道顺序，恢复「脚本音源在前、内置平台在后」的默认排序。
  Future<void> resetChannelOrder() async {
    if (_sourceOrder.isEmpty) return;
    _sourceOrder = const [];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsSourceOrderKey);
    } catch (_) {}
  }

  /// 保存 any-listen 配置（设置页调用），并刷新音源可见性。
  ///
  /// 只写本地，不发起网络请求；返回是否持久化成功。
  Future<bool> updateAnyListenConfig(AnyListenConfig config) async {
    final saved = await _anyListenSource.updateConfig(config);
    notifyListeners();
    return saved;
  }

  /// 重新从 shared_preferences 加载 any-listen 配置（例如设置页直接写入后）。
  Future<void> reloadAnyListenConfig() async {
    await _anyListenSource.init();
    notifyListeners();
  }

  /// 导入脚本（不激活时可用于预览）。
  Future<LxScriptInfo> importScript(String script, {bool activate = false}) async {
    final info = LxScriptInfo.parse(script);
    if (info == null) {
      throw const FormatException('无法解析音源脚本：缺少以 /** @name ... */ 开头的元信息');
    }
    await repository.add(info);
    notifyListeners();
    if (activate || repository.activeScript == null) {
      await this.activate(info.id);
    }
    return info;
  }

  /// 激活指定脚本（重新执行脚本并收集其声明的源）。
  Future<void> activate(String id) async {
    final script = repository.scripts.where((s) => s.id == id).firstOrNull;
    if (script == null) {
      throw LxEngineException('音源脚本不存在: $id');
    }
    _activatingId = id;
    _activeError = null;
    notifyListeners();
    try {
      final sources = await _engine.start(script);
      _activeSources = sources;
      await repository.setActive(id);
      await repository.cacheSources(id, sources);
    } catch (e) {
      _activeError = e is LxEngineException ? e.message : e.toString();
      _activeSources = {};
      rethrow;
    } finally {
      _activatingId = null;
      notifyListeners();
    }
  }

  /// 停用当前音源。
  Future<void> deactivate() async {
    await _engine.dispose();
    _activeSources = {};
    await repository.setActive(null);
    notifyListeners();
  }

  Future<void> removeScript(String id) async {
    await repository.remove(id);
    if (repository.activeId == null) {
      await _engine.dispose();
      _activeSources = {};
    }
    notifyListeners();
  }

  /// 搜索（兼容入口，只返回曲目列表）。
  ///
  /// 需要 total/hasMore 等分页信息时请使用 [searchWithMeta]。
  Future<List<SourceTrack>> search(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final result =
        await searchWithMeta(sourceKey, keyword, page: page, limit: limit);
    return result.tracks;
  }

  /// 分页搜索。内置平台走 Dart 移植的搜索接口，脚本自定义源走脚本扩展 action。
  ///
  /// 返回 [SourceSearchResult]，携带 hasMore（由平台总数或本页结果推断）与
  /// total（平台返回时才有）。脚本扩展搜索的返回格式为社区约定，字段兼容性
  /// 尽力而为：优先识别 isEnd / hasMore / total，否则用 tracks.length >= limit 近似。
  Future<SourceSearchResult> searchWithMeta(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    // any-listen 远程音源（未配置/未启用时抛出可读异常，不影响其它分支）
    if (sourceKey == AnyListenSource.sourceKey) {
      try {
        return await _anyListenSource.search(keyword, page: page, limit: limit);
      } on AnyListenException catch (e) {
        // 跨出 sources 层的唯一转换点：保留鉴权/连接失败的 kind 语义。
        throw e.toSourceFailure();
      }
    }
    final decl = _activeSources[sourceKey];
    if (BuiltinSearch.isBuiltin(sourceKey)) {
      if (decl == null || !decl.canResolveUrl) {
        throw LxEngineException(
            '当前音源脚本不支持 ${BuiltinSearch.displayName(sourceKey)}，无法播放该平台歌曲');
      }
      return BuiltinSearch.searchWithMeta(sourceKey, keyword,
          page: page, limit: limit);
    }
    if (decl == null) {
      throw LxEngineException('未知音源: $sourceKey');
    }
    if (!decl.canSearch) {
      throw LxEngineException('音源「${decl.name}」不支持搜索');
    }
    final action = decl.actions.contains('musicSearch') ? 'musicSearch' : 'search';
    final data = await _engine.search(
      source: sourceKey,
      action: action,
      keyword: keyword,
      page: page,
      limit: limit,
    );
    return parseLxSearchResult(sourceKey, data, page: page, limit: limit);
  }

  /// 解析播放地址。requestedQuality 为空时使用默认音质偏好。
  Future<String> resolveUrl(SourceTrack track, {String? requestedQuality}) async {
    // any-listen 曲目走远程服务器取链；其余曲目走 LX 脚本取链。
    if (AnyListenSource.isAnyListenTrack(track)) {
      try {
        return await _anyListenSource.resolveUrl(track,
            requestedQuality: requestedQuality);
      } on AnyListenException catch (e) {
        throw e.toSourceFailure();
      }
    }
    final decl = _activeSources[track.sourceKey];
    if (decl == null) {
      throw LxEngineException('音源 ${track.sourceKey} 当前不可用');
    }
    if (!decl.canResolveUrl) {
      throw LxEngineException('音源「${decl.name}」不支持获取播放地址');
    }
    final picked = track.pickQuality(requestedQuality ?? _preferredQuality);
    final musicInfo = _withPickedHash(track, picked);
    return _engine.getMusicUrl(
      source: track.sourceKey,
      musicInfo: musicInfo,
      quality: picked,
    );
  }

  /// 酷狗等平台不同音质对应不同 hash，取链前替换为所选音质的 hash。
  Map<String, dynamic> _withPickedHash(SourceTrack track, String quality) {
    final info = Map<String, dynamic>.from(track.raw);
    final qualityInfo = track.qualities.where((q) => q.type == quality).firstOrNull;
    if (qualityInfo?.hash != null && qualityInfo!.hash!.isNotEmpty) {
      info['hash'] = qualityInfo.hash;
    }
    return info;
  }

  /// 获取歌词（脚本 lyric action 优先，内置平台原生实现回退）。
  ///
  /// 无脚本 / 脚本不支持 / 脚本失败时走内置实现：
  /// wy eapi + yrc、QQ PlayLyricInfo + QRC、酷狗 KRC、酷我 LRCX、咪咕 MRC。
  Future<LxLyricResult?> fetchLyric(SourceTrack track) async {
    if (AnyListenSource.isAnyListenTrack(track)) {
      try {
        final lyric = await _anyListenSource.fetchLyric(track);
        if (lyric == null) return null;
        return LxLyricResult(
          lyric: lyric.lyric,
          tlyric: lyric.tlyric,
          rlyric: lyric.rlyric,
          // any-listen 的 awlyric 为逐字歌词，对应 LX 的 lxlyric。
          lxlyric: lyric.awlyric,
        );
      } catch (_) {
        // 与 LX 分支保持一致：歌词失败返回 null，交由现有歌词源回退。
        return null;
      }
    }
    final decl = _activeSources[track.sourceKey];
    if (decl != null && decl.canFetchLyric) {
      try {
        final result = await _engine.getLyric(
          source: track.sourceKey,
          musicInfo: track.raw,
        );
        if (result.lyric.trim().isNotEmpty) return result;
      } catch (_) {
        // 脚本失败时继续尝试内置回退。
      }
    }
    return _builtinLyric(track);
  }

  /// 获取封面（搜索自带封面 / 脚本 pic action / 内置平台原生实现）。
  ///
  /// 平台搜索响应已带封面（wy/tx/mg）时直接复用；否则脚本 pic 优先，
  /// 再回退内置实现（kw/kg 取图接口、wy 歌曲详情、tx 专辑 mid 拼 URL、
  /// mg 资源封面）。
  Future<String?> fetchPic(SourceTrack track) async {
    if (AnyListenSource.isAnyListenTrack(track)) {
      try {
        return await _anyListenSource.fetchPic(track);
      } catch (_) {
        return null;
      }
    }
    final existing = track.coverUrl;
    if (existing != null && existing.isNotEmpty) return existing;
    final decl = _activeSources[track.sourceKey];
    if (decl != null && decl.canFetchPic) {
      try {
        final url = await _engine.getPic(
          source: track.sourceKey,
          musicInfo: track.raw,
        );
        if (url.isNotEmpty) return url;
      } catch (_) {
        // 脚本失败时继续尝试内置回退。
      }
    }
    return _builtinPic(track);
  }

  /// 内置平台原生歌词回退（不支持 / 失败返回 null）。
  Future<LxLyricResult?> _builtinLyric(SourceTrack track) async {
    if (!BuiltinSearch.isBuiltin(track.sourceKey)) return null;
    try {
      return await _builtinLyricCache.getOrCreate<LxLyricResult?>(
          '${track.id}:lyric', () async {
        final info = await _fetchBuiltinLyric(track);
        if (info == null || info.isEmpty) return null;
        return LxLyricResult(
          lyric: info.lyric,
          tlyric: _nonEmpty(info.tlyric),
          rlyric: _nonEmpty(info.rlyric),
          lxlyric: _nonEmpty(info.lxlyric),
        );
      });
    } catch (_) {
      return null;
    }
  }

  /// 内置平台原生封面回退（不支持 / 失败返回 null）。
  Future<String?> _builtinPic(SourceTrack track) async {
    if (!BuiltinSearch.isBuiltin(track.sourceKey)) return null;
    try {
      return await _builtinPicCache.getOrCreate<String?>(
          '${track.id}:pic', () => _fetchBuiltinPic(track));
    } catch (_) {
      return null;
    }
  }

  /// 派发到各内置平台的原生取词实现。
  static Future<BuiltinLyricResult?> _fetchBuiltinLyric(
    SourceTrack track,
  ) {
    final raw = track.raw;
    switch (track.sourceKey) {
      case 'wy':
        final songId = raw['songmid'] ?? raw['id'];
        if (songId == null) return Future.value(null);
        return WyLyric.fetch(songId.toString()).then(
          (info) => BuiltinLyricResult(
            lyric: info.lyric,
            tlyric: _nonEmpty(info.tlyric),
            rlyric: _nonEmpty(info.rlyric),
            lxlyric: _nonEmpty(info.lxlyric),
          ),
        );
      case 'tx':
        return TxLyric.fetch(
          songId: raw['songId']?.toString(),
          songMid: raw['songmid']?.toString(),
        );
      case 'kg':
        final hash = raw['hash']?.toString();
        final name = raw['name']?.toString();
        if (hash == null || hash.isEmpty || name == null || name.isEmpty) {
          return Future.value(null);
        }
        return KgLyric.fetch(
          name: name,
          hash: hash,
          timelengthSeconds: _intervalSecondsOf(raw),
        );
      case 'kw':
        final songmid = raw['songmid']?.toString();
        if (songmid == null || songmid.isEmpty) return Future.value(null);
        return KwLyric.fetch(songmid);
      case 'mg':
        return MgLyric.fetch(
          songId: raw['songmid']?.toString(),
          mrcUrl: raw['mrcUrl']?.toString(),
          lrcUrl: raw['lrcUrl']?.toString(),
          trcUrl: raw['trcUrl']?.toString(),
        );
      default:
        return Future.value(null);
    }
  }

  /// 派发到各内置平台的原生取图实现。
  static Future<String?> _fetchBuiltinPic(SourceTrack track) {
    final raw = track.raw;
    switch (track.sourceKey) {
      case 'wy':
        final songId = raw['songmid'] ?? raw['id'];
        if (songId == null) return Future.value(null);
        return WyMusicDetail.getList([songId]).then(
          (list) => list.isEmpty ? null : list.first.coverUrl,
        );
      case 'tx':
        final albumMid = (raw['albumMid'] ?? raw['albumId'])?.toString();
        if (albumMid != null && albumMid.isNotEmpty && albumMid != '空') {
          return Future.value(
            'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg',
          );
        }
        return Future.value(null);
      case 'kg':
        return KgPic.fetch(
          songmid: raw['songmid']?.toString() ?? '',
          audioId: raw['audioId']?.toString(),
          albumId: raw['albumId']?.toString(),
          hash: raw['hash']?.toString(),
          name: raw['name']?.toString(),
          singer: raw['singer']?.toString(),
        );
      case 'kw':
        return KwPic.fetch(raw['songmid']?.toString() ?? '');
      case 'mg':
        final img = raw['img']?.toString();
        if (img != null && img.isNotEmpty) return Future.value(img);
        final songId = raw['songmid']?.toString();
        if (songId == null || songId.isEmpty) return Future.value(null);
        return MgLyric.coverOf(songId);
      default:
        return Future.value(null);
    }
  }

  /// 曲目时长（秒）：优先 `_interval`，否则解析 `mm:ss` 文本。
  static int _intervalSecondsOf(Map<String, dynamic> raw) {
    final rawInterval = raw['_interval'];
    if (rawInterval is num) return rawInterval.toInt();
    if (rawInterval is String) {
      final parsed = int.tryParse(rawInterval);
      if (parsed != null) return parsed;
    }
    final interval = raw['interval']?.toString() ?? '';
    final match = RegExp(r'^(\d{1,3}):(\d{2})').firstMatch(interval);
    if (match == null) return 0;
    return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// 运行期 `updateAlert` 上报的更新地址记入当前激活脚本。
  Future<void> _recordUpdateUrl(LxUpdateAlert alert) async {
    final url = alert.updateUrl?.trim();
    if (url == null || url.isEmpty) return;
    final active = repository.activeScript;
    if (active == null || active.updateUrl == url) return;
    try {
      await repository.replace(active.id, active.copyWith(updateUrl: url));
      notifyListeners();
    } catch (e) {
      debugPrint('[SourceManager] 记录更新地址失败: $e');
    }
  }

  LxScriptInfo _scriptById(String id) {
    final script = repository.scripts.where((s) => s.id == id).firstOrNull;
    if (script == null) {
      throw const ScriptUpdateException(
          ScriptUpdateError.scriptNotFound, '音源脚本不存在或已被删除');
    }
    return script;
  }

  /// 检查脚本是否有在线更新（下载 [LxScriptInfo.updateUrl] 并与本地对比）。
  ///
  /// 判定规则：版本号不同即视为有更新；版本号相同（含都为空）再比较脚本
  /// 内容 hash，内容变化同样视为有更新。无 updateUrl、下载失败、内容非法
  /// 时抛可读的 [ScriptUpdateException]。
  Future<ScriptUpdateCheck> checkScriptUpdate(String id) async {
    final current = _scriptById(id);
    final url = current.updateUrl?.trim();
    if (url == null || url.isEmpty) {
      throw const ScriptUpdateException(
          ScriptUpdateError.noUpdateUrl, '该音源未提供更新地址，请手动导入新版本');
    }
    final text = await downloadLxScriptText(url);
    final latest = parseDownloadedScript(text, id: current.id);
    final hasUpdate = latest.version != current.version ||
        _scriptHash(latest.script) != _scriptHash(current.script);
    return ScriptUpdateCheck(
      hasUpdate: hasUpdate,
      currentVersion: current.version,
      latestVersion: latest.version,
      latestScript: latest,
    );
  }

  /// 应用在线更新：下载最新脚本并原地替换（保留 id / 导入时间 / 激活态）。
  ///
  /// 传入 [check] 可复用 [checkScriptUpdate] 已下载的结果，避免重复下载。
  /// 若该脚本正在激活中，替换后重新激活（引擎重放新脚本并刷新
  /// [activeSources]）。
  Future<LxScriptInfo> applyScriptUpdate(
    String id, {
    ScriptUpdateCheck? check,
  }) async {
    _scriptById(id);
    final result = check ?? await checkScriptUpdate(id);
    final replaced = await repository.replace(id, result.latestScript);
    if (repository.activeId == id && !kIsWeb) {
      await activate(id);
    } else {
      notifyListeners();
    }
    return replaced;
  }

  static String _scriptHash(String script) =>
      md5.convert(utf8.encode(script)).toString();

  void clearUpdateAlert() {
    _lastUpdateAlert = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _anyListenSource.dispose();
    _engine.onStateChanged = null;
    _engine.close();
    super.dispose();
  }
}
