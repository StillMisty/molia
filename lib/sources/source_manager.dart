import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import 'any_listen/any_listen_config.dart';
import 'any_listen/any_listen_errors.dart';
import 'any_listen/any_listen_source.dart';
import 'builtin/album_source.dart';
import 'builtin/artist_source.dart';
import 'builtin/builtin_lyric_dispatch.dart';
import 'builtin/builtin_pic_dispatch.dart';
import 'builtin/builtin_platforms.dart';
import 'builtin/builtin_search.dart';
import 'builtin/comment_source.dart';
import 'builtin/lyric_hit.dart';
import 'builtin/lyric_search.dart';
import 'lx/lx_engine_supervisor.dart';
import 'lx/lx_engine_types.dart';
import 'lx/lx_script_info.dart';
import 'lx/lx_script_repository.dart';
import 'lx/lx_script_update.dart';
import 'lx/lx_search_parse.dart';
import 'source_preferences.dart';
import 'source_profiles.dart';
import 'source_search_result.dart';
import 'source_track.dart';
import '../domain/models/album.dart';
import '../domain/models/artist.dart';
import '../domain/models/comment.dart';
import '../domain/models/failure.dart';
import '../domain/models/source.dart' show SourceCapabilities, SourceDescriptor;
import '../domain/ports/music_source.dart' show PlayableStream;

// UI（音源页）白名单仅允许直连 source_manager，这里把在线更新流程的
// 返回/异常类型随管理器一起导出，避免扩大分层豁免。
export 'lx/lx_engine_types.dart' show LxEngineException;
export 'lx/lx_script_update.dart'
    show ScriptUpdateCheck, ScriptUpdateError, ScriptUpdateException;
// SourceKind 搬到 sources/source_profiles.dart（画像模块的唯一事实），
// 这里 re-export 保持既有 import 路径与调用方不变。
export 'source_profiles.dart' show SourceKind, SourceProfile, SourceProfiles;

/// 音源管理器：
/// - 管理已导入的 LX 音源脚本（导入 / 删除 / 激活）；
/// - 聚合内置平台搜索、脚本扩展搜索与 any-listen 远程音源；
/// - 统一对外提供取链 / 歌词 / 封面能力。
///
/// 该抽象与 any-listen 的接入隔离：上层只依赖 [SourceManager] 的
/// search / resolveStream / fetchLyric / fetchPic 能力；any-listen 通过
/// [AnyListenSource] 适配为 [SourceKind.anyListen]。仅当「已配置且启用」
/// 时才出现在 [searchableSources]，未配置/连接失败时对现有功能零影响。
class SourceManager extends ChangeNotifier {
  final LxScriptRepository repository = LxScriptRepository();

  /// 引擎自愈包装：超时/isolate 退出后自动按退避重启。
  /// 构造参数仅用于测试注入（默认创建真实 supervisor，行为不变）。
  final LxEngineSupervisor _engine;
  final SettingsAccess _settings;
  final AnyListenSource _anyListenSource;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 渠道偏好（音质 / 顺序 / 停用）的唯一持有者；变化经本类转发给 UI。
  late final SourcePreferences _preferences;

  /// 内置平台原生歌词回退（脚本不可用 / 未声明 lyric action 时的 Dart 实现）。
  final BuiltinLyricDispatch _builtinLyricFallback = BuiltinLyricDispatch();

  /// 内置平台原生封面回退（同上）。
  final BuiltinPicDispatch _builtinPicFallback = BuiltinPicDispatch();

  SourceManager({LxEngineSupervisor? engine, required SettingsAccess settings})
      : _engine = engine ?? LxEngineSupervisor(),
        _settings = settings,
        _anyListenSource = AnyListenSource(settings: settings) {
    _preferences = SourcePreferences(_settings)..addListener(notifyListeners);
    _engine.onStateChanged = _onEngineStateChanged;
    // 应用远端设置后的定向重载：渠道偏好（自绑于 SourcePreferences）/
    // any-listen 连接。
    _settings.bindReload(kAnyListenServerUrl, reloadAnyListenConfig);
    _settings.bindReload(kAnyListenToken, reloadAnyListenConfig);
    _settings.bindReload(kAnyListenEnabled, reloadAnyListenConfig);
  }

