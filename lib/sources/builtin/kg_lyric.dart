import 'dart:convert';
import 'dart:typed_data';

import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'lyric_result.dart';
import 'zlib_stub.dart' if (dart.library.io) 'zlib_io.dart' as zlib_impl;

/// 酷狗歌词获取（移植自 lx-music-mobile `kg/lyric.js` + `kg/util.js`）。
///
/// - `lyrics.kugou.com/search` 用歌名 + 文件 hash + 时长匹配歌词候选；
/// - `/download` 拿 KRC（zlib + 16 字节 XOR）或 LRC（base64）；
/// - KRC 头部的 `[language:...]` 附带翻译 / 罗马音，行内 `<start,dur,0>` 为
///   逐字时间轴（输出统一为 LX `<start,dur>` 格式）。
///
/// 搜索接口对请求头有校验（KG-RC / KG-THash / UA），缺一可能返回 403。
class KgLyric {
  KgLyric._();

  static const Map<String, String> _headers = {
    'KG-RC': '1',
    'KG-THash': 'expand_search_manager.cpp:852736169:451',
    'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
  };

  /// KRC 解码用的 16 字节 key（LX `kg/util.js` 原样）。
  static const List<int> _encKey = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
    0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
  ];

  /// KRC 头部 `[id:$xxxx]` 行（LX `headExp`，仅单行匹配）。
  static final RegExp _idHeader = RegExp(r'^.*\[id:\$\w+\]\r?\n?');

  static final RegExp _languageTag = RegExp(r'\[language:([\w=\\/+]+)\]');
  static final RegExp _languageLine = RegExp(r'\[language:[\w=\\/+]+\]\r?\n?');
  static final RegExp _lineTime = RegExp(r'^\[(\d+),\d+\]');
  static final RegExp _wordTime = RegExp(r'<(\d+),(\d+),\d+>');

  /// 获取歌词；失败返回 null（由调用方回退其它来源）。
  ///
  /// [timelengthSeconds] 为 LX `musicInfo._interval`（秒）。
  static Future<BuiltinLyricResult?> fetch({
    required String name,
    required String hash,
    required int timelengthSeconds,
  }) async {
    final searchUrl = 'http://lyrics.kugou.com/search?ver=1&man=yes&client=pc'
        '&keyword=${Uri.encodeComponent(name)}'
        '&hash=$hash&timelength=$timelengthSeconds&lrctxt=1';
    final search = await lxHttpGet(
      searchUrl,
      headers: _headers,
      retries: BuiltinTransport.defaultRetries,
      retryIf: (json) => json is! Map,
    );
    final candidates = search is Map ? search['candidates'] : null;
    if (candidates is! List || candidates.isEmpty) return null;
    final info = candidates.first;
    if (info is! Map) return null;
    final fmt =
        (info['krctype'] == 1 && info['contenttype'] != 1) ? 'krc' : 'lrc';

    final downloadUrl = 'http://lyrics.kugou.com/download?ver=1&client=pc'
        '&id=${info['id']}&accesskey=${info['accesskey']}'
        '&fmt=$fmt&charset=utf8';
    final download = await lxHttpGet(
      downloadUrl,
      headers: _headers,
      retries: BuiltinTransport.defaultRetries,
      retryIf: (json) => json is! Map,
    );
    if (download is! Map) return null;
    final content = download['content'];
    if (content is! String || content.isEmpty) return null;
    final actualFmt = download['fmt']?.toString() ?? fmt;

    if (actualFmt == 'krc') {
      final text = _decodeKrc(content);
      if (text == null || text.trim().isEmpty) return null;
      return _parseKrc(text);
    }
    try {
      return BuiltinLyricResult(
        lyric: utf8.decode(base64.decode(content), allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// KRC 解码：base64 → 去前 4 字节 → 16 字节 key 循环 XOR → zlib。
  static String? _decodeKrc(String content) {
    try {
      final decoded = base64.decode(content);
      if (decoded.length <= 4) return null;
      final buf = Uint8List.fromList(decoded.sublist(4));
      for (var i = 0; i < buf.length; i++) {
        buf[i] ^= _encKey[i % 16];
      }
      final inflated = zlib_impl.zlibInflate(buf);
      return utf8.decode(inflated, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// KRC 正文解析（对照 LX `parseLyric`）：
  /// `[start,dur]` 行时间 → `[mm:ss.mmm]`；`<start,dur,0>` 词时间 → `<start,dur>`；
  /// `[language:...]` base64 JSON 内 `type:0` = 罗马音、`type:1` = 翻译。
  static BuiltinLyricResult _parseKrc(String raw) {
    var str = raw.replaceAll('\r', '');
    str = str.replaceFirst(_idHeader, '');

    List<List<String>>? rlyric;
    List<List<String>>? tlyric;
    final language = _languageTag.firstMatch(str);
    if (language != null) {
      str = str.replaceFirst(_languageLine, '');
      try {
        final json = jsonDecode(utf8.decode(base64.decode(language.group(1)!)));
        final content = json is Map ? json['content'] : null;
        if (content is List) {
          for (final item in content) {
            if (item is! Map) continue;
            final lines = _normalizeLyricContent(item['lyricContent']);
            if (lines == null) continue;
            switch (item['type']) {
              case 0:
                rlyric = lines;
              case 1:
                tlyric = lines;
            }
          }
        }
      } catch (_) {
        // language 段损坏：忽略翻译/罗马音。
      }
    }

    final tlyricLines = tlyric == null ? null : <String>[];
    final rlyricLines = rlyric == null ? null : <String>[];
    final lineBuilder = StringBuffer();
    var index = 0;
    for (var line in str.split('\n')) {
      line = line.trim();
      final match = _lineTime.firstMatch(line);
      if (match == null) {
        lineBuilder.writeln(line);
        continue;
      }
      final startMs = int.tryParse(match.group(1)!);
      if (startMs == null) {
        lineBuilder.writeln(line);
        continue;
      }
      final timeTag = msFormat(startMs);
      if (rlyric != null) {
        rlyricLines!.add('$timeTag${_lineContentOf(rlyric, index)}');
      }
      if (tlyric != null) {
        tlyricLines!.add('$timeTag${_lineContentOf(tlyric, index)}');
      }
      index++;
      lineBuilder.writeln('$timeTag${line.substring(match.end)}');
    }

    var lxlyric = lineBuilder.toString();
    lxlyric = lxlyric.replaceAllMapped(
      _wordTime,
      (m) => '<${m.group(1)},${m.group(2)}>',
    );
    lxlyric = decodeName(lxlyric).trim();
    final lyric = lxlyric.replaceAll(RegExp(r'<\d+,\d+>'), '').trim();
    if (lyric.isEmpty) {
      return const BuiltinLyricResult(lyric: '');
    }
    return BuiltinLyricResult(
      lyric: lyric,
      tlyric: tlyricLines == null ? null : decodeName(tlyricLines.join('\n')).trim(),
      rlyric: rlyricLines == null ? null : decodeName(rlyricLines.join('\n')).trim(),
      lxlyric: lxlyric,
    );
  }

  /// 取翻译/罗马音第 [index] 行的文本（缺失按空串，与 LX `?.join('') ?? ''` 一致）。
  static String _lineContentOf(List<List<String>> lines, int index) {
    if (index >= lines.length) return '';
    return lines[index].join();
  }

  /// `[language:...]` 的 `lyricContent` 归一化为「每行 = 片段列表」。
  static List<List<String>>? _normalizeLyricContent(Object? content) {
    if (content is! List) return null;
    return [
      for (final line in content)
        if (line is List)
          [for (final part in line) part.toString()]
        else if (line is String)
          [line]
        else
          const <String>[],
    ];
  }
}

