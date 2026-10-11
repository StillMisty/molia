import 'dart:convert';

import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'lyric_result.dart';
import 'tx_qrc.dart';

/// QQ 音乐歌词获取（移植自 lx-music-mobile `tx/lyric.js`）。
///
/// - `music.musichallSong.PlayLyricInfo.GetPlayLyricInfo` 一次取回
///   原文 / 翻译 / 罗马音（`crypt: 1` 时均为 hex QRC，需 [TxQrc.decode]）；
/// - 数字 `songID` 优先（LX 约定），缺失时回退 `songMID`；
/// - QRC 逐字格式 `(词开始ms,词时长)` → LX `<相对开始ms,时长>`；
/// - 翻译 / 罗马音按原文时间轴做 <100ms 匹配修正（`fixTlrcTimeTag`）。
class TxLyric {
  TxLyric._();

  static const String _url = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

  static final RegExp _lineTime = RegExp(r'^\[(\d+),\d+\]');
  static final RegExp _lineTime2 = RegExp(r'^\[([\d:.]+)\]');
  static final RegExp _wordAll = RegExp(r'\((\d+),(\d+)\)');
  static final RegExp _word = RegExp(r'\(\d+,\d+\)');

  /// 获取歌词；失败返回 null（由调用方回退其它来源）。
  ///
  /// [songId] 为数字歌曲 ID（优先），[songMid] 为字符串 songmid（兜底）。
  static Future<BuiltinLyricResult?> fetch({
    String? songId,
    String? songMid,
  }) async {
    final param = <String, dynamic>{
      'format': 'json',
      'crypt': 1,
      'ct': 19,
      'cv': 1873,
      'interval': 0,
      'lrc_t': 0,
      'qrc': 1,
      'qrc_t': 0,
      'roma': 1,
      'roma_t': 0,
      'trans': 1,
      'trans_t': 0,
      'type': -1,
    };
    if (songId != null && songId.isNotEmpty) {
      param['songID'] = int.tryParse(songId) ?? songId;
    } else if (songMid != null && songMid.isNotEmpty) {
      param['songMID'] = songMid;
    } else {
      return null;
    }

    final body = jsonEncode({
      'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
      'req': {
        'method': 'GetPlayLyricInfo',
        'module': 'music.musichallSong.PlayLyricInfo',
        'param': param,
      },
    });
    final response = await lxHttpPost(
      _url,
      body: body,
      headers: {
        'referer': 'https://y.qq.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: (json) =>
          json is! Map || json['code'] != 0 || json['req'] is! Map,
    );
    if (response is! Map || response['code'] != 0) return null;
    final req = response['req'];
    if (req is! Map || req['code'] != 0) return null;
    final data = req['data'];
    if (data is! Map) return null;

    final lyric = _decodeMaybe(data['lyric']);
    if (lyric == null || lyric.trim().isEmpty) return null;
    final info = parse(
      lyric,
      _decodeMaybe(data['trans']),
      _decodeMaybe(data['roma']),
    );
    if (info.isEmpty) return null;
    return info;
  }

  /// 解码单个字段：明文 LRC / QRC hex / 旧接口 base64 明文。
  static String? _decodeMaybe(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final text = value.trim();
    if (text.startsWith('[')) return text;
    final qrc = TxQrc.decode(text);
    if (qrc != null && qrc.contains('[')) return qrc;
    try {
      final decoded = utf8.decode(
        base64.decode(text.replaceAll(RegExp(r'\s'), '')),
        allowMalformed: true,
      );
      if (decoded.contains('[')) return decoded;
    } catch (_) {
      // 非 base64：忽略。
    }
    return null;
  }

  /// QRC 正文解析（对照 LX `parseTools.parse`）。
  static BuiltinLyricResult parse(String? lrc, String? tlrc, String? rlrc) {
    var lyric = '';
    var lxlyric = '';
    if (lrc != null && lrc.isNotEmpty) {
      final parsed = _parseLyric(_removeTag(lrc));
      lyric = parsed.lyric;
      lxlyric = parsed.lxlyric;
    }
    var tlyric = '';
    var rlyric = '';
    if (rlrc != null && rlrc.isNotEmpty) {
      rlyric = _fixRlrcTimeTag(_parseRlyric(_removeTag(rlrc)), lyric);
    }
    if (tlrc != null && tlrc.isNotEmpty) {
      tlyric = _fixTlrcTimeTag(tlrc, lyric);
    }
    return BuiltinLyricResult(
      lyric: lyric,
      tlyric: tlyric.isEmpty ? null : tlyric,
      rlyric: rlyric.isEmpty ? null : rlyric,
      lxlyric: lxlyric.isEmpty ? null : lxlyric,
    );
  }

  /// 去除 QRC XML 包装，取 `LyricContent="..."` 属性内容。
  static String _removeTag(String str) {
    var result = str.replaceFirst(RegExp(r'^[\S\s]*?LyricContent="'), '');
    result = result.replaceFirst(RegExp(r'/"\/>[\S\s]*?$'), '');
    return result;
  }

  static ({String lyric, String lxlyric}) _parseLyric(String raw) {
    final text = raw.trim().replaceAll('\r', '');
    if (text.isEmpty) return (lyric: '', lxlyric: '');
    final lxLines = <String>[];
    final lrcLines = <String>[];
    for (var line in text.split('\n')) {
      line = line.trim();
      final match = _lineTime.firstMatch(line);
      if (match == null) {
        if (line.startsWith('[offset')) {
          lxLines.add(line);
          lrcLines.add(line);
        }
        if (_lineTime2.hasMatch(line)) {
          lrcLines.add(line);
        }
        continue;
      }
      final startMs = int.tryParse(match.group(1)!);
      if (startMs == null) continue;
      final timeTag = msFormat(startMs);
      final words = line.substring(match.end);

      lrcLines.add('$timeTag${words.replaceAll(_word, '')}');

      final times = _wordAll.allMatches(words).map((m) => m.group(0)!).toList();
      if (times.isEmpty) continue;
      final converted = [
        for (final time in times)
          () {
            final pair = _wordAll.firstMatch(time)!;
            final start = int.parse(pair.group(1)!);
            return '<${(start - startMs < 0 ? 0 : start - startMs)},'
                '${pair.group(2)}>';
          }(),
      ];
      final wordArr = words.split(_word);
      final newWords = [
        for (var i = 0; i < converted.length; i++)
          '${converted[i]}${i < wordArr.length ? wordArr[i] : ''}',
      ].join();
      lxLines.add('$timeTag$newWords');
    }
    return (lyric: lrcLines.join('\n'), lxlyric: lxLines.join('\n'));
  }

  static String _parseRlyric(String raw) {
    final text = raw.trim().replaceAll('\r', '');
    if (text.isEmpty) return '';
    final lrcLines = <String>[];
    for (var line in text.split('\n')) {
      line = line.trim();
      final match = _lineTime.firstMatch(line);
      if (match == null) continue;
      final startMs = int.tryParse(match.group(1)!);
      if (startMs == null) continue;
      final timeTag = msFormat(startMs);
      final words = line.substring(match.end);
      lrcLines.add('$timeTag${words.replaceAll(_word, '')}');
    }
    return lrcLines.join('\n');
  }

  /// `[mm:ss.xx]` → 毫秒（LX `getIntv`）。
  static int _getIntv(String interval) {
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

  static String _fixRlrcTimeTag(String rlrc, String lrc) {
    final rlrcLines = rlrc.split('\n');
    var lrcLines = lrc.split('\n');
    final newLrc = <String>[];
    for (final line in rlrcLines) {
      final result = _lineTime2.firstMatch(line);
      if (result == null) continue;
      final words = line.replaceFirst(_lineTime2, '');
      if (words.trim().isEmpty) continue;
      final t1 = _getIntv(result.group(1)!);
      while (lrcLines.isNotEmpty) {
        final lrcLine = lrcLines.removeAt(0);
        final lrcLineResult = _lineTime2.firstMatch(lrcLine);
        if (lrcLineResult == null) continue;
        final t2 = _getIntv(lrcLineResult.group(1)!);
        if ((t1 - t2).abs() < 100) {
          newLrc.add(line.replaceFirst(_lineTime2, lrcLineResult.group(0)!));
          break;
        }
      }
    }
    return newLrc.join('\n');
  }

  static String _fixTlrcTimeTag(String tlrc, String lrc) {
    final tlrcLines = tlrc.split('\n');
    var lrcLines = lrc.split('\n');
    final newLrc = <String>[];
    for (final line in tlrcLines) {
      final result = _lineTime2.firstMatch(line);
      if (result == null) continue;
      final words = line.replaceFirst(_lineTime2, '');
      if (words.trim().isEmpty) continue;
      var time = result.group(1)!;
      if (time.contains('.')) {
        final fraction = time.split('.')[1];
        if (fraction.length < 3) time += '0' * (3 - fraction.length);
      }
      final t1 = _getIntv(time);
      while (lrcLines.isNotEmpty) {
        final lrcLine = lrcLines.removeAt(0);
        final lrcLineResult = _lineTime2.firstMatch(lrcLine);
        if (lrcLineResult == null) continue;
        final t2 = _getIntv(lrcLineResult.group(1)!);
        if ((t1 - t2).abs() < 100) {
          newLrc.add(line.replaceFirst(_lineTime2, lrcLineResult.group(0)!));
          break;
        }
      }
    }
    return newLrc.join('\n');
  }
}