  bool _initialized = false;
  String? _activatingId;
  String? _activeError;
  Map<String, LxSourceDecl> _activeSources = {};
  LxUpdateAlert? _lastUpdateAlert;

  bool get initialized => _initialized;
  bool get isActivating => _activatingId != null;
  String? get activeError => _activeError;
  Map<String, LxSourceDecl> get activeSources =>
      Map.unmodifiable(_activeSources);
  List<LxScriptInfo> get scripts => repository.scripts;
  LxScriptInfo? get activeScript => repository.activeScript;
  bool get engineReady => _engine.isRunning;
  String get preferredQuality => _preferences.preferredQuality;
  LxUpdateAlert? get lastUpdateAlert => _lastUpdateAlert;

  /// 用户自定义的渠道顺序（持久化于 shared_preferences；同时决定渠道路由
  /// 之外的展示顺序与搜索音源顺序）。
  List<String> get sourceOrder => _preferences.sourceOrder;

  /// 已停用的渠道集合（持久化；停用只影响列表/选择，不影响已保存曲目的取链）。
  Set<String> get disabledChannels => _preferences.disabledChannels;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  bool get hasActiveSource => _engine.isRunning && _activeSources.isNotEmpty;

  /// any-listen 适配器（搜索 / 取链 / 歌词 / 封面 / 连接测试）。
  AnyListenSource get anyListenSource => _anyListenSource;

  /// 供连接测试用的独立适配器：复用本管理器的按键作用域，不另建注册表。
  ///
  /// 页面可独立打开探测表单值，不要求先 `init()`；配置存取路径用不到，
  /// 但构造仍要求一个合法的设置来源。
  AnyListenSource createProbeSource() => AnyListenSource(settings: _settings);

  /// any-listen 当前配置。
  AnyListenConfig get anyListenConfig => _anyListenSource.config;

  /// any-listen 是否「已配置且启用」；只有此时才出现在 [searchableSources]。
  bool get anyListenAvailable => _anyListenSource.isUsable;

  /// 当前音源画像快照（渠道 / 能力 / 可见性的唯一事实）。
  ///
  /// 每次读取按当前激活脚本、any-listen 配置与渠道偏好重建；个位数条目，
  /// 不做缓存就没有失效逻辑，也不会出现「能力位更新了、渠道没更新」。
  SourceProfiles get sourceProfiles => SourceProfiles.build(
        activeSources: _activeSources,
        anyListenUsable: _anyListenSource.isUsable,
        disabledChannels: _preferences.disabledChannels,
        sourceOrder: _preferences.sourceOrder,
      );

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序排列）。
  ///
  /// 资料页的渠道选择与「音源管理」的渠道排序都消费该列表；脚本扩展源 /
  /// any-listen 只有搜索能力，内置发现平台无论是否有脚本都保留发现入口。
  List<SourceDescriptor> get channels {
    final profiles = sourceProfiles.channels;
    return [
      for (var index = 0; index < profiles.length; index++)
        profiles[index].toDescriptor(order: index),
    ];
  }

  /// 可供搜索/播放的音源列表（仅启用项；按用户自定义顺序排列）。
  List<SourceDescriptor> get searchableSources {
    final profiles = sourceProfiles.searchable;
    return [
      for (var index = 0; index < profiles.length; index++)
        profiles[index].toDescriptor(order: index),
    ];
  }

  /// 音源能力：直接读 [SourceProfiles]（registry / 领域适配器共用同一答案）。
  SourceCapabilities capabilitiesFor(String key) =>
      sourceProfiles.forKey(key)?.capabilities ?? const SourceCapabilities();

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
    await _preferences.load();
    // 只读本地配置，不发起网络请求；失败时 AnyListenSource 维持默认（未配置）。
    await _anyListenSource.init();

