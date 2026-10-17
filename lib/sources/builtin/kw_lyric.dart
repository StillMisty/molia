import 'dart:convert';
import 'dart:typed_data';

import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'lyric_result.dart';
import 'zlib_io.dart' as zlib_impl;

/// 酷我歌词获取（移植自 lx-music-mobile `kw/lyric.js` + `kw/decodeLyric.js`
/// + `kw/util.js` 的 lrcTools）。
///
/// - 主路径：`mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=<songmid>`，
///   响应为 `TP=content` 包头的二进制（zlib → base64 → `yeelion` XOR）；
/// - 行内 `<a,b[,c]>` 词时间按 `[kuwo:...]` 八进制偏移换算为 LX `<start,dur>`；
/// - 重复时间行的后一次出现视为翻译行（带逐字标记 `isLyricx` 时）；
/// - 兜底：`m.kuwo.cn/newh5/singles/songinfoandlrc`（平台 H5 JSON 接口）。
class KwLyric {
  KwLyric._();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// 逐字歌词 XOR key（`Buffer.from('yeelion')`，7 字节）。
  static const List<int> _yeelion = [121, 101, 101, 108, 105, 111, 110];

  static final RegExp _timeExp = RegExp(r'^\[([\d:.]*)\]');
  static final RegExp _twoDigitMs = RegExp(r'\.\d\d$');
  static final RegExp _tagLine = RegExp(
    r'\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*\]',
  );
  static final RegExp _wordLine = RegExp(
    r'^(\[\d{1,2}:.*\d{1,4}\])\s*(\S+(?:\s+\S+)*)?\s*',
  );
  static final RegExp _wordTimeAll = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');
  static final RegExp _wordTime = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');
  static final RegExp _lyricxTag = RegExp(r'^<-?\d+,-?\d+>');
  static final RegExp _existTimeExp = RegExp(r'\[\d{1,2}:.*\d{1,4}\]');

  /// 获取歌词；失败返回 null（由调用方回退其它来源）。
  static Future<BuiltinLyricResult?> fetch(String songmid) async {
    try {
      final bytes = await lxHttpGetBytes(
        'http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1'
        '&rid=$songmid&encode=utf8',
        headers: _headers,
        retries: BuiltinTransport.defaultRetries,
      );
      final text = _decodeLrcx(bytes);
      if (text != null && text.isNotEmpty) {
        final parsed = _parseLrcxText(text);
        if (parsed != null && !parsed.isEmpty) return parsed;
      }
    } catch (_) {
      // 主路径失败：走 H5 兜底。
    }
    return _fetchH5(songmid);
  }

