import 'dart:async';
import 'package:html_unescape/html_unescape.dart';

/// 歌词提供者抽象类
abstract class LyricProvider {
  /// 搜索歌曲，返回平台自己的歌曲ID（单个结果）
  Future<SongMatch?> search(String title, String artist);

  /// 搜索歌曲，返回多个匹配结果
  Future<List<SongMatch>> searchMultiple(String title, String artist, {int limit = 3});

  /// 获取歌词原文 LRC（原始接口，内置歌词搜索页直接消费）。
  ///
  /// 需要翻译 / 罗马音时用 [fetchLyrics] / [getLyrics] 的结构化结果。
  Future<String?> fetchLyric(String songId);

  /// 获取结构化歌词（原文 + 翻译 + 罗马音）；默认回退到 [fetchLyric]。
  Future<LyricsPayload?> fetchLyrics(String songId) async {
    final lyric = await fetchLyric(songId);
    if (lyric == null || lyric.trim().isEmpty) return null;
    return LyricsPayload(lyric: lyric);
  }

  /// 提供者名称
  String get name;

  /// 规范化歌词文本
  String normalizeLyric(String rawLyric) {
    final unescape = HtmlUnescape();
    final decoded = unescape.convert(rawLyric);
    return decoded.replaceAll(RegExp(r'\r?\n+'), '\n').trim();
  }

  /// 获取歌词的完整流程（结构化：原文 + 翻译 + 罗马音）。
  ///
  /// 搜索 → 取词 → 规范化；任一环节失败返回 null（与旧 [getLyric] 语义一致）。
  Future<LyricsPayload?> getLyrics(String title, String artist) async {
    try {
      final songMatch = await search(title, artist);
      if (songMatch == null) return null;

      final payload = await fetchLyrics(songMatch.songId);
      if (payload == null) return null;

      final normalized = LyricsPayload(
        lyric: normalizeLyric(payload.lyric),
        translation: _normalizeOptional(payload.translation),
        roma: _normalizeOptional(payload.roma),
      );
      return normalized.lyric.isEmpty ? null : normalized;
    } catch (e) {
      return null;
    }
  }

  /// 兼容旧接口：仅返回原文。
  Future<String?> getLyric(String title, String artist) async =>
      (await getLyrics(title, artist))?.lyric;

  String? _normalizeOptional(String? text) {
    if (text == null) return null;
    final normalized = normalizeLyric(text);
    return normalized.isEmpty ? null : normalized;
  }
}

/// 结构化歌词结果：原文必填，翻译 / 罗马音可选（LRC 或纯文本）。
class LyricsPayload {
  final String lyric;
  final String? translation;
  final String? roma;

  const LyricsPayload({
    required this.lyric,
    this.translation,
    this.roma,
  });
}

/// 歌曲匹配结果
class SongMatch {
  final String songId;
  final String title;
  final String artist;

  SongMatch({
    required this.songId,
    required this.title,
    required this.artist,
  });
}

/// 歌词缓存数据。
///
/// [translation] / [roma] 为后续版本新增：旧缓存缺失这两个字段时按「无」处理，
/// 写入时仅在非空时落库，保持与旧版本缓存互读。
class LyricCacheData {
  final String provider;
  final String lyric;
  final String? translation;
  final String? roma;
  final int timestamp;

  LyricCacheData({
    required this.provider,
    required this.lyric,
    this.translation,
    this.roma,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'provider': provider,
      'lyric': lyric,
      if (translation != null) 'translation': translation,
      if (roma != null) 'roma': roma,
      'ts': timestamp,
    };
  }

  factory LyricCacheData.fromJson(Map<String, dynamic> json) {
    return LyricCacheData(
      provider: json['provider'] as String,
      lyric: json['lyric'] as String,
      translation: json['translation'] as String?,
      roma: json['roma'] as String?,
      timestamp: json['ts'] as int,
    );
  }
}
