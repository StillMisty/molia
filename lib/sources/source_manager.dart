import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/settings/settings_access.dart';
import 'any_listen/any_listen_config.dart';
import 'any_listen/any_listen_errors.dart';
import 'any_listen/any_listen_source.dart';
import 'builtin/album_source.dart';
import 'builtin/artist_source.dart';
import 'builtin/builtin_lyric_dispatch.dart';
import 'builtin/builtin_pic_dispatch.dart';
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
import 'source_routing.dart';
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
// SourceKind 定义在 sources/source_profiles.dart（画像模块的唯一事实），
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

  SourceManager({
    LxEngineSupervisor? engine,
    required SettingsAccess settings,
    List<Duration> activationRetryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 20),
    ],
    Duration lazyActivationCooldown = const Duration(seconds: 5),
  }) : _engine = engine ?? LxEngineSupervisor(),
       _settings = settings,
       _anyListenSource = AnyListenSource(settings: settings),
       _activationRetryDelays = List<Duration>.unmodifiable(
         activationRetryDelays,
       ),
       // 公开参数名保持 lazyActivationCooldown（测试注入短冷却要能具名传参），
       // 字段按本类惯例私有。
       // ignore: prefer_initializing_formals
       _lazyActivationCooldown = lazyActivationCooldown {
    _preferences = SourcePreferences(_settings)..addListener(notifyListeners);
    _engine.onStateChanged = _onEngineStateChanged;
  }

  /// 启动激活失败的延迟重试间隔（次数 = 长度）。生产默认 5s / 20s；
  /// 测试注入短间隔，不等待真实秒级定时器。
  final List<Duration> _activationRetryDelays;

  /// 惰性激活（首次使用触发）的冷却：失败后短时间内不重复重跑脚本。
  final Duration _lazyActivationCooldown;

  bool _initialized = false;
  String? _activatingId;
  String? _activeError;
  Map<String, LxSourceDecl> _activeSources = {};
  LxUpdateAlert? _lastUpdateAlert;

  /// 启动激活失败的延迟重试计时器（用户主动停用 / 激活成功即取消）。
  Timer? _activationRetryTimer;
  int _activationRetryAttempt = 0;

  /// 最近一次惰性激活的尝试时刻（限流用；见 [_ensureActiveScript]）。
  DateTime? _lastLazyActivationAt;

  /// 在途的 [retryEngine]（连点「重试」/ 网络事件连发时合并成一次）。
  Future<bool>? _retryEngineInFlight;

  bool get initialized => _initialized;
  bool get isActivating => _activatingId != null;
  String? get activeError => _activeError;
  Map<String, LxSourceDecl> get activeSources =>
      Map.unmodifiable(_activeSources);
  List<LxScriptInfo> get scripts => repository.scripts;
  LxScriptInfo? get activeScript => repository.activeScript;
  bool get engineReady => _engine.isRunning;

  /// 引擎是否处于「已停止、等冷却后半开恢复」状态（网络恢复触发读这里）。
  bool get engineFailed => _engine.isFailed;

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
  List<SourceDescriptor> get channels =>
      sourceProfiles.channels.toDescriptors();

  /// 可供搜索/播放的音源列表（仅启用项；按用户自定义顺序排列）。
  List<SourceDescriptor> get searchableSources =>
      sourceProfiles.searchable.toDescriptors();

  /// 音源能力：直接读 [SourceProfiles]（registry / 领域适配器共用同一答案）。
  SourceCapabilities capabilitiesFor(String key) =>
      sourceProfiles.forKey(key)?.capabilities ?? const SourceCapabilities();

  /// 当前快照的能力路由：画像 + 激活脚本声明，管理器不再自己分支。
  SourceRouting routingOf(SourceProfiles profiles) =>
      SourceRouting(profiles: profiles, declarations: _activeSources);

  /// 脚本源的惰性激活入口。
  ///
  /// 只有画像里「不是内置 / any-listen」的 key 才可能靠脚本恢复：内置渠道
  /// 的原生能力不依赖脚本（脚本只做覆盖），any-listen 走自己的配置。
  /// 这与旧实现的 `!SongChannels.isSupported(key)` 判定同义，但现在读的是
  /// 画像的身份，不再查平台 key。
  Future<void> _ensureScriptFor(String key, SourceProfiles profiles) async {
    final profile = profiles.forKey(key);
    if (profile == null || profile.kind == SourceKind.lx) {
      await _ensureActiveScript(key);
    }
  }

  /// 路由不可用 → 与既有实现一致的错误（未知 / 无实现 / 能力门关闭）。
  Never _throwUnavailable(UnavailableSourceRoute route) {
    switch (route.capability) {
      case SourceCapability.search:
        if (route.reason == SourceUnavailableReason.searchGateClosed) {
          throw LxEngineException(
            '当前环境不支持 ${route.profile.displayName} 的搜索与播放',
          );
        }
        if (route.reason == SourceUnavailableReason.unknownSource) {
          throw LxEngineException('未知音源: ${route.key}');
        }
        final name = route.declaration?.name ?? route.profile.displayName;
        throw LxEngineException('音源「$name」不支持搜索');
      case SourceCapability.resolve:
        if (route.reason == SourceUnavailableReason.unknownSource ||
            route.declaration == null) {
          // 内置渠道没有原生取链、也没有脚本声明：与旧实现的脚本分支
          // 一样按「该 key 当前不可用」上报（不冒充「平台不支持」）。
          throw LxEngineException('音源 ${route.key} 当前不可用');
        }
        throw LxEngineException('音源「${route.declaration!.name}」不支持获取播放地址');
      case SourceCapability.lyric:
      case SourceCapability.picture:
        // 歌词 / 封面契约允许失败：无实现时返回 null 由调用方回退。
        throw StateError('歌词 / 封面不可用时不应走到错误分支');
      case SourceCapability.comments:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '音源 ${route.key} 不支持评论',
        );
      case SourceCapability.album:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '音源 ${route.key} 不支持专辑',
        );
      case SourceCapability.artist:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '音源 ${route.key} 不支持歌手',
        );
      case SourceCapability.lyricSearch:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '音源 ${route.key} 不支持歌词搜索',
        );
    }
  }

  /// 路由第一条路线是否能执行；不可用路线直接按能力给出既有错误。
  SourceRoute _primaryRoute(
    SourceProfiles profiles,
    String key,
    SourceCapability capability,
  ) {
    final route = routingOf(profiles).primaryFor(key, capability);
    if (route == null || route is UnavailableSourceRoute) {
      _throwUnavailable(
        route is UnavailableSourceRoute
            ? route
            : UnavailableSourceRoute(
                key: key,
                capability: capability,
                profile:
                    profiles.forKey(key) ??
                    SourceProfile(
                      key: key,
                      displayName: key,
                      kind: SourceKind.lx,
                      capabilities: const SourceCapabilities(),
                    ),
                reason: SourceUnavailableReason.unknownSource,
              ),
      );
    }
    return route;
  }

  /// supervisor 状态回调：重启 / 半开恢复成功后用引擎当前声明的源刷新
  /// [activeSources]，修复“引擎死了源列表还在”（超时 kill 后脚本重新执行，
  /// 声明可能变化）；进入 failed 时把失败原因写进 [activeError]，
  /// 让音源页立刻出现「重试」入口（不必等下一次取链失败）。
  void _onEngineStateChanged(LxEngineState state) {
    switch (state) {
      case LxEngineState.ready:
        _activeSources = Map<String, LxSourceDecl>.from(_engine.sources);
        _activeError = null;
      case LxEngineState.failed:
        // 不清 _activeSources：惰性激活只在“该源没有声明”时触发，留着声明
        // 才能让 failed 的冷却由 supervisor 统一裁决（而不是每次请求都跑脚本）。
        _activeError = _engine.failureReason ?? '音源引擎已停止';
      case LxEngineState.stopped:
      case LxEngineState.starting:
      case LxEngineState.restarting:
        return;
    }
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
        // 激活失败保留错误信息供 UI 展示（activate 已写入 _activeError），
        // 并安排延迟重试：启动阶段的脚本加载 / 网络抖动不该让音源一直不可用。
        _scheduleActivationRetry(activeId);
      }
    }
  }

  /// 重新读取渠道偏好（顺序 / 停用 / 音质）。跨设备同步应用远端设置后由
  /// 组合根挂载的 reload 触发；先重置为默认再加载，
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
    _cancelActivationRetry();
    _activatingId = id;
    _activeError = null;
    notifyListeners();
    try {
      final sources = await _engine.start(script);
      _activeSources = sources;
      _activationRetryAttempt = 0;
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
  ///
  /// 这是用户的显式决定：取消待执行的激活重试并清掉错误提示，之后的惰性
  /// 激活（[_ensureActiveScript]）也不会再把脚本拉起来。
  Future<void> deactivate() async {
    _cancelActivationRetry();
    await _engine.dispose();
    _activeSources = {};
    _activeError = null;
    _activationRetryAttempt = 0;
    await repository.setActive(null);
    notifyListeners();
  }

  /// 安排一次延迟激活重试（[_activationRetryDelays] 用尽后不再重试）。
  void _scheduleActivationRetry(String id) {
    if (_activationRetryAttempt >= _activationRetryDelays.length) return;
    final delay = _activationRetryDelays[_activationRetryAttempt++];
    _activationRetryTimer?.cancel();
    _activationRetryTimer = Timer(delay, () {
      _activationRetryTimer = null;
      unawaited(_retryActivation(id));
    });
  }

  /// 延迟重试回调：用户已切换 / 停用脚本或另有激活在途时直接放弃。
  Future<void> _retryActivation(String id) async {
    if (!_initialized || _activatingId != null) return;
    if (repository.activeId != id) return;
    try {
      await activate(id);
    } catch (_) {
      // 失败仍写 _activeError；按剩余间隔继续重试。
      _scheduleActivationRetry(id);
    }
  }

  void _cancelActivationRetry() {
    _activationRetryTimer?.cancel();
    _activationRetryTimer = null;
  }

  /// 惰性激活兜底（脚本源的搜索 / 取链 / 歌词 / 封面入口调用）。
  ///
  /// 只有「用户保存了激活脚本、但引擎没跑起来」（启动激活失败、半开冷却中）
  /// 才补一次激活：没有激活脚本（`repository.activeScript == null`，含用户
  /// 主动停用）绝不自动拉起；引擎已就绪或该源已声明时无事可做。用
  /// [_lazyActivationCooldown] 限流，避免每次失败请求都重跑脚本
  /// （激活本身要几百毫秒到数秒）。
  Future<void> _ensureActiveScript(String sourceKey) async {
    if (_activeSources[sourceKey] != null) return;
    // 用 activeScript 而不是 activeId：脚本被删除 / 仓库里找不到时没有可
    // 重放的内容，不能每隔几秒撞一次「脚本不存在」。
    final activeScript = repository.activeScript;
    if (activeScript == null || _engine.isRunning || _activatingId != null) {
      return;
    }
    final now = DateTime.now();
    final lastAttempt = _lastLazyActivationAt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < _lazyActivationCooldown) {
      return;
    }
    _lastLazyActivationAt = now;
    try {
      await activate(activeScript.id);
    } catch (_) {
      // 失败已写入 _activeError（UI 展示 + 重试按钮），调用方按原路失败。
    }
  }

  /// 立即重试引擎恢复（音源页「重试」与网络恢复触发）。
  ///
  /// 绕过 supervisor 的半开冷却；成功时用引擎当前声明的源刷新
  /// [activeSources] 并清掉 [activeError]，失败保留可读原因。
  /// 无激活脚本 / 引擎已就绪时视为成功（没有可恢复的东西）。
  Future<bool> retryEngine() => _retryEngineInFlight ??= _retryEngine()
      .whenComplete(() => _retryEngineInFlight = null);

  Future<bool> _retryEngine() async {
    _cancelActivationRetry();
    _activationRetryAttempt = 0;
    final ok = await _engine.retryNow();
    if (ok) {
      _activeError = null;
      if (_engine.isRunning) {
        _activeSources = Map<String, LxSourceDecl>.from(_engine.sources);
      }
    } else {
      _activeError = _engine.failureReason ?? '音源引擎仍未恢复，请稍后重试';
    }
    notifyListeners();
    return ok;
  }

  Future<void> removeScript(String id) async {
    await repository.remove(id);
    onScriptRemoved?.call(id);
    if (repository.activeId == null) {
      // 脚本被删掉后没有可激活目标：连待执行的启动重试一起取消。
      _cancelActivationRetry();
      _activationRetryAttempt = 0;
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
    var profiles = sourceProfiles;
    // 脚本源首次使用：画像里没有声明时先补一次激活（内置 / any-listen 不触发）。
    await _ensureScriptFor(sourceKey, profiles);
    profiles = sourceProfiles;
    final route = _primaryRoute(profiles, sourceKey, SourceCapability.search);
    switch (route) {
      case AnyListenSourceRoute():
        try {
          return await _anyListenSource.search(
            keyword,
            page: page,
            limit: limit,
          );
        } on AnyListenException catch (e) {
          // 跨出 sources 层的唯一转换点：保留鉴权/连接失败的 kind 语义。
          throw e.toSourceFailure();
        }
      case BuiltinSourceRoute():
        return BuiltinSearch.searchWithMeta(
          sourceKey,
          keyword,
          page: page,
          limit: limit,
        );
      case ScriptSourceRoute():
        // 激活可能在上一步失败：声明不在时与旧实现一样按未知源上报。
        final decl = _activeSources[sourceKey];
        if (decl == null) {
          throw LxEngineException('未知音源: $sourceKey');
        }
        final action = decl.actions.contains('musicSearch')
            ? 'musicSearch'
            : 'search';
        final data = await _engine.search(
          source: sourceKey,
          action: action,
          keyword: keyword,
          page: page,
          limit: limit,
        );
        return parseLxSearchResult(sourceKey, data, page: page, limit: limit);
      case UnavailableSourceRoute():
        // _primaryRoute 已抛错，这里只让类型收窄可穷尽。
        _throwUnavailable(route);
    }
  }

  /// 解析播放流。requestedQuality 为空时使用默认音质偏好。
  ///
  /// 返回 [PlayableStream] 而不是 URL 字符串：B 站等平台的音频直链需要
  /// `Referer` / `User-Agent`，这些请求头必须一路透传到播放器、边播边缓存
  /// 与后台缓存写入；提前降级成 String 就会丢掉头部。any-listen / LX 脚本
  /// 目前只返回 URL（headers 为空），后续原生解析器可直接返回带头的流。
  ///
  /// LX 分支在「该档位没地址」（notFound / unsupported）时按
  /// [qualityFallbackCandidates] 降档重试（最多 2 档）；网络 / 超时 / 脚本
  /// 错误不降档——那是暂时故障，同档位重试才有意义（由 CatalogService 做）。
  ///
  /// [timeout] 是调用方的剩余预算：降档循环用它算 deadline，每档 `getMusicUrl`
  /// 的超时取 `min(20s, 剩余)`，剩余耗尽就停（不再发起下一档）。native /
  /// any-listen 分支不消费该参数，由调用方自己的截止时间兜底。
  ///
  /// 脚本源首次使用会先尝试惰性激活（启动激活失败 / 引擎 failed 时），
  /// 成功后再按正常流程取链。
  Future<PlayableStream> resolveStream(
    SourceTrack track, {
    String? requestedQuality,
    Duration? timeout,
  }) async {
    var profiles = sourceProfiles;
    // 脚本源（含内置渠道被脚本声明覆盖取链的情况）先尝试惰性恢复：
    // 内置渠道的原生取链不需要引擎，因此只有脚本路线才等待激活。
    await _ensureScriptFor(track.sourceKey, profiles);
    profiles = sourceProfiles;
    final route = _primaryRoute(
      profiles,
      track.sourceKey,
      SourceCapability.resolve,
    );
    if (route is AnyListenSourceRoute) {
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
    if (route is BuiltinSourceRoute) {
      final nativeResolve = route.channel.resolve;
      if (nativeResolve != null) {
        try {
          return await nativeResolve(track.raw, quality: picked);
        } catch (e) {
          throw SourceFailure.from(e);
        }
      }
    }
    if (route is! ScriptSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: track.sourceKey,
          capability: SourceCapability.resolve,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
      );
    }
    // 内置渠道的脚本取链：引擎没跑起来时补一次激活（与旧实现同一条路径）。
    await _ensureActiveScript(track.sourceKey);
    final decl = _activeSources[track.sourceKey];
    if (decl == null) {
      throw LxEngineException('音源 ${track.sourceKey} 当前不可用');
    }
    if (!decl.canResolveUrl) {
      throw LxEngineException('音源「${decl.name}」不支持获取播放地址');
    }
    final candidates = <String>[
      picked,
      ...qualityFallbackCandidates(
        track.qualities.map((quality) => quality.type),
        picked,
      ),
    ];
    final stopwatch = Stopwatch()..start();
    var index = 0;
    SourceFailure? lastFailure;
    while (true) {
      // 每档都用「剩余预算」压超时：引擎侧的 invoke 超时会被截到剩余时间，
      // 剩余耗尽就不发起下一档（避免一次取链吃掉 3×20s）。
      var qualityTimeout = _kLxResolveAttemptTimeout;
      if (timeout != null) {
        final remaining = timeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          // 没有上一档失败时（timeout 一开始就耗尽）按超时上报。
          throw lastFailure ??
              SourceFailure(
                kind: FailureKind.timeout,
                message: '取链超时：${timeout.inMilliseconds}ms 预算已用完',
                retryable: true,
              );
        }
        if (remaining < qualityTimeout) qualityTimeout = remaining;
      }
      final quality = candidates[index];
      try {
        final musicInfo = _withPickedHash(track, quality);
        final url = await _engine.getMusicUrl(
          source: track.sourceKey,
          musicInfo: musicInfo,
          quality: quality,
          timeout: qualityTimeout,
        );
        return PlayableStream(Uri.parse(url));
      } on Exception catch (e) {
        // 边界统一为 SourceFailure：调用方（适配器 / 目录）按 kind 决策。
        // 只归一化 Exception：编程错误（Error）继续冒泡，不伪装成音源失败。
        final failure = SourceFailure.from(e);
        lastFailure = failure;
        final canDowngrade =
            index < candidates.length - 1 && _canDowngradeQuality(failure);
        if (!canDowngrade) throw failure;
        index++;
      }
    }
  }

  /// 单档 LX 取链的默认超时（与引擎 `getMusicUrl` 默认值一致）；调用方给了
  /// 剩余预算时取更短者。
  static const Duration _kLxResolveAttemptTimeout = Duration(seconds: 20);

  /// 取链失败是否值得降档：只有「该档位没有地址」的语义才换档。
  ///
  /// 网络 / 超时 / 脚本错误是暂时故障，换档只会多花一次脚本调用；
  /// 这些交给 CatalogService 在同档位重试。
  static bool _canDowngradeQuality(SourceFailure failure) =>
      failure.kind == FailureKind.notFound ||
      failure.kind == FailureKind.unsupported;

  /// 酷狗等平台不同音质对应不同 hash，取链前替换为所选音质的 hash。
  Map<String, dynamic> _withPickedHash(SourceTrack track, String quality) {
    final info = Map<String, dynamic>.from(track.raw);
    final qualityInfo = track.qualities
        .where((q) => q.type == quality)
        .firstOrNull;
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
    var profiles = sourceProfiles;
    // 原生渠道不依赖脚本：脚本只做覆盖，因此不在歌词入口拉起引擎；
    // 纯脚本源 / 未知 key 才补一次惰性激活（与旧实现同一条路径）。
    await _ensureScriptFor(track.sourceKey, profiles);
    profiles = sourceProfiles;
    final routes = routingOf(profiles)
        .routesFor(track.sourceKey, SourceCapability.lyric);
    for (final route in routes) {
      switch (route) {
        case AnyListenSourceRoute():
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
        case ScriptSourceRoute():
          final decl = _activeSources[track.sourceKey];
          if (decl == null || !decl.canFetchLyric) continue;
          try {
            final result = await _engine.getLyric(
              source: track.sourceKey,
              musicInfo: track.raw,
            );
            if (result.lyric.trim().isNotEmpty) return result;
          } catch (_) {
            // 脚本失败时继续尝试内置回退。
          }
        case BuiltinSourceRoute():
          return _builtinLyricFallback.fetch(track);
        case UnavailableSourceRoute():
          continue;
      }
    }
    // 没有任何实现：旧实现的脚本分支也会落到内置回退（对非内置 key 返回
    // null），这里显式返回 null，语义相同。
    return null;
  }

  /// 清掉某平台的原生取词缓存（B 站扫码登录后调用）。
  ///
  /// `BuiltinLyricDispatch` 会缓存 null 5 分钟；登录态从无到有时必须清掉，
  /// 否则当前曲目仍会走跨平台回退。
  void invalidateLyricCacheFor(String sourceKey) {
    _builtinLyricFallback.invalidateSource(sourceKey);
  }

  /// 托盘隐藏 / 系统低内存：释放内置平台原生取词缓存。
  ///
  /// 只动结果缓存，脚本仓库 / 引擎 / 渠道偏好都不在这里清；幂等。
  void releaseBuiltinLyricCache() => _builtinLyricFallback.clearCache();

  /// 托盘隐藏 / 系统低内存：释放内置平台原生取图缓存（同上，幂等）。
  void releaseBuiltinPicCache() => _builtinPicFallback.clearCache();

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
    // 能力位与注册表适配器同源：路由门与 profile.comment 读同一份画像。
    final route = _primaryRoute(
      sourceProfiles,
      track.sourceKey,
      SourceCapability.comments,
    );
    if (route is! BuiltinSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: track.sourceKey,
          capability: SourceCapability.comments,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
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
    final route = _primaryRoute(
      sourceProfiles,
      sourceKey,
      SourceCapability.album,
    );
    if (route is! BuiltinSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: sourceKey,
          capability: SourceCapability.album,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
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
    // 详情路由只看适配器（画像的 `artist` 还叠了搜索门，UI 入口用能力位），
    // 已保存曲目的歌手 id 在无激活脚本时仍可直接取详情。
    final route = _primaryRoute(
      sourceProfiles,
      sourceKey,
      SourceCapability.artist,
    );
    if (route is! BuiltinSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: sourceKey,
          capability: SourceCapability.artist,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
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
    // 歌手搜索与单曲搜索同门（画像 `artist` 只在搜索路由可用时为真）；
    // 能力位与路由同源，UI 不会显示一个必然失败的入口。
    final profiles = sourceProfiles;
    if (profiles.forKey(sourceKey)?.capabilities.artist != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌手搜索',
      );
    }
    final route = _primaryRoute(profiles, sourceKey, SourceCapability.artist);
    if (route is! BuiltinSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: sourceKey,
          capability: SourceCapability.artist,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
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
    final profiles = sourceProfiles;
    if (profiles.forKey(sourceKey)?.capabilities.lyricSearch != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌词搜索',
      );
    }
    final route = _primaryRoute(
      profiles,
      sourceKey,
      SourceCapability.lyricSearch,
    );
    if (route is! BuiltinSourceRoute) {
      _throwUnavailable(
        UnavailableSourceRoute(
          key: sourceKey,
          capability: SourceCapability.lyricSearch,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
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
  /// 平台搜索响应已带封面（wy/tx/kg/kw/mg）时直接复用；否则脚本 pic 优先，
  /// 再回退内置实现（kw/kg 取图接口、wy 歌曲详情、tx 专辑 mid 拼 URL、
  /// mg 资源封面）。
  Future<String?> fetchPic(SourceTrack track) async {
    var profiles = sourceProfiles;
    // any-listen 的封面来自远端服务器，优先于曲目自带封面（旧实现顺序）。
    final initialRoutes = routingOf(profiles)
        .routesFor(track.sourceKey, SourceCapability.picture);
    if (initialRoutes.first is AnyListenSourceRoute) {
      try {
        return await _anyListenSource.fetchPic(track);
      } catch (_) {
        return null;
      }
    }
    final existing = track.coverUrl;
    if (existing != null && existing.isNotEmpty) return existing;
    // 同 fetchLyric：内置渠道走原生取图，脚本只做覆盖、不触发激活。
    await _ensureScriptFor(track.sourceKey, profiles);
    profiles = sourceProfiles;
    final routes = routingOf(profiles)
        .routesFor(track.sourceKey, SourceCapability.picture);
    for (final route in routes) {
      switch (route) {
        case AnyListenSourceRoute():
          continue;
        case ScriptSourceRoute():
          final decl = _activeSources[track.sourceKey];
          if (decl == null || !decl.canFetchPic) continue;
          try {
            final url = await _engine.getPic(
              source: track.sourceKey,
              musicInfo: track.raw,
            );
            if (url.isNotEmpty) return url;
          } catch (_) {
            // 脚本失败时继续尝试内置回退。
          }
        case BuiltinSourceRoute():
          return _builtinPicFallback.fetch(track);
        case UnavailableSourceRoute():
          continue;
      }
    }
    return null;
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
    final hasUpdate =
        latest.version != current.version ||
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
    _cancelActivationRetry();
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