  /// `TP=content` 二进制解码：zlib → base64 → `yeelion` XOR（lrcx=1）。
  static String? _decodeLrcx(Uint8List buf) {
    if (buf.length < 10) return null;
    final head =
        utf8.decode(buf.sublist(0, 10), allowMalformed: true).toLowerCase();
    if (head != 'tp=content') return null;
    final sep = _indexOfBytes(buf, const [13, 10, 13, 10]);
    if (sep < 0) return null;
    try {
      final inflated = zlib_impl.zlibInflate(
        Uint8List.fromList(buf.sublist(sep + 4)),
      );
      final base64Text = utf8.decode(inflated, allowMalformed: true);
      final inner = base64.decode(base64Text.replaceAll(RegExp(r'\s'), ''));
      final out = Uint8List(inner.length);
      for (var i = 0; i < inner.length; i++) {
        out[i] = inner[i] ^ _yeelion[i % _yeelion.length];
      }
      return utf8.decode(out, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// lrcx 文本 → 结构化歌词（对照 LX `parseLrc` + `getLyric` 的收尾处理）。
  static BuiltinLyricResult? _parseLrcxText(String lrc) {
    final lines = lrc.split(RegExp(r'\r\n|\r|\n'));
    final tags = <String>[];
    final items = <_KwLrcItem>[];
    for (var line in lines) {
      line = line.trim();
      final match = _timeExp.firstMatch(line);
      if (match != null) {
        var time = match.group(1) ?? '';
        final text = line.replaceAll(_timeExp, '').trim();
        if (_twoDigitMs.hasMatch(time)) time += '0';
        if (time.isNotEmpty) items.add(_KwLrcItem(time, text));
      } else if (_tagLine.hasMatch(line)) {
        tags.add(line);
      }
    }

    final sorted = _sortLrcArr(items, guardLyricxHeuristic: true);
    final lyricRaw = _transformLrc(tags, sorted.lrc);
    String? lxlyric;
    try {
      lxlyric = _convertWordTags(lyricRaw);
    } catch (_) {
      lxlyric = null;
    }
    final lyric = decodeName(lyricRaw.replaceAll(_wordTimeAll, '')).trim();
    if (lyric.isEmpty || !_existTimeExp.hasMatch(lyric)) return null;

    final tlyricRaw = sorted.trans.isEmpty ? null : _transformLrc(tags, sorted.trans);
    return BuiltinLyricResult(
      lyric: lyric,
      tlyric: tlyricRaw == null
          ? null
          : decodeName(tlyricRaw.replaceAll(_wordTimeAll, '')).trim(),
      lxlyric: (lxlyric == null || lxlyric.isEmpty)
          ? null
          : decodeName(lxlyric).trim(),
    );
  }

  /// H5 JSON 兜底：`data.songinfo` + `data.lrclist`。
  static Future<BuiltinLyricResult?> _fetchH5(String songmid) async {
    try {
      final json = await lxHttpGet(
        'http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=$songmid',
        headers: _headers,
        retries: BuiltinTransport.defaultRetries,
        retryIf: (value) => value is! Map,
      );
      if (json is! Map) return null;
      final data = json['data'];
      final rawList = data is Map ? data['lrclist'] : null;
      if (rawList is! List || rawList.isEmpty) return null;
      final songinfo = data is Map ? data['songinfo'] : null;

      final items = <_KwLrcItem>[];
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final seconds = raw['time'] is num
            ? (raw['time'] as num).toDouble()
            : double.tryParse('${raw['time']}') ?? 0;
        items.add(_KwLrcItem(
          _formatH5Time(seconds),
          raw['lineLyric']?.toString() ?? '',
        ));
      }
      final sorted = _sortLrcArr(items, guardLyricxHeuristic: false);
      final tags = <String>[];
      if (songinfo is Map) {
        tags.addAll([
          '[ti:${songinfo['songName'] ?? ''}]',
          '[ar:${songinfo['artist'] ?? ''}]',
          '[al:${songinfo['album'] ?? ''}]',
          '[by:]',
          '[offset:0]',
        ]);
      }
      final lyric = decodeName(_transformLrc(tags, sorted.lrc)).trim();
      if (lyric.isEmpty || !_existTimeExp.hasMatch(lyric)) return null;
      final tlyricRaw =
          sorted.trans.isEmpty ? null : _transformLrc(tags, sorted.trans);
      return BuiltinLyricResult(
        lyric: lyric,
        tlyric: tlyricRaw == null ? null : decodeName(tlyricRaw).trim(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 重复时间行拆分（对照 LX `sortLrcArr`）：
  /// 同一时间的后一次出现回退为前一行的翻译行。
  ///
  /// [guardLyricxHeuristic] 为 lrcx 场景的防误判：正文无逐字标记、
  /// 但「翻译行」占比过半时视为文本重复而非翻译（此时丢弃翻译保留原文，
  /// 与 LX 的 reject 相比更稳健——至少歌词可用）。
  static _KwLrcSorted _sortLrcArr(
    List<_KwLrcItem> arr, {
    required bool guardLyricxHeuristic,
  }) {
    final seen = <String>{};
    final lrc = <_KwLrcItem>[];
    final trans = <_KwLrcItem>[];
    var isLyricx = false;
    for (final item in arr) {
      if (seen.contains(item.time)) {
        if (lrc.length < 2) continue;
        final tItem = lrc.removeLast();
        tItem.time = lrc.last.time;
        trans.add(tItem);
        lrc.add(item);
      } else {
        lrc.add(item);
        seen.add(item.time);
      }
      if (!isLyricx && _lyricxTag.hasMatch(item.text)) isLyricx = true;
    }
    if (guardLyricxHeuristic &&
        !isLyricx &&
        trans.length > lrc.length * 0.3 &&
        lrc.length - trans.length > 6) {
      return _KwLrcSorted(lrc: lrc, trans: const []);
    }
    return _KwLrcSorted(lrc: lrc, trans: trans);
  }

  /// 对照 LX `transformLrc`：标签行 + 时间行（`[time]text`）。
  static String _transformLrc(List<String> tags, List<_KwLrcItem> list) {
    final buffer = StringBuffer(tags.join('\n'));
    if (tags.isNotEmpty) buffer.write('\n');
    if (list.isEmpty) {
      buffer.write('暂无歌词');
      return buffer.toString();
    }
    for (final item in list) {
      buffer.write('[${item.time}]${item.text}\n');
    }
    return buffer.toString();
  }

  /// 对照 LX `lrcTools.parse`：把 `<a,b[,c]>` 词时间换算为 LX `<start,dur>`。
  ///
  /// `[kuwo:...]` 八进制值给出行内偏移参数（offset / offset2）；
  /// 前一词的结束时间会按后一词开始时间裁剪。
  static String? _convertWordTags(String lrc) {
    final lines = lrc.split(RegExp(r'\r\n|\r|\n'));
    var offset = 1;
    var offset2 = 1;
    final out = <String>[];
    final tags = <String>[];
    for (final line in lines) {
      if (line.length < 6) continue;
      final wordLine = _wordLine.firstMatch(line);
      if (wordLine != null) {
        final time = wordLine.group(1)!;
        var words = wordLine.group(2) ?? '';
        final wordTimes =
            _wordTimeAll.allMatches(words).map((m) => m.group(0)!).toList();
        if (wordTimes.isEmpty) continue;
        _KwWordInfo? previous;
        for (final timeStr in wordTimes) {
          final match = _wordTime.firstMatch(timeStr);
          if (match == null) continue;
          final info = _wordInfo(
            match.group(1)!,
            match.group(2)!,
            previous,
            offset,
            offset2,
          );
          words = words.replaceFirst(timeStr, info.timeStr);
          final prev = previous;
          if (prev?.newTimeStr != null) {
            words = words.replaceFirst(prev!.timeStr, prev.newTimeStr!);
          }
          previous = info;
        }
        out.add('$time$words');
        continue;
      }
      final tag = _tagLine.firstMatch(line);
      if (tag == null) continue;
      if (tag.group(1) == 'kuwo') {
        var content = tag.group(2) ?? '';
        if (content.contains('][')) {
          content = content.substring(0, content.indexOf(']['));
        }
        final value = int.tryParse(content, radix: 8);
        if (value == null) return null;
        offset = value ~/ 10;
        offset2 = value % 10;
        if (offset == 0 || offset2 == 0) return null;
      } else {
        tags.add(line);
      }
    }
    if (out.isEmpty) return '';
    final buffer = StringBuffer();
    if (tags.isNotEmpty) buffer.writeln(tags.join('\n'));
    buffer.write(out.join('\n'));
    return buffer.toString();
  }

  static _KwWordInfo _wordInfo(
    String str,
    String str2,
    _KwWordInfo? previous,
    int offset,
    int offset2,
  ) {
    final a = int.tryParse(str) ?? 0;
    final b = int.tryParse(str2) ?? 0;
    var startTime = ((a + b).abs() / (offset * 2)).truncate();
    var endTime = ((a - b).abs() / (offset2 * 2)).truncate() + startTime;
    if (previous != null && startTime < previous.endTime) {
      previous.endTime = startTime;
      if (previous.startTime > previous.endTime) {
        previous.startTime = previous.endTime;
      }
      previous.newTimeStr =
          '<${previous.startTime},${previous.endTime - previous.startTime}>';
    }
    return _KwWordInfo(
      startTime,
      endTime,
      '<$startTime,${endTime - startTime}>',
    );
  }

  /// H5 兜底时间格式（`mm:ss.xx`）。
  static String _formatH5Time(double seconds) {
    var m = seconds ~/ 60;
    var s = seconds % 60;
    final mText = m < 10 ? '0$m' : '$m';
    final sText = s < 10 ? '0${s.toStringAsFixed(2)}' : s.toStringAsFixed(2);
    return '$mText:$sText';
  }

  static int _indexOfBytes(Uint8List data, List<int> pattern) {
    for (var i = 0; i + pattern.length <= data.length; i++) {
      var found = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }
}

class _KwLrcItem {
  _KwLrcItem(this.time, this.text);

  /// `mm:ss.xxx`（lrcx）或 `mm:ss.xx`（H5）。
  String time;
  String text;
}

class _KwLrcSorted {
  const _KwLrcSorted({required this.lrc, required this.trans});

  final List<_KwLrcItem> lrc;
  final List<_KwLrcItem> trans;
}

class _KwWordInfo {
  _KwWordInfo(this.startTime, this.endTime, this.timeStr);

  int startTime;
  int endTime;
  final String timeStr;
  String? newTimeStr;
}
