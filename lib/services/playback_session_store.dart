import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            : {
                'name': context!.name,
                'type': context!.type,
                'uri': context!.uri
              },
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

/// SharedPreferences 持久化（会话键 + 游标键 + 轻量进度键；解析失败静默丢弃）。
///
/// 为什么拆键：会话 JSON 含整份队列（每首都有 raw payload，大队列下是
/// 数百 KB ~ MB 级），而切歌 / 暂停只改下标与进度。若这些变化也整份重写，
/// 等于每次切歌做一次全队列 `jsonEncode` + prefs 整文件写入（UI isolate）。
/// 因此：
/// - 会话键 [save] 只在队列内容 / 模式 / 上下文变化时重写（队列列表实例相同
///   即视为未变：后端按 `queueRevision` 复用同一份不可变 List）；
/// - 游标键 [_stateKey] 存下标 / 进度 / savedAt，切歌 / 暂停只写它；
/// - 进度键 [savePosition] 是 int，按秒刷新；
/// - [load] / [loadRaw] 读取时把三个键合并成完整会话，对上层透明。
class PlaybackSessionStore {
  static const String _key = 'playback_session_v1';

  /// 高频进度键（毫秒 int）：与 [_key] 分离的轻量写入面。
  static const String _positionKey = 'playback_session_position_v1';

  /// 游标键：下标 / 进度 / savedAt；队列未变时 [save] 只写它。
  static const String _stateKey = 'playback_session_state_v1';

  /// 写入时间戳键（跨设备同步用它判断会话新旧）。
  static const String savedAtKey = kPlaybackSessionSavedAtKey;

