/// 音源能力执行器：按 [SourceRouting] 给出的路线执行搜索 / 取链 / 歌词 /
/// 封面 / 评论 / 专辑 / 歌手 / 歌词搜索。
///
/// `SourceManager` 只保留生命周期（引擎 / 脚本仓库 / 偏好 / any-listen 配置）
/// 与画像 facade，能力方法一律委托到这里；本模块不持有画像 / 路由状态
/// （每次调用都读管理器给出的当前快照），只持有由管理器转交清理的内置取词 /
/// 取图缓存。依赖全部由构造注入：
/// - [profiles]：每次调用重建画像快照（与 `SourceManager.sourceProfiles`
///   同一答案，不缓存就没有第二份失效逻辑）；
/// - [ensureActiveScript]：脚本惰性激活回调（激活状态与限流仍在管理器）；
/// - [engine] / [anyListenSource] / [builtinTransport] / [preferences]：执行
///   各路线所需的适配器；
/// - 内置原生取词 / 取图派发在构造时按共享传输创建；其缓存是执行器唯一持有
///   的状态，清理入口由管理器转发。
///
/// 行为契约（从 `SourceManager` 迁出时逐条保留）：
/// - 路线顺序由 [SourceRouting.routesFor] 给出：歌词 / 封面脚本优先、内置
///   原生回退，其余能力单路线；
/// - 内置渠道的原生能力不触发脚本激活，纯脚本源 / 未知 key 才补激活；取链
///   在「内置画像 + 脚本尚未激活」时额外补一次后重新路由；
/// - 引擎返回的 [PlayableStream] 原样保留 headers；失败统一为
///   [SourceFailure]；
/// - B 站账号边界仍由适配器裁决，本模块不读 Cookie。
library;

import '../domain/models/album.dart';
import '../domain/models/artist.dart';
import '../domain/models/comment.dart';
import '../domain/models/failure.dart';
import '../domain/ports/music_source.dart' show PlayableStream;
import 'any_listen/any_listen_errors.dart';
import 'any_listen/any_listen_source.dart';
import 'builtin/album_source.dart';
import 'builtin/artist_source.dart';
import 'builtin/builtin_lyric_dispatch.dart';
import 'builtin/builtin_pic_dispatch.dart';
import 'builtin/builtin_search.dart';
import 'builtin/builtin_transport.dart';
import 'builtin/comment_source.dart';
import 'builtin/lyric_hit.dart';
import 'builtin/lyric_search.dart';
import 'lx/lx_engine_supervisor.dart';
import 'lx/lx_engine_types.dart';
import 'lx/lx_search_parse.dart';
import 'source_preferences.dart';
import 'source_profiles.dart';
import 'source_routing.dart';
import 'source_search_result.dart';
import 'source_track.dart';

class SourceRouteExecutor {
  SourceRouteExecutor({
    required this._engine,
    required this._anyListenSource,
    required this._builtinTransport,
    required this._preferences,
    required this._profiles,
    required this._ensureActiveScript,
  });

  final LxEngineSupervisor _engine;
  final AnyListenSource _anyListenSource;

  /// 内置平台的共享 HTTP 传输（组合根注入；测试各自构造）。
  final BuiltinTransport _builtinTransport;

  /// 渠道偏好：取链只读默认音质，写路径仍归 [SourcePreferences]。
  final SourcePreferences _preferences;

  /// 画像快照提供方：每次执行都取当前值，不缓存。
  final SourceProfiles Function() _profiles;

  /// 脚本惰性激活回调（[SourceManager] 的 `_ensureActiveScript`）。
  final Future<void> Function(String sourceKey) _ensureActiveScript;

  /// 内置平台原生歌词 / 封面回退（脚本不可用或未声明对应 action 时）。
  ///
  /// 缓存随执行器生命周期；构造时按共享传输创建，避免另建一份 HTTP 栈。
  late final BuiltinLyricDispatch _builtinLyricFallback = BuiltinLyricDispatch(
    _builtinTransport,
  );
  late final BuiltinPicDispatch _builtinPicFallback = BuiltinPicDispatch(
    _builtinTransport,
  );

  /// 单档 LX 取链的默认超时（与引擎 `getMusicUrl` 默认值一致）；调用方给了
  /// 剩余预算时取更短者。
  static const Duration _kLxResolveAttemptTimeout = Duration(seconds: 20);

  /// 纯脚本源的惰性激活入口（搜索 / 歌词 / 封面入口）。
  ///
  /// 内置渠道的原生能力不依赖脚本（脚本只做覆盖），any-listen 走自己的
  /// 配置，因此只有「画像未知」或「画像身份是 LX」才在这里拉起引擎。
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
          // 内置渠道没有原生取链、也没有脚本声明：按「该 key 当前不可用」
          // 上报（不冒充「平台不支持」）。
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

  /// 路由第一条路线；不可用路线直接按能力给出既有错误。
  ///
  /// `available=false` 只可能出现在 any-listen 路线（配置由适配器裁决），
  /// 这里不拦；内置 / 脚本路线生成时已通过能力门。
  SourceRoute _primaryRoute(
    SourceProfiles profiles,
    String key,
    SourceCapability capability,
  ) {
    final route = SourceRouting(profiles: profiles).primaryFor(key, capability);
    if (route is UnavailableSourceRoute) _throwUnavailable(route);
    return route;
  }

