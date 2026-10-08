import 'dart:convert';
import 'dart:math' as math;

import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 网易云歌词结果（对应 LX lyric.js 返回的 `info`）。
class WyLyricInfo {
  /// 原文歌词（含 yrc 转换出的 LRC；带 `[mm:ss.xxx]` 标签）。
  final String lyric;

  /// 翻译歌词（按原文时间轴修正后）。
  final String tlyric;

  /// 罗马音歌词（按原文时间轴修正后）。
  final String rlyric;

  /// 逐字歌词（LX 扩展格式 `<start,end>`，来自 yrc）。
  final String lxlyric;

  const WyLyricInfo({
    this.lyric = '',
    this.tlyric = '',
    this.rlyric = '',
    this.lxlyric = '',
  });

  bool get isEmpty => lyric.isEmpty;
}

/// 网易云歌词获取（移植自 lx-music-mobile `wy/lyric.js`）。
///
/// - eapi `/api/song/lyric/v1` 获取 lrc/tlyric/romalrc/yrc/ytlrc/yromalrc；
/// - [WyLyricParser] 全量移植 parseTools：JSON 逐字行 → LRC / LX 逐字歌词、
///   时间标签修正（`fixTimeLabel`）、翻译/罗马音按时间轴对齐（`fixTimeTag`）。
class WyLyric {
  WyLyric._();

  /// 获取歌词（失败抛 [StateError]，由歌词服务回退到其它提供者）。
  static Future<WyLyricInfo> fetch(String songId) async {
    final body = await lxHttpPost(
      'https://interface3.music.163.com/eapi/song/lyric/v1',
      form: true,
      headers: {'origin': 'https://music.163.com'},
      body: {
        'params': eapiParams('/api/song/lyric/v1', {
          'id': songId,
          'cp': false,
          'tv': 0,
          'lv': 0,
          'rv': 0,
          'kv': 0,
          'yv': 0,
          'ytv': 0,
          'yrv': 0,
        }),
      },
    );
    if (body is! Map || body['code'] != 200) {
      throw StateError('Get lyric failed');
    }
    final lrc = _lyricOf(body['lrc']);
    if (lrc == null || lrc.isEmpty) throw StateError('Get lyric failed');

    final fixed = WyLyricParser.fixTimeLabel(
      lrc,
      _lyricOf(body['tlyric']),
      _lyricOf(body['romalrc']),
    );
    final info = WyLyricParser.parse(
      ylrc: _lyricOf(body['yrc']),
      ytlrc: _lyricOf(body['ytlrc']),
      yrlrc: _lyricOf(body['yromalrc']),
      lrc: fixed.lrc,
      tlrc: fixed.tlrc,
      rlrc: fixed.romalrc,
    );
    if (info.isEmpty) throw StateError('Get lyric failed');
    return info;
  }

  static String? _lyricOf(Object? section) {
    if (section is! Map) return null;
    final lyric = section['lyric'];
    return lyric is String && lyric.isNotEmpty ? lyric : null;
  }
}

/// parseTools 全量移植（纯函数，独立出来便于单元测试）。
class WyLyricParser {
  WyLyricParser._();

  static final RegExp _info = RegExp(r'^{"');
  static final RegExp _lineTime = RegExp(r'^\[(\d+),\d+\]');
  static final RegExp _wordTime = RegExp(r'\(\d+,\d+,\d+\)');
  static final RegExp _wordTimeCaptured = RegExp(r'\((\d+),(\d+),\d+\)');
  static final RegExp _timeMs2 = RegExp(r'\[\d+:\d+\.\d{2}]');
  static final RegExp _timeMs3 = RegExp(r'\[\d+:\d+\.\d{3}]');
  static final RegExp _timeTag = RegExp(r'^\[([\d:.]+)\]');
  static final RegExp _headerTime = RegExp(r'^\[[\d:.]+\]');

  /// 毫秒 → `[mm:ss.xxx]`（pad3=false 时毫秒保留两位，与 LX 一致）。
  static String msFormat(num timeMs, {bool pad3 = true}) {
    if (timeMs.isNaN) return '';
    var ms = (timeMs % 1000).floor().toString().padLeft(pad3 ? 3 : 2, '0');
    if (!pad3 && ms.length > 2) ms = ms.substring(0, 2);
    var time = timeMs / 1000;
    final m = (time / 60).floor().toString().padLeft(2, '0');
    time %= 60;
    final s = time.floor().toString().padLeft(2, '0');
    return '[$m:$s.$ms]';
  }