  /// [_preferences] / [clock] 仅测试注入。
  PlaybackSessionStore({
    this._preferences,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now;

  /// 会话落盘回调（组合根在同步栈建好后接线：标记「会话待外发」）。
  void Function()? onSaved;

  final SharedPreferences? _preferences;
  final DateTime Function() _clock;

  final Logger _logger = Logger('molia.playback_session_store');

  /// 最近一次写请求（保存 / 原样写入 / 清除）的完成时机。
  ///
  /// 写请求按调用顺序串行落盘：后一个不会先于前一个写入，`clear()` 也不会
  /// 被在途的位置保存在之后「复活」。系统控制路径（通知暂停 / 停止）await 它，
  /// 保证暂停态在控制动作返回前已写回本地——进程随后被回收也能恢复。
  /// 无写请求时为已完成的 Future。
  Future<void> get pendingWrite => _pendingWrite ?? Future<void>.value();
  Future<void>? _pendingWrite;

  /// 上一次成功整份写入的队列形状：列表实例 + 模式 + 上下文都相同时，
  /// [save] 只更新游标键（见 [_stateKey]）。写成功后才更新。
  List<Track>? _writtenTracks;
  PlayMode? _writtenMode;
  PlaybackContext? _writtenContext;

  /// 队列缓存代次：发起整份写入 / 外部整份改写都会 +1。
  ///
  /// 整份写入在写回调里才提交缓存，必须确认期间没有更新的作废请求——否则
  /// 一次迟到的成功写入会把已被覆盖的队列误记为「会话键里是它」。
  int _queueCacheEpoch = 0;

  Future<void> save(PlaybackSession session) {
    final savedAt = _clock().millisecondsSinceEpoch;
    final positionMs = session.position.inMilliseconds;
    // 立即序列化：会话对象持有队列列表，写请求排队期间状态可能已被替换。
    final state = jsonEncode({
      'index': session.index,
      'positionMs': positionMs,
      savedAtKey: savedAt,
    });

    final tracks = session.tracks;
    final mode = session.mode;
    final context = session.context;
    final queueUnchanged = identical(tracks, _writtenTracks) &&
        mode == _writtenMode &&
        context == _writtenContext;
    final String? full;
    int? cacheEpoch;
    if (queueUnchanged) {
      full = null;
    } else {
      full = _encodeFull(session, savedAt: savedAt);
      if (full == null) return Future<void>.value();
      // 整份写入在途时先作废缓存：写失败或排在后面的保存请求都不能拿「已写」
      // 跳过完整键，否则会话键会停在旧队列。
      cacheEpoch = _invalidateQueueCache();
    }

    return _enqueueWrite((sp) async {
      if (full != null) {
        final written = await sp.setString(_key, full);
        if (!written) {
          // 平台拒绝落盘时不能继续写游标：旧队列配上新下标会让重启后的
          // 下标越界 / 指向错误的歌。抛出让 _runWrite 跳过本轮剩余写入。
          throw StateError('完整会话键写入被平台拒绝');
        }
        // 期间若有更新的整份写入 / 作废请求，这份队列已不是会话键里的内容。
        if (cacheEpoch == _queueCacheEpoch) {
          _writtenTracks = tracks;
          _writtenMode = mode;
          _writtenContext = context;
        }
      }
      await _writeStateKey(sp, state: state, contentWritten: full != null);
      await _writePositionKey(sp, positionMs);
    }, notify: true);
  }

  /// 写游标键；被平台拒绝时抛错，让 [_runWrite] 跳过本轮进度键写入。
  ///
  /// 完整键刚写过时先删掉旧游标 / 进度：旧游标的 savedAt 可能等于或晚于新
  /// 完整 JSON（同毫秒保存、远端时间戳更旧），读取时会把它套到新队列上；
  /// 旧进度也会盖掉新 JSON 自带的 position。删掉后读取回落到完整 JSON。
  /// 只写游标时不能删：旧游标 + 旧进度才是自洽的。
  Future<void> _writeStateKey(
    SharedPreferences preferences, {
    required String state,
    required bool contentWritten,
  }) async {
    bool written;
    try {
      written = await preferences.setString(_stateKey, state);
    } catch (_) {
      if (contentWritten) await _dropStaleCursor(preferences);
      rethrow;
    }
    if (written) return;
    if (contentWritten) await _dropStaleCursor(preferences);
    throw StateError('游标键写入被平台拒绝');
  }

  /// 尽力删除可能压过新完整 JSON 的旧游标 / 进度（单个失败只记日志）。
  Future<void> _dropStaleCursor(SharedPreferences preferences) async {
    for (final key in [_stateKey, _positionKey]) {
      try {
        await preferences.remove(key);
      } catch (e) {
        _logger.warning('清除旧播放游标失败: $e');
      }
    }
  }

  /// 写进度键；平台拒绝时删掉旧进度再抛错。
  ///
  /// 进度是读取时最后覆盖 position 的事实来源：写入失败若留下旧值，会把
  /// 刚写好的 state / 完整 JSON 的新进度改回去（曲目对、进度错）。完整 JSON
  /// 与 state 已成功，删除只影响进度，读取会回落到它们自带的 position。
  Future<void> _writePositionKey(
    SharedPreferences preferences,
    int positionMs,
  ) async {
    bool written;
    try {
      written = await preferences.setInt(_positionKey, positionMs);
    } catch (_) {
      await _dropStalePosition(preferences);
      rethrow;
    }
    if (written) return;
    await _dropStalePosition(preferences);
    throw StateError('进度键写入被平台拒绝');
  }

  /// 尽力删除可能盖过新 state / 完整 JSON 的旧进度（失败只记日志）。
  Future<void> _dropStalePosition(SharedPreferences preferences) async {
    try {
      await preferences.remove(_positionKey);
    } catch (e) {
      _logger.warning('清除旧播放进度失败: $e');
    }
  }

  /// 整份会话 JSON（含 [savedAtKey]）；序列化失败返回 null。
  String? _encodeFull(PlaybackSession session, {required int savedAt}) {
    try {
      final json = session.toJson();
      json[savedAtKey] = savedAt;
      return jsonEncode(json);
    } catch (e) {
      _logger.warning('保存播放会话失败: $e');
      return null;
    }
  }

  /// 作废队列缓存：下一次 [save] 保守重写整份 JSON。
  ///
  /// 外部整份改写（远端应用 / 数据注入 / 清除）、整份写入在途或写失败后，
  /// 本实例缓存的「会话键里是哪份队列」都不再可信。返回新的代次，供写回调
  /// 判断自己是否仍然有效。
  int _invalidateQueueCache() {
    _writtenTracks = null;
    _writtenMode = null;
    _writtenContext = null;
    return ++_queueCacheEpoch;
  }

  /// 只刷新播放进度（位置 tick 的高频路径）。
  ///
  /// 不重写会话 JSON、不触发 [onSaved]（进度不是内容变更，不应让同步
  /// 每轮都把整份队列当成新版本）。
  Future<void> savePosition(int positionMs) {
    return _enqueueWrite((sp) => sp.setInt(_positionKey, positionMs));
  }

  /// 串行化写请求（按调用顺序执行；[pendingWrite] 因此可直接 await）。
  Future<void> _enqueueWrite(
    Future<void> Function(SharedPreferences preferences) write, {
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
    Future<void> Function(SharedPreferences preferences) write, {
    bool notify = false,
  }) async {
    SharedPreferences? sp;
    try {
      sp = _preferences ?? await SharedPreferences.getInstance();
      await write(sp);
      if (notify) onSaved?.call();
    } catch (e) {
      _logger.warning('写入播放会话失败: $e');
      // `setX` 先改进程内缓存再调平台：平台返回 false / 抛错时缓存里已经是
      // 「写成功」的值，与磁盘不一致（同进程的 load 会读到没落盘的队列 /
      // 游标）。失败路径才 reload，把缓存拉回平台真实值；正常写入零额外 IO。
      // 代价是 reload 可能覆盖其它服务刚写、尚未落盘的缓存值——宁可少一次
      // 未持久化的内存更新，也不能让上层把没落盘的会话当成已保存。
      await _reloadAfterWriteFailure(sp);
    }
  }

  /// 写入失败后回读平台值；reload 自身失败只记日志，不掩盖原始写入错误。
  Future<void> _reloadAfterWriteFailure(SharedPreferences? preferences) async {
    if (preferences == null) return;
    try {
      await preferences.reload();
    } catch (e) {
      _logger.warning('回读播放会话失败: $e');
    }
  }

  Future<PlaybackSession?> load() async {
    try {
      final json = await loadRaw();
      return json == null ? null : PlaybackSession.fromJson(json);
    } catch (e) {
      _logger.warning('加载播放会话失败: $e');
      return null;
    }
  }

  /// 原始 JSON（含 [savedAtKey]；游标与进度以轻量键为准）：无记录或损坏返回 null。
  Future<Map<String, dynamic>?> loadRaw() async {
    try {
      final sp = _preferences ?? await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final map = json.cast<String, dynamic>();
      _applyState(sp.getString(_stateKey), map);
      // 进度键是更高频的事实来源；整份会话与进度键短暂不一致时沿用会话内值。
      final positionMs = sp.getInt(_positionKey);
      if (positionMs != null) map['positionMs'] = positionMs;
      return map;
    } catch (e) {
      _logger.warning('加载播放会话失败: $e');
      return null;
    }
  }

  /// 用游标键覆盖整份 JSON 里的下标 / 进度 / savedAt（切歌 / 暂停只更新它）。
  ///
  /// 状态键比会话键旧说明会话键被外部整份改写（数据注入 / 旧版本）：状态键已
  /// 不属于这份队列，忽略它。损坏的状态键只丢覆盖，不影响会话读取。
  void _applyState(String? encoded, Map<String, dynamic> map) {
    if (encoded == null || encoded.isEmpty) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return;
      final state = decoded.cast<String, dynamic>();
      final stateSavedAt = (state[savedAtKey] as num?)?.toInt();
      final contentSavedAt = (map[savedAtKey] as num?)?.toInt();
      if (stateSavedAt != null &&
          contentSavedAt != null &&
          stateSavedAt < contentSavedAt) {
        return;
      }
      final index = (state['index'] as num?)?.toInt();
      if (index != null) map['index'] = index;
      final positionMs = (state['positionMs'] as num?)?.toInt();
      if (positionMs != null) map['positionMs'] = positionMs;
      if (stateSavedAt != null) map[savedAtKey] = stateSavedAt;
    } catch (e) {
      _logger.warning('忽略损坏的播放会话状态键: $e');
    }
  }

  /// 原样写入 JSON（跨设备同步应用远端会话用；内容须自包含 savedAt）。
  ///
  /// 不经 [onSaved]：写入方是同步适配器自己，回传待发标记只会多跑一轮。
  /// 远端整份覆盖了队列，因此作废队列缓存，下一次本地 [save] 保守重写整份。
  Future<void> saveRaw(Map<String, dynamic> raw) {
    final positionMs = (raw['positionMs'] as num?)?.toInt();
    final index = (raw['index'] as num?)?.toInt();
    final savedAt = (raw[savedAtKey] as num?)?.toInt();
    final state = jsonEncode({
      'index': ?index,
      'positionMs': ?positionMs,
      savedAtKey: ?savedAt,
    });
    _invalidateQueueCache();
    return _enqueueWrite((sp) async {
      final written = await sp.setString(_key, jsonEncode(raw));
      if (!written) {
        // 完整键没落盘时写远端游标，会把远端下标套到旧队列上；抛出让
        // _runWrite 跳过本轮剩余写入。缓存已作废，下次本地 / 远端写入重试。
        throw StateError('会话键写入被平台拒绝');
      }
      await _writeStateKey(sp, state: state, contentWritten: true);
      if (positionMs != null) await _writePositionKey(sp, positionMs);
    });
  }

  Future<void> clear() {
    _invalidateQueueCache();
    return _enqueueWrite((sp) async {
      await sp.remove(_key);
      await sp.remove(_stateKey);
      await sp.remove(_positionKey);
    });
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
    duration:
        durationMs is num ? Duration(milliseconds: durationMs.toInt()) : null,
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
