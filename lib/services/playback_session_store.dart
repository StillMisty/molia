import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
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
    this.mode = PlayMode.sequential,
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
          orElse: () => PlayMode.sequential,
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

/// SharedPreferences 持久化（单键 JSON；解析失败静默丢弃）。
class PlaybackSessionStore {
  static const String _key = 'playback_session_v1';

  final Logger _logger = Logger();

  Future<void> save(PlaybackSession session) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(session.toJson()));
    } catch (e) {
      _logger.w('保存播放会话失败: $e');
    }
  }

  Future<PlaybackSession?> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return PlaybackSession.fromJson(json);
    } catch (e) {
      _logger.w('加载播放会话失败: $e');
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_key);
    } catch (e) {
      _logger.w('清除播放会话失败: $e');
    }
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