  /// yrc 行解析：同时产出标准 LRC 与 LX 逐字歌词。
  static ({String lyric, String lxlyric}) parseLyric(List<String> lines) {
    final lxlrcLines = <String>[];
    final lrcLines = <String>[];

    for (var line in lines) {
      line = line.trim();
      final result = _lineTime.firstMatch(line);
      if (result == null) {
        if (line.startsWith('[offset')) {
          lxlrcLines.add(line);
          lrcLines.add(line);
        }
        continue;
      }

      final startMsTime = int.parse(result.group(1)!);
      final startTimeStr = msFormat(startMsTime);
      if (startTimeStr.isEmpty) continue;

      final words = line.replaceFirst(_lineTime, '');
      lrcLines.add('$startTimeStr${words.replaceAll(_wordTime, '')}');

      final times =
          _wordTime.allMatches(words).map((match) => match.group(0)!).toList();
      if (times.isEmpty) continue;
      final converted = times.map((time) {
        final parsed = _wordTimeCaptured.firstMatch(time)!;
        final start = int.parse(parsed.group(1)!);
        final end = parsed.group(2)!;
        return '<${math.max(start - startMsTime, 0)},$end>';
      }).toList();
      final wordArr = words.split(_wordTime)..removeAt(0);
      final newWords = [
        for (var i = 0; i < converted.length; i++)
          '${converted[i]}${i < wordArr.length ? wordArr[i] : ''}',
      ].join();
      lxlrcLines.add('$startTimeStr$newWords');
    }
    return (lyric: lrcLines.join('\n'), lxlyric: lxlrcLines.join('\n'));
  }

  /// 解析 JSON 逐字行（`{"t":...,"c":[{"tx":...}]}`）为带时间标签的行。
  static List<String>? parseHeaderInfo(String str) {
    str = str.trim().replaceAll('\r', '');
    if (str.isEmpty) return null;
    final isPad3 = _timeMs3.hasMatch(str) || !_timeMs2.hasMatch(str);
    return str.split('\n').map((line) {
      if (!_info.hasMatch(line)) return line;
      try {
        final info = jsonDecode(line);
        if (info is! Map) return '';
        final t = info['t'];
        final timeTag = t is num ? msFormat(t, pad3: isPad3) : '';
        if (timeTag.isEmpty) return '';
        final content = info['c'];
        if (content is! List) return '';
        final text = content
            .whereType<Map>()
            .map((part) => (part['tx'] ?? '').toString())
            .join();
        return '$timeTag$text';
      } catch (_) {
        return '';
      }
    }).toList();
  }

  /// `[mm:ss.xxx]` / `mm:ss.xxx` → 毫秒。
  static int getIntv(String interval) {
    if (interval.isEmpty) return 0;
    var text = interval;
    if (!text.contains('.')) text += '.0';
    final arr = text.split(RegExp(r'[:.]'));
    while (arr.length < 3) {
      arr.insert(0, '0');
    }
    final m = int.tryParse(arr[0]) ?? 0;
    final s = int.tryParse(arr[1]) ?? 0;
    final ms = int.tryParse(arr[2]) ?? 0;
    return m * 3600000 + s * 1000 + ms;
  }

  /// 以 [targetlrc] 的行序为准，把时间标签替换为 [lrc] 中最近（<100ms）的时间。
  static String fixTimeTag(String lrc, String targetlrc) {
    var lrcLines = lrc.split('\n');
    final targetlrcLines = targetlrc.split('\n');
    var temp = <String>[];
    final newLrc = <String>[];
    for (final line in targetlrcLines) {
      final result = _timeTag.firstMatch(line);
      if (result == null) continue;
      final words = line.replaceFirst(_timeTag, '');
      if (words.trim().isEmpty) continue;
      final t1 = getIntv(result.group(1)!);

      while (lrcLines.isNotEmpty) {
        final lrcLine = lrcLines.removeAt(0);
        final lrcLineResult = _timeTag.firstMatch(lrcLine);
        if (lrcLineResult == null) continue;
        final t2 = getIntv(lrcLineResult.group(1)!);
        if ((t1 - t2).abs() < 100) {
          final fixed = line.replaceFirst(_timeTag, lrcLineResult.group(0)!).trim();
          if (fixed.isEmpty) continue;
          newLrc.add(fixed);
          break;
        }
        temp.add(lrcLine);
      }
      lrcLines = [...temp, ...lrcLines];
      temp = [];
    }
    return newLrc.join('\n');
  }

