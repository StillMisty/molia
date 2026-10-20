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
                'uri': context!.uri,
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

/// SharedPreferences 持久化（会话键 + 轻量进度键；解析失败静默丢弃）。
///
/// 为什么拆两个键：会话 JSON 含整份队列（每首都有 raw payload，大队列下是
/// 数百 KB ~ MB 级），而播放进度每秒都在推进。若进度 tick 也整份重写，等于
/// 播放期间每秒做一次全队列 `jsonEncode` + prefs 整文件写入（UI isolate）。
/// 因此：
/// - 会话键 [save] 只在内容变化（切歌 / 队列 / 模式 / 上下文）时重写；
/// - 进度键 [savePosition] 是 int，按秒刷新；
/// - [load] / [loadRaw] 读取时把两个键合并成完整会话，对上层透明。
class PlaybackSessionStore {
  static const String _key = 'playback_session_v1';

  /// 高频进度键（毫秒 int）：与 [_key] 分离的轻量写入面。
  static const String _positionKey = 'playback_session_position_v1';

  /// 写入时间戳键（跨设备同步用它判断会话新旧；旧数据缺省按 0 处理）。
  static const String savedAtKey = kPlaybackSessionSavedAtKey;

  /// [preferences] / [clock] 仅测试注入。
  PlaybackSessionStore({
    SharedPreferences? preferences,
    DateTime Function()? clock,
  })  : _preferences = preferences,
        _clock = clock ?? DateTime.now;

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

  Future<void> save(PlaybackSession session) {
    // 立即序列化：会话对象持有队列列表，写请求排队期间状态可能已被替换。
    final String encoded;
    try {
      final json = session.toJson();
      json[savedAtKey] = _clock().millisecondsSinceEpoch;
      encoded = jsonEncode(json);
    } catch (e) {
      _logger.warning('保存播放会话失败: $e');
      return Future<void>.value();
    }
    return _enqueueWrite((sp) async {
      await sp.setString(_key, encoded);
      await sp.setInt(_positionKey, session.position.inMilliseconds);
    }, notify: true);
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
    try {
      final sp = _preferences ?? await SharedPreferences.getInstance();
      await write(sp);
      if (notify) onSaved?.call();
    } catch (e) {
      _logger.warning('写入播放会话失败: $e');
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

  /// 原始 JSON（含 [savedAtKey]；进度以轻量进度键为准）：无记录或损坏返回 null。
  Future<Map<String, dynamic>?> loadRaw() async {
    try {
      final sp = _preferences ?? await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final map = json.cast<String, dynamic>();
      // 进度键是更高频的事实来源；旧数据/远端写入没有进度键时沿用会话内值。
      final positionMs = sp.getInt(_positionKey);
      if (positionMs != null) map['positionMs'] = positionMs;
      return map;
    } catch (e) {
      _logger.warning('加载播放会话失败: $e');
      return null;
    }
  }

  /// 原样写入 JSON（跨设备同步应用远端会话用；内容须自包含 savedAt）。
  ///
  /// 不经 [onSaved]：写入方是同步适配器自己，回传待发标记只会多跑一轮。
  Future<void> saveRaw(Map<String, dynamic> raw) {
    final positionMs = (raw['positionMs'] as num?)?.toInt();
    return _enqueueWrite((sp) async {
      await sp.setString(_key, jsonEncode(raw));
      if (positionMs != null) await sp.setInt(_positionKey, positionMs);
    });
  }

  Future<void> clear() {
    return _enqueueWrite((sp) async {
      await sp.remove(_key);
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
      'qualities': [
        for (final quality in track.qualities)
          {
            'type': quality.type,
            'size': quality.size,
            'hash': quality.hash,
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
    qualities: [
      if (qualitiesJson is List)
        for (final quality in qualitiesJson)
          if (quality is Map)
            AudioQuality(
              type: quality['type'] as String? ?? '',
              size: quality['size'] as String?,
              hash: quality['hash'] as String?,
            ),
    ],
    payload: payload is Map ? payload.cast<String, Object?>() : const {},
  );
}