    _subscriptions.add(
      _engine.logs.listen((entry) {
        if (kDebugMode) debugPrint('[LX:${entry.level}] ${entry.message}');
      }),
    );
    _subscriptions.add(
      _engine.updateAlerts.listen((alert) {
        _lastUpdateAlert = alert;
        // 运行期上报的更新地址记入当前激活脚本，供「立即更新」使用。
        unawaited(_recordUpdateUrl(alert));
        notifyListeners();
      }),
    );

    _initialized = true;
    notifyListeners();

    final activeId = repository.activeId;
    if (activeId != null) {
      try {
        await activate(activeId);
      } catch (_) {
        // 激活失败时保留错误信息供 UI 展示
      }
    }
  }

  /// 重新读取渠道偏好（顺序 / 停用 / 音质）。跨设备同步应用远端设置后由
  /// 组合根经 [SettingsRegistry.bindReload] 触发；先重置为默认再加载，
  /// 保证远端「清空」也能生效。状态与重载实现见 [SourcePreferences]。
  Future<void> reloadPreferences() => _preferences.reload();

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

  Future<void> setPreferredQuality(String quality) =>
      _preferences.setPreferredQuality(quality);

  /// 覆盖音源顺序（去重后持久化）。
  Future<void> setSourceOrder(List<String> keys) =>
      _preferences.setSourceOrder(keys);

  /// 拖拽排序：把渠道列表（含内置发现平台；停用项同样参与排序）第
  /// [oldIndex] 项移动到 [newIndex]。
  ///
  /// [newIndex] 是 `ReorderableListView.onReorderItem` 语义（已按「移除
  /// oldIndex 后」校正），直接按下标搬移。
  Future<void> reorderChannel(int oldIndex, int newIndex) async {
    final keys = channels.map((o) => o.key).toList();
    if (oldIndex < 0 || oldIndex >= keys.length) return;
    final target = newIndex.clamp(0, keys.length - 1);
    if (target == oldIndex) return;
    final moved = keys.removeAt(oldIndex);
    keys.insert(target, moved);
    await setSourceOrder(keys);
  }

  /// 启用 / 停用渠道（持久化）。停用后该渠道不再出现在资料页渠道选择
  /// 与搜索结果中；已保存内容仍可通过内部路由取链播放。
  Future<void> setChannelEnabled(String key, bool enabled) =>
      _preferences.setChannelEnabled(key, enabled);

  /// 本机脚本写入钩子（组合根接线：同步层立即登记并追加增量日志）。
  ///
  /// 只在**本机**导入 / 更新 / 删除脚本时触发；应用远端脚本走仓库层，
  /// 不经过这些方法。
  void Function(String id)? onScriptWritten;
  void Function(String id)? onScriptRemoved;

  /// 清空自定义渠道顺序，恢复「脚本音源在前、内置平台在后」的默认排序。
  Future<void> resetChannelOrder() => _preferences.resetChannelOrder();

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
  Future<LxScriptInfo> importScript(
    String script, {
    bool activate = false,
  }) async {
    final info = LxScriptInfo.parse(script);
    if (info == null) {
      throw const FormatException('无法解析音源脚本：缺少以 /** @name ... */ 开头的元信息');
    }
    await repository.add(info);
    onScriptWritten?.call(info.id);
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
    onScriptRemoved?.call(id);
    if (repository.activeId == null) {
      await _engine.dispose();
      _activeSources = {};
    }
    notifyListeners();
  }

  /// 分页搜索。内置平台走 Dart 移植的搜索接口，脚本自定义源走脚本扩展 action。
  ///
  /// 返回 [SourceSearchResult]，携带 hasMore（由平台总数或本页结果推断）与
  /// total（平台返回时才有）。脚本扩展搜索的返回格式为社区约定，字段兼容性
  /// 尽力而为：优先识别 isEnd / hasMore / total，否则用 tracks.length >= limit 近似。
  ///
  /// 内置平台的失败语义：`failure` 非空表示失败（区分「平台返回空」，
  /// 见 `builtin_search_runner.dart`）。
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
    if (BuiltinPlatforms.isSupported(sourceKey)) {
      // 搜索门直接读画像（与能力位同一事实）：能力位为 false 时这里必然
      // 拒绝，避免 UI 显示可搜索但路由报错。
      if (sourceProfiles.forKey(sourceKey)?.searchable != true) {
        throw LxEngineException(
          '当前环境不支持 ${BuiltinPlatforms.displayName(sourceKey)} 的搜索与播放',
        );
      }
      return BuiltinSearch.searchWithMeta(
        sourceKey,
        keyword,
        page: page,
        limit: limit,
      );
    }
    if (decl == null) {
      throw LxEngineException('未知音源: $sourceKey');
    }
    if (!decl.canSearch) {
      throw LxEngineException('音源「${decl.name}」不支持搜索');
    }
    final action =
        decl.actions.contains('musicSearch') ? 'musicSearch' : 'search';
    final data = await _engine.search(
      source: sourceKey,
      action: action,
      keyword: keyword,
      page: page,
      limit: limit,
    );
    return parseLxSearchResult(sourceKey, data, page: page, limit: limit);
  }

  /// 解析播放流。requestedQuality 为空时使用默认音质偏好。
  ///
  /// 返回 [PlayableStream] 而不是 URL 字符串：B 站等平台的音频直链需要
  /// `Referer` / `User-Agent`，这些请求头必须一路透传到播放器、边播边缓存
  /// 与后台缓存写入；提前降级成 String 就会丢掉头部。any-listen / LX 脚本
  /// 目前只返回 URL（headers 为空），后续原生解析器可直接返回带头的流。
  Future<PlayableStream> resolveStream(
    SourceTrack track, {
    String? requestedQuality,
  }) async {
    // any-listen 曲目走远程服务器取链；其余曲目走 LX 脚本取链。
    if (AnyListenSource.isAnyListenTrack(track)) {
      try {
        final url = await _anyListenSource.resolveUrl(
          track,
          requestedQuality: requestedQuality,
        );
        return PlayableStream(Uri.parse(url));
      } on AnyListenException catch (e) {
        throw e.toSourceFailure();
      }
    }
    final picked = track.pickQuality(
      requestedQuality ?? _preferences.preferredQuality,
    );
    // 原生取链优先：B 站等平台的搜索与播放不依赖脚本，走注册表里的解析器
    // 才能保留直链要求的 headers / 有效期。
    final nativeResolve = BuiltinPlatforms.resolveFor(track.sourceKey);
    if (nativeResolve != null) {
      try {
        return await nativeResolve(track.raw, quality: picked);
      } catch (e) {
        throw SourceFailure.from(e);
      }
    }
    final decl = _activeSources[track.sourceKey];
    if (decl == null) {
      throw LxEngineException('音源 ${track.sourceKey} 当前不可用');
    }
    if (!decl.canResolveUrl) {
      throw LxEngineException('音源「${decl.name}」不支持获取播放地址');
    }
    final musicInfo = _withPickedHash(track, picked);
    final url = await _engine.getMusicUrl(
      source: track.sourceKey,
      musicInfo: musicInfo,
      quality: picked,
    );
    return PlayableStream(Uri.parse(url));
  }

  /// 酷狗等平台不同音质对应不同 hash，取链前替换为所选音质的 hash。
  Map<String, dynamic> _withPickedHash(SourceTrack track, String quality) {
    final info = Map<String, dynamic>.from(track.raw);
    final qualityInfo =
        track.qualities.where((q) => q.type == quality).firstOrNull;
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
    return _builtinLyricFallback.fetch(track);
  }

  /// 清掉某平台的原生取词缓存（B 站扫码登录后调用）。
  ///
  /// `BuiltinLyricDispatch` 会缓存 null 5 分钟；登录态从无到有时必须清掉，
  /// 否则当前曲目仍会走跨平台回退。
  void invalidateLyricCacheFor(String sourceKey) {
    _builtinLyricFallback.invalidateSource(sourceKey);
  }

  /// 获取曲目评论（内置平台；脚本扩展源 / any-listen 无评论能力）。
  ///
  /// 失败统一归一化为 [SourceFailure]（业务拒绝 → unknown/retryable，
  /// 传输失败 → network）；分页与缓存由 data 层 `CommentsService` 承担。
  Future<CommentPage> fetchComments(
    SourceTrack track, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    // 能力位与注册表适配器同源：profile.comment 为真必然有评论适配器。
    if (!capabilitiesFor(track.sourceKey).comment) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 ${track.sourceKey} 不支持评论',
      );
    }
    try {
      return await BuiltinComments.fetch(
        track.sourceKey,
        track.raw,
        kind: kind,
        page: page,
        limit: limit,
      );
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 获取专辑（内置五平台；脚本扩展源 / any-listen 无专辑能力）。
  ///
  /// [albumId] 为平台内专辑 id（wy 数字 id / tx albumMid / kg/kw/mg albumId，
  /// 取自曲目 payload 的 `albumId` / `albumMid` 原样字段）。失败统一归一化为
  /// [SourceFailure]；分页与缓存由 data 层 `AlbumService` 承担。
  Future<Album> fetchAlbum(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    if (!capabilitiesFor(sourceKey).collection) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持专辑',
      );
    }
    try {
      return await BuiltinAlbums.fetch(
        sourceKey,
        albumId,
        page: page,
        limit: limit,
      );
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 获取歌手详情 + 一页歌手歌曲（内置平台；脚本扩展源 / any-listen 无歌手能力）。
  ///
  /// [artistId] 为平台内歌手 id（与曲目 payload 的歌手引用同体系；取自
  /// `_artists` 字段）。失败统一归一化为 [SourceFailure]；分页与缓存由
  /// data 层 `ArtistService` 承担。
  Future<ArtistDetail> fetchArtist(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    // 详情路由只看适配器：画像的 `artist` 还叠了搜索门（UI 入口），但已保存
    // 曲目的歌手 id 在无激活脚本时仍可直接取详情（与迁移前一致）。
    if (BuiltinPlatforms.artistFor(sourceKey) == null) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌手',
      );
    }
    try {
      return await BuiltinArtists.fetch(
        sourceKey,
        artistId,
        page: page,
        limit: limit,
      );
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 歌手搜索（内置平台；搜索页「歌手」类型）。
  ///
  /// 能力位与单曲搜索同门（画像里的 `artist` 只在搜索路由可用时为真）；
  /// 失败归一化为 [SourceFailure]，不静默吞成空结果。
  Future<ArtistSearchPage> searchArtists(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (sourceProfiles.forKey(sourceKey)?.capabilities.artist != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌手搜索',
      );
    }
    try {
      return await BuiltinArtists.search(
        sourceKey,
        keyword,
        page: page,
        limit: limit,
      );
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 按歌词搜歌（内置五平台；脚本扩展源 / any-listen 无此能力）。
  ///
  /// 失败归一化为 [SourceFailure]；分页与缓存由 data 层（CatalogService）
  /// 承担。平台差异（kw 模糊匹配 / mg 排序偏翻唱）见各 `*_lyric_search.dart`。
  Future<LyricSearchPage> searchLyrics(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (sourceProfiles.forKey(sourceKey)?.capabilities.lyricSearch != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌词搜索',
      );
    }
    try {
      return await BuiltinLyricSearch.searchWithMeta(
        sourceKey,
        keyword,
        page: page,
        limit: limit,
      );
    } catch (e) {
      throw SourceFailure.from(e);
    }
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
    return _builtinPicFallback.fetch(track);
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
        ScriptUpdateError.scriptNotFound,
        '音源脚本不存在或已被删除',
      );
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
        ScriptUpdateError.noUpdateUrl,
        '该音源未提供更新地址，请手动导入新版本',
      );
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
    onScriptWritten?.call(id);
    if (repository.activeId == id) {
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
    _preferences.removeListener(notifyListeners);
    _preferences.dispose();
    _anyListenSource.dispose();
    _engine.onStateChanged = null;
    _engine.close();
    super.dispose();
  }
}