  /// 只接受内置实现的能力（评论 / 专辑 / 歌手 / 歌词搜索）的唯一取路入口。
  BuiltinSourceRoute _builtinRoute(
    SourceProfiles profiles,
    String key,
    SourceCapability capability,
  ) {
    final route = _primaryRoute(profiles, key, capability);
    if (route is BuiltinSourceRoute) return route;
    // 这些能力在内置渠道之外没有实现；any-listen / 脚本路线属于接线错误，
    // 按「不支持」给出能力对应的文案。
    _throwUnavailable(
      UnavailableSourceRoute(
        key: key,
        capability: capability,
        profile: route.profile,
        reason: SourceUnavailableReason.missingAdapter,
        declaration: route is ScriptSourceRoute ? route.declaration : null,
      ),
    );
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
    var profiles = _profiles();
    // 脚本源首次使用：画像里没有声明时先补一次激活（内置 / any-listen 不触发）。
    await _ensureScriptFor(sourceKey, profiles);
    profiles = _profiles();
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
          _builtinTransport,
          sourceKey,
          keyword,
          page: page,
          limit: limit,
        );
      case ScriptSourceRoute(:final action):
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
    var profiles = _profiles();
    // 纯脚本源 / 未知 key 先尝试惰性恢复。
    await _ensureScriptFor(track.sourceKey, profiles);
    profiles = _profiles();
    var route = SourceRouting(profiles: profiles)
        .primaryFor(track.sourceKey, SourceCapability.resolve);
    // 内置渠道没有原生取链、脚本又尚未激活时，画像里还没有 script 声明：
    // 与搜索 / 歌词不同，取链必须补一次激活后重新路由（否则已保存曲目会
    // 因为「脚本没跑起来」而不可播）。
    if (route is UnavailableSourceRoute &&
        profiles.forKey(track.sourceKey)?.kind == SourceKind.builtin) {
      await _ensureActiveScript(track.sourceKey);
      profiles = _profiles();
      route = SourceRouting(profiles: profiles)
          .primaryFor(track.sourceKey, SourceCapability.resolve);
    }
    if (route is UnavailableSourceRoute) _throwUnavailable(route);
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
          return await nativeResolve(
            _builtinTransport,
            track.raw,
            quality: picked,
          );
        } catch (e) {
          throw SourceFailure.from(e);
        }
      }
    }
    if (route is! ScriptSourceRoute) {
      // 内置路线必然有原生 resolve（否则路由会给出脚本 / 不可用），这里只
      // 让类型收窄可穷尽。
      _throwUnavailable(
        UnavailableSourceRoute(
          key: track.sourceKey,
          capability: SourceCapability.resolve,
          profile: route.profile,
          reason: SourceUnavailableReason.missingAdapter,
        ),
      );
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
    var profiles = _profiles();
    // 原生渠道不依赖脚本：脚本只做覆盖，因此不在歌词入口拉起引擎；
    // 纯脚本源 / 未知 key 才补一次惰性激活。
    await _ensureScriptFor(track.sourceKey, profiles);
    profiles = _profiles();
    final routes = SourceRouting(profiles: profiles)
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
        case ScriptSourceRoute(:final declaration):
          if (!declaration.canFetchLyric) continue;
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
    // 没有任何实现：歌词契约允许失败，返回 null 交由上层歌词源回退。
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
    _builtinRoute(_profiles(), track.sourceKey, SourceCapability.comments);
    try {
      return await BuiltinComments.fetch(
        _builtinTransport,
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
    _builtinRoute(_profiles(), sourceKey, SourceCapability.album);
    try {
      return await BuiltinAlbums.fetch(
        _builtinTransport,
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
    _builtinRoute(_profiles(), sourceKey, SourceCapability.artist);
    try {
      return await BuiltinArtists.fetch(
        _builtinTransport,
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
    final profiles = _profiles();
    if (profiles.forKey(sourceKey)?.capabilities.artist != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌手搜索',
      );
    }
    _builtinRoute(profiles, sourceKey, SourceCapability.artist);
    try {
      return await BuiltinArtists.search(
        _builtinTransport,
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
    final profiles = _profiles();
    if (profiles.forKey(sourceKey)?.capabilities.lyricSearch != true) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $sourceKey 不支持歌词搜索',
      );
    }
    _builtinRoute(profiles, sourceKey, SourceCapability.lyricSearch);
    try {
      return await BuiltinLyricSearch.searchWithMeta(
        _builtinTransport,
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
    var profiles = _profiles();
    // any-listen 的封面来自远端服务器，优先于曲目自带封面。
    final initialRoutes = SourceRouting(profiles: profiles)
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
    profiles = _profiles();
    final routes = SourceRouting(profiles: profiles)
        .routesFor(track.sourceKey, SourceCapability.picture);
    for (final route in routes) {
      switch (route) {
        case AnyListenSourceRoute():
          continue;
        case ScriptSourceRoute(:final declaration):
          if (!declaration.canFetchPic) continue;
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
}