  /// 汇总解析（对应 LX parseTools.parse）。
  static WyLyricInfo parse({
    String? ylrc,
    String? ytlrc,
    String? yrlrc,
    String? lrc,
    String? tlrc,
    String? rlrc,
  }) {
    var lyric = '';
    var tlyric = '';
    var rlyric = '';
    var lxlyric = '';

    if (ylrc != null && ylrc.isNotEmpty) {
      final lines = parseHeaderInfo(ylrc);
      if (lines != null) {
        final result = parseLyric(lines);
        if (ytlrc != null && ytlrc.isNotEmpty) {
          final tlrcLines = parseHeaderInfo(ytlrc);
          if (tlrcLines != null) {
            tlyric = fixTimeTag(result.lyric, tlrcLines.join('\n'));
          }
        }
        if (yrlrc != null && yrlrc.isNotEmpty) {
          final rlrcLines = parseHeaderInfo(yrlrc);
          if (rlrcLines != null) {
            rlyric = fixTimeTag(result.lyric, rlrcLines.join('\n'));
          }
        }
        final headers =
            lines.where((line) => _headerTime.hasMatch(line)).join('\n');
        lyric = '$headers\n${result.lyric}';
        lxlyric = result.lxlyric;
        return WyLyricInfo(
          lyric: lyric,
          tlyric: tlyric,
          rlyric: rlyric,
          lxlyric: lxlyric,
        );
      }
    }

    if (lrc != null && lrc.isNotEmpty) {
      final lines = parseHeaderInfo(lrc);
      if (lines != null) lyric = lines.join('\n');
    }
    if (tlrc != null && tlrc.isNotEmpty) {
      final lines = parseHeaderInfo(tlrc);
      if (lines != null) tlyric = lines.join('\n');
    }
    if (rlrc != null && rlrc.isNotEmpty) {
      final lines = parseHeaderInfo(rlrc);
      if (lines != null) rlyric = lines.join('\n');
    }
    return WyLyricInfo(
      lyric: lyric,
      tlyric: tlyric,
      rlyric: rlyric,
      lxlyric: lxlyric,
    );
  }

  /// 时间标签修正（LX `fixTimeLabel`）：
  /// 老接口存在 `[mm:ss:xx]` 三段时间标签，统一为 `[mm:ss.xx]`。
  static ({String? lrc, String? tlrc, String? romalrc}) fixTimeLabel(
    String? lrc,
    String? tlrc,
    String? romalrc,
  ) {
    if (lrc != null && lrc.isNotEmpty) {
      // Dart 的 replaceAll 不做 `$1` 展开，必须用 replaceAllMapped。
      final newLrc = lrc.replaceAllMapped(
          RegExp(r'\[(\d{2}:\d{2}):(\d{2})\]'), (m) => '[${m[1]}.${m[2]}]');
      final newTlrc = tlrc?.replaceAllMapped(
          RegExp(r'\[(\d{2}:\d{2}):(\d{2})\]'), (m) => '[${m[1]}.${m[2]}]');
      if (newLrc != lrc || newTlrc != tlrc) {
        lrc = newLrc;
        tlrc = newTlrc;
        if (romalrc != null && romalrc.isNotEmpty) {
          romalrc = romalrc
              .replaceAllMapped(RegExp(r'\[(\d{2}:\d{2}):(\d{2,3})\]'),
                  (m) => '[${m[1]}.${m[2]}]')
              .replaceAllMapped(RegExp(r'\[(\d{2}:\d{2}\.\d{2})0\]'),
                  (m) => '[${m[1]}]');
        }
      }
    }
    return (lrc: lrc, tlrc: tlrc, romalrc: romalrc);
  }
}
