import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/molia_database.dart';
import '../data/playback_session_repository.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/playback_session_sync.dart';
import '../models/play_mode.dart';

/// 上次播放会话：队列 + 下标 + 进度 + 模式 + 上下文。
///
/// 冷启动用于「继续上次播放」：UI 先展示恢复态（封面/标题/进度），
/// 用户点播放再重新取链恢复（直链不持久化，过期由取链层重解析）。
class PlaybackSession {
  final List<Track> tracks;
  final int index;
  final Duration position;
  final PlayMode mode;
  final PlaybackContext? context;

  const PlaybackSession({
    required this.tracks,
    required this.index,
    this.position = Duration.zero,
    this.mode = PlayMode.listLoop,
    this.context,
  });

  Track? get current =>
      index >= 0 && index < tracks.length ? tracks[index] : null;

  PlaybackSession copyWith({
    List<Track>? tracks,
    int? index,
    Duration? position,
    PlayMode? mode,
    PlaybackContext? context,
  }) {
    return PlaybackSession(
      tracks: tracks ?? this.tracks,
      index: index ?? this.index,
      position: position ?? this.position,
      mode: mode ?? this.mode,
      context: context ?? this.context,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'index': index,
    'positionMs': position.inMilliseconds,
    'mode': mode.name,
    'context': context == null
        ? null
        : {'name': context!.name, 'type': context!.type, 'uri': context!.uri},
    'tracks': [for (final track in tracks) _trackToJson(track)],
  };

  static PlaybackSession? fromJson(Map<String, dynamic> json) {
    try {
      final tracksJson = json['tracks'];
      if (tracksJson is! List || tracksJson.isEmpty) return null;
      final tracks = <Track>[
        for (final track in tracksJson)
          if (track is Map) _trackFromJson(track.cast<String, dynamic>()),
      ];
      if (tracks.isEmpty) return null;
      final index = (json['index'] as num?)?.toInt() ?? 0;
      final positionMs = (json['positionMs'] as num?)?.toInt() ?? 0;
      final modeName = json['mode'] as String?;
      final contextJson = json['context'];
      return PlaybackSession(
        tracks: tracks,
        index: index.clamp(0, tracks.length - 1),
        position: Duration(milliseconds: positionMs < 0 ? 0 : positionMs),
        mode: PlayMode.values.firstWhere(
          (mode) => mode.name == modeName,
          orElse: () => PlayMode.listLoop,
        ),
        context: contextJson is Map
            ? PlaybackContext(
                name: contextJson['name'] as String?,
                type: contextJson['type'] as String?,
                uri: contextJson['uri'] as String?,
              )
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 播放会话持久化：主库两张表（payload + cursor），动作落盘、无周期写。
///
/// 为什么拆两张表（不再用 SharedPreferences）：会话 JSON 含整份队列（每首都有
/// raw payload，大队列下是 MB 级），而切歌 / 暂停 / seek 只改下标与进度。prefs
/// 任何一次 `setString` 都会整文件重写，1Hz 进度写会把整份队列按 MB/s 写盘；
/// 现在进度只写 cursor 单行，队列 / 模式 / 上下文变化才写 payload 行（且
/// payload + cursor 在同一事务）。
///
/// 写请求仍经 [pendingWrite] 串行：后一个写不会先于前一个落盘，`clear()` 也
/// 不会被在途的保存「复活」；系统控制路径 await 它，保证动作返回前已写回。
///
/// 旧 prefs 会话（三个键）**不迁移、不读取**：首次读取时一次性删除，避免
/// 2MB 继续留在 prefs 里被后续设置写入反复整文件重写。删除失败只记日志。
class PlaybackSessionStore {
  static const String _key = 'playback_session_v1';

  /// 旧版高频进度键（毫秒 int）：只用于清理。
  static const String _positionKey = 'playback_session_position_v1';

  /// 旧版游标键：只用于清理。
  static const String _stateKey = 'playback_session_state_v1';

  /// 写入时间戳键（跨设备同步用它判断会话新旧）。
  static const String savedAtKey = kPlaybackSessionSavedAtKey;

  /// [preferences] / [clock] / [repository] 仅测试注入。
  PlaybackSessionStore({
    PlaybackSessionRepository? repository,
    MoliaDatabase Function()? database,
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
  }) : _repository =
           repository ??
           PlaybackSessionRepository(
             database: database ?? debugDatabaseOverride,
           ),
       _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  /// 测试统一注入内存库（`flutter_test_config.dart` 每个用例重置）；生产为 null。
  @visibleForTesting
  static MoliaDatabase Function()? debugDatabaseOverride;

  /// 会话落盘回调（组合根在同步栈建好后接线：标记「会话待外发」）。
  void Function()? onSaved;

  final PlaybackSessionRepository _repository;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;

  final Logger _logger = Logger('molia.playback_session_store');

  /// 最近一次写请求（保存 / 原样写入 / 清除）的完成时机。
  Future<void> get pendingWrite => _pendingWrite ?? Future<void>.value();
  Future<void>? _pendingWrite;

  /// 上一次成功写 payload 的队列形状：列表实例 + 模式 + 上下文都相同时，
  /// [save] 只更新 cursor 行。写成功后才更新。
  List<Track>? _writtenTracks;
  PlayMode? _writtenMode;
  PlaybackContext? _writtenContext;

  /// 队列缓存代次：发起 payload 写入 / 外部整份改写都会 +1。
  ///
  /// payload 写入在事务完成后才提交缓存，必须确认期间没有更新的作废请求
  /// ——否则一次迟到的成功写入会把已被覆盖的队列误记为「库里是它」。
  int _queueCacheEpoch = 0;

  /// 旧 prefs 清理只做一次；失败清掉 future，下次启动 / 读取会重试。
  Future<void>? _legacyCleanup;

  /// 启动埋点只记第一次读取（同步轮询 loadRaw / 恢复态重载不刷日志）。
  bool _loadTimingLogged = false;

  Future<void> save(PlaybackSession session) {
    final savedAt = _clock().millisecondsSinceEpoch;
    final positionMs = session.position.inMilliseconds;

    final tracks = session.tracks;
    final mode = session.mode;
    final context = session.context;
    final queueUnchanged =
        identical(tracks, _writtenTracks) &&
        mode == _writtenMode &&
        context == _writtenContext;
    if (queueUnchanged) {
      return _enqueueWrite(
        (repository) => repository.saveCursor(
          index: session.index,
          positionMs: positionMs,
          savedAt: savedAt,
        ),
        notify: true,
      );
    }

    final full = _encodeFull(session, savedAt: savedAt);
    if (full == null) return Future<void>.value();
    // payload 写入在途时先作废缓存：写失败或排在后面的保存请求都不能拿
    // 「已写」跳过整份 payload，否则库里会停在旧队列。
    final cacheEpoch = _invalidateQueueCache();

    return _enqueueWrite((repository) async {
      await repository.saveAll(
        payload: full,
        savedAt: savedAt,
        index: session.index,
        positionMs: positionMs,
      );
      // 期间若有更新的整份写入 / 作废请求，这份队列已不是库里的内容。
      if (cacheEpoch == _queueCacheEpoch) {
        _writtenTracks = tracks;
        _writtenMode = mode;
        _writtenContext = context;
      }
    }, notify: true);
  }

  /// 整份会话 JSON（含 [savedAtKey]）；序列化失败返回 null。
  Map<String, dynamic>? _encodeFull(
    PlaybackSession session, {
    required int savedAt,
  }) {
    try {
      final json = session.toJson();
      json[savedAtKey] = savedAt;
      return json;
    } catch (e) {
      _logger.warning('保存播放会话失败: $e');
      return null;
    }
  }

  /// 作废队列缓存：下一次 [save] 保守重写整份 payload。
  int _invalidateQueueCache() {
    _writtenTracks = null;
    _writtenMode = null;
    _writtenContext = null;
    return ++_queueCacheEpoch;
  }

  /// 只刷新播放进度（保留 API；协调者不再周期调用，动作落盘走 [save]）。
  ///
  /// 不写 payload、不触发 [onSaved]；不存在的 cursor 行不会被凭空创建。
  Future<void> savePosition(int positionMs) {
    return _enqueueWrite((repository) => repository.updatePosition(positionMs));
  }

  /// 串行化写请求（按调用顺序执行；[pendingWrite] 因此可直接 await）。
  Future<void> _enqueueWrite(
    Future<void> Function(PlaybackSessionRepository repository) write, {
    bool notify = false,
  }) {
    final pending = _pendingWrite;
    final next = pending == null
        ? _runWrite(write, notify: notify)
        : pending.then((_) => _runWrite(write, notify: notify));
    _pendingWrite = next;
    return next;
  }

  Future<void> _runWrite(
    Future<void> Function(PlaybackSessionRepository repository) write, {
    bool notify = false,
  }) async {
    try {
      await write(_repository);
      if (notify) onSaved?.call();
    } catch (e) {
      _logger.warning('写入播放会话失败: $e');
      // 事务失败时 SQLite 已回滚；缓存仍由 epoch 保护，下次保存重试整份。
    }
  }

  Future<PlaybackSession?> load() async {
    // 启动埋点：首帧前的恢复态读取（含首次开库 / Windows 旧库迁移成本）。
    final watch = Stopwatch()..start();
    final cacheEpoch = _queueCacheEpoch;
    try {
      final json = await loadRaw();
      if (json == null) return null;
      final session = PlaybackSession.fromJson(json);
      if (session == null) return null;
      // 恢复出的队列就是库里已有的 payload：把写缓存对齐过去，否则恢复后
      // 第一次暂停 / seek 会走「队列变化」分支，把 MB 级 payload 重写一遍。
      // 期间若有写入 / 作废请求（epoch 变了），缓存不可信，交给下一次 save。
      if (cacheEpoch == _queueCacheEpoch) {
        _writtenTracks = session.tracks;
        _writtenMode = session.mode;
        _writtenContext = session.context;
      }
      return session;
    } catch (e) {
      _logger.warning('加载播放会话失败: $e');
      return null;
    } finally {
      if (!_loadTimingLogged) {
        _loadTimingLogged = true;
        Logger('molia.startup')
            .info('sub.session.load：${watch.elapsedMilliseconds}ms');
      }
    }
  }

  /// 原始 JSON（含 [savedAtKey]；cursor 以 savedAt 合并）：无记录或损坏返回 null。
  Future<Map<String, dynamic>?> loadRaw() async {
    await cleanupLegacyPreferences();
    try {
      return await _repository.loadRaw();
    } catch (e) {
      _logger.warning('加载播放会话失败: $e');
      return null;
    }
  }

  /// 原样写入 JSON（跨设备同步应用远端会话用；内容须自包含 savedAt）。
  ///
  /// 不经 [onSaved]：写入方是同步适配器自己，回传待发标记只会多跑一轮。
  /// 远端整份覆盖了队列，因此作废队列缓存，下一次本地 [save] 保守重写整份。
  Future<void> saveRaw(Map<String, dynamic> raw) {
    final positionMs = (raw['positionMs'] as num?)?.toInt();
    final index = (raw['index'] as num?)?.toInt();
    final savedAt = (raw[savedAtKey] as num?)?.toInt() ?? 0;
    _invalidateQueueCache();
    return _enqueueWrite(
      (repository) => repository.saveAll(
        payload: raw,
        savedAt: savedAt,
        index: index ?? 0,
        positionMs: positionMs ?? 0,
      ),
    );
  }

  Future<void> clear() {
    _invalidateQueueCache();
    return _enqueueWrite((repository) async {
      await repository.clear();
      await cleanupLegacyPreferences();
    });
  }

  /// 旧 prefs 会话键一次性删除：不读内容、不导入，只清掉大对象。
  ///
  /// 协调者启动时即使「恢复上次播放」开关关闭也会调用它，保证旧 2MB 不会
  /// 因为跳过会话读取而长期留在 prefs 里。失败只记日志并允许下次重试。
  Future<void> cleanupLegacyPreferences() {
    return _legacyCleanup ??= () async {
      var failed = false;
      try {
        final prefs = await _preferences();
        for (final key in [_key, _stateKey, _positionKey]) {
          if (!prefs.containsKey(key)) continue;
          // 平台写入失败会返回 false（不抛错）：不能当成功缓存，否则旧 2MB
          // 键再也不会被重试。
          final removed = await prefs.remove(key);
          if (!removed) {
            failed = true;
            _logger.warning('清理旧播放会话 prefs 被平台拒绝: $key');
          }
        }
      } catch (e) {
        failed = true;
        _logger.warning('清理旧播放会话 prefs 失败: $e');
      } finally {
        // 任一键失败都不缓存：下次启动 / 读取 / 清除再试一次。
        if (failed) _legacyCleanup = null;
      }
    }();
  }
}

Map<String, dynamic> _trackToJson(Track track) => {
  'sourceKey': track.id.sourceKey,
  'id': track.id.id,
  'title': track.title,
  'artists': [
    for (final artist in track.artists)
      {'name': artist.name, if (artist.id != null) 'id': artist.id},
  ],
  'album': track.album,
  'durationMs': track.duration?.inMilliseconds,
  'artwork': track.artwork?.uri.toString(),
  'origin': track.origin.name,
  'platformPageUrl': track.platformPageUrl,
  'platformAlbumId': track.platformAlbumId,
  'qualities': [
    for (final quality in track.qualities)
      {
        'type': quality.type,
        'size': quality.size,
        'hash': quality.hash,
        if (quality.container != null) 'container': quality.container,
      },
  ],
  'payload': track.payload,
};

Track _trackFromJson(Map<String, dynamic> json) {
  final artistsJson = json['artists'];
  final qualitiesJson = json['qualities'];
  final artworkUrl = json['artwork'] as String?;
  final durationMs = json['durationMs'];
  final payload = json['payload'];
  return Track(
    id: TrackId(
      json['sourceKey'] as String? ?? '',
      json['id'] as String? ?? '',
    ),
    title: json['title'] as String? ?? '',
    artists: [
      if (artistsJson is List)
        for (final artist in artistsJson)
          if (artist is Map)
            Artist(
              name: artist['name'] as String? ?? '',
              id: artist['id'] as String?,
            ),
    ],
    album: json['album'] as String?,
    duration: durationMs is num
        ? Duration(milliseconds: durationMs.toInt())
        : null,
    artwork: artworkUrl != null && artworkUrl.isNotEmpty
        ? Artwork(uri: Uri.parse(artworkUrl))
        : null,
    origin: TrackOrigin.values.firstWhere(
      (origin) => origin.name == json['origin'],
      orElse: () => TrackOrigin.lx,
    ),
    platformPageUrl: json['platformPageUrl'] as String?,
    platformAlbumId: json['platformAlbumId'] as String?,
    qualities: [
      if (qualitiesJson is List)
        for (final quality in qualitiesJson)
          if (quality is Map)
            AudioQuality(
              type: quality['type'] as String? ?? '',
              size: quality['size'] as String?,
              hash: quality['hash'] as String?,
              container: quality['container'] as String?,
            ),
    ],
    payload: payload is Map ? payload.cast<String, Object?>() : const {},
  );
}
