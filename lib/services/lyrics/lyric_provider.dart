import 'dart:async';

import 'package:molia/utils/html_unescape/html_unescape.dart';

import 'lyrics_match.dart';

/// 歌词提供者。
abstract class LyricProvider {
  /// 搜索歌曲，返回平台自己的歌曲ID（单个结果）
  Future<SongMatch?> search(String title, String artist);

  /// 搜索歌曲，返回多个匹配结果
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  });

  /// 获取歌词原文 LRC（原始接口，内置歌词搜索页直接消费）。
  ///
  /// 需要翻译 / 罗马音时用 [fetchLyrics] / [fetchForMatch] 的结构化结果。
  Future<String?> fetchLyric(String songId);

  /// 获取结构化歌词（原文 + 翻译 + 罗马音 + 逐字）；默认回退到 [fetchLyric]。
  Future<LyricsPayload?> fetchLyrics(String songId) async {
    final lyric = await fetchLyric(songId);
    if (lyric == null || lyric.trim().isEmpty) return null;
    return LyricsPayload(lyric: lyric);
  }

  /// 按搜索结果取词（平台附带字段经 [SongMatch.extra] 透传）。
  ///
  /// kg（hash + 时长）、mg（mrc/lrc/trc URL）、tx（数字 songId）等平台的
  /// 取词接口需要搜索响应里的附加字段，不能只靠 songId。
  Future<LyricsPayload?> fetchForMatch(SongMatch match) =>
      fetchLyrics(match.songId);

  /// 提供者名称
  String get name;

  /// 自动回退用的渠道 key（音源 key，如 `wy` / `tx`）。
  ///
  /// 默认与 [name] 相同；跨平台 provider 的展示名与渠道 key 不同
  /// （`netease` ↔ `wy`、`qq` ↔ `tx`），由实现覆盖。自动回退据此
  /// 判断「这个 provider 是不是曲目来源渠道」。
  String get channelKey => name;

  /// 规范化歌词文本
  String normalizeLyric(String rawLyric) {
    final unescape = HtmlUnescape();
    final decoded = unescape.convert(rawLyric);
    return decoded.replaceAll(RegExp(r'\r?\n+'), '\n').trim();
  }

  /// 获取歌词的完整流程（结构化：原文 + 翻译 + 罗马音 + 逐字）。
  ///
  /// 搜索 → 相似度挑选（时长 / 歌名 / 歌手，移植 LX `findMusic`）→ 取词 →
  /// 规范化；任一环节失败返回 null。
  Future<LyricsPayload?> getLyrics(String title, String artist) async {
    try {
      final matches = await searchMultiple(title, artist, limit: 5);
      if (matches.isEmpty) return null;
      final match =
          pickBestSongMatch(matches, title: title, artist: artist) ??
          matches.first;

      final payload = await fetchForMatch(match);
      if (payload == null) return null;

      final normalized = LyricsPayload(
        lyric: normalizeLyric(payload.lyric),
        translation: normalizeOptionalLyric(this, payload.translation),
        roma: normalizeOptionalLyric(this, payload.roma),
        lxlyric: normalizeOptionalLyric(this, payload.lxlyric),
      );
      return normalized.lyric.isEmpty ? null : normalized;
    } catch (e) {
      return null;
    }
  }
}

/// 可选扩展字段（翻译 / 罗马音 / 逐字）的统一归一：空串按 null，避免 UI
/// 渲染出空占位行。
String? normalizeOptionalLyric(LyricProvider provider, String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final normalized = provider.normalizeLyric(text);
  return normalized.isEmpty ? null : normalized;
}

/// 结构化歌词结果：原文必填，翻译 / 罗马音 / 逐字可选（LRC 或纯文本）。
class LyricsPayload {
  final String lyric;
  final String? translation;
  final String? roma;

  /// 逐字歌词（LX 扩展格式 `<相对开始ms,时长ms>`）。
  final String? lxlyric;

  const LyricsPayload({
    required this.lyric,
    this.translation,
    this.roma,
    this.lxlyric,
  });
}

/// 歌曲匹配结果
class SongMatch {
  final String songId;
  final String title;
  final String artist;

  /// 专辑名（可选，相似度匹配用）。
  final String? album;

  /// 时长（可选，相似度匹配用；缺失视为未知）。
  final Duration? duration;

  /// 平台附带字段（kg: hash/_interval；mg: mrcUrl/lrcUrl/trcUrl；
  /// tx: 数字 songId 等），取词时经 [LyricProvider.fetchForMatch] 透传。
  final Map<String, dynamic> extra;

  SongMatch({
    required this.songId,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.extra = const {},
  });
}

/// 歌词缓存数据。
///
/// [translation] / [roma] / [lxlyric] 为可选扩展字段：缺失时按「无」处理，
/// 写入时仅在非空时落库。
class LyricCacheData {
  final String provider;
  final String lyric;
  final String? translation;
  final String? roma;
  final String? lxlyric;
  final int timestamp;

  /// 用户手动选择（换歌词）的缓存：B 站登录后的同源重试不覆盖它。
  final bool manual;

  LyricCacheData({
    required this.provider,
    required this.lyric,
    this.translation,
    this.roma,
    this.lxlyric,
    required this.timestamp,
    this.manual = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'provider': provider,
      'lyric': lyric,
      if (translation != null) 'translation': translation,
      if (roma != null) 'roma': roma,
      if (lxlyric != null) 'lxlyric': lxlyric,
      if (manual) 'manual': true,
      'ts': timestamp,
    };
  }

  factory LyricCacheData.fromJson(Map<String, dynamic> json) {
    return LyricCacheData(
      provider: json['provider'] as String,
      lyric: json['lyric'] as String,
      translation: json['translation'] as String?,
      roma: json['roma'] as String?,
      lxlyric: json['lxlyric'] as String?,
      manual: json['manual'] == true,
      timestamp: json['ts'] as int,
    );
  }
}
