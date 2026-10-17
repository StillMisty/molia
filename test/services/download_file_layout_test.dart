/// 下载文件命名 / 放置模块：模板 → 基名 → 去重 → sidecar 路径的唯一实现。
///
/// 这里打的是**生产实现**（下载链路真正调用的 `DownloadFileLayout`）——
/// 此前 `DownloadService.baseNameFor` 是 `_baseNameFor` 的手写双胞胎，两者在
/// 「无歌手」时命名不同（双胞胎只留歌名），测的不是生产路径；双胞胎已删除，
/// 命名行为在这里钉住。
///
/// 真依赖（`FakeDownloadStorage` + 真 `DownloadSettings`）：只经公开接口断言
/// 基名 / 路径 / 写入结果，不读私有字段。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/downloads/download_storage.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_file_layout.dart';
import 'package:molia/services/download/download_settings.dart';

import '../support/fake_download_storage.dart';

void main() {
  late FakeDownloadStorage storage;
  late DownloadFileLayout layout;

  Track makeTrack({String title = '测试歌曲', String artist = '歌手'}) => Track(
        id: const TrackId('kw', '1'),
        title: title,
        artists: artist.isEmpty ? const [] : [Artist(name: artist)],
        album: '专辑',
        origin: TrackOrigin.builtin,
      );

  setUp(() {
    storage = FakeDownloadStorage();
    layout = DownloadFileLayout(storage: storage);
  });

  test('基名：按设置模板生成并清洗（未设设置 = 默认模板）', () {
    expect(
      layout.baseNameFor(makeTrack(title: 'A/B:C*D?E"F<G>H|I')),
      '歌手 - A_B_C_D_E_F_G_H_I',
    );
    // 无歌手：默认模板保留 `- ` 前缀——这是下载路径真正使用的实现的行为，
    // 不在这里另做「无歌手只用歌名」的隐式兜底。
    expect(
      layout.baseNameFor(makeTrack(title: '  多   空格  ', artist: '')),
      '- 多 空格',
    );
  });

  test('基名：自定义模板即时生效（改设置无需重建模块）', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    final withSettings =
        DownloadFileLayout(storage: storage, settings: settings);
    expect(withSettings.baseNameFor(makeTrack()), '歌手 - 测试歌曲');

    await settings.setFilenameTemplate('{title} - {artist}');
    expect(withSettings.baseNameFor(makeTrack()), '测试歌曲 - 歌手');

    // 未知占位符原样保留（用户可能想要字面量 `{}` 文本）。
    await settings.setFilenameTemplate('{artist}/{unknown}');
    expect(withSettings.baseNameFor(makeTrack()), '歌手_{unknown}');
  });

  test('sanitize：非法字符替换、空白折叠、空名回退、按 rune 限长', () {
    expect(DownloadFileLayout.sanitizeFileName('///'), '___');
    expect(DownloadFileLayout.sanitizeFileName('   '), 'unknown');
    expect(
      DownloadFileLayout.sanitizeFileName('a' * 130),
      'a' * 120,
    );
    // 代理对不被截断成孤立半区（U+FFFD 替换字符不出现）。
    final emoji = DownloadFileLayout.sanitizeFileName('😀' * 130);
    expect(emoji.runes.length, 120);
    expect(emoji.contains('\uFFFD'), isFalse);
  });

  test('扩展名：直链后缀优先（oga 归一 ogg），否则按音质推断', () {
    expect(
      DownloadFileLayout.extensionFor(
        Uri.parse('https://x/a.flac?q=1'),
        '320k',
      ),
      'flac',
    );
    expect(
      DownloadFileLayout.extensionFor(Uri.parse('https://x/a'), 'flac'),
      'flac',
    );
    expect(
      DownloadFileLayout.extensionFor(Uri.parse('https://x/a.m3u8'), '128k'),
      'mp3',
    );
    expect(
      DownloadFileLayout.extensionFor(Uri.parse('https://x/a.oga'), '320k'),
      'ogg',
    );

    expect(DownloadFileLayout.extensionForQuality('flac24bit'), 'flac');
    expect(DownloadFileLayout.extensionForQuality('wav'), 'wav');
    expect(DownloadFileLayout.extensionForQuality('ape'), 'ape');
    expect(DownloadFileLayout.extensionForQuality('320k'), 'mp3');

    expect(DownloadFileLayout.coverExtension('https://x/c.jpeg'), 'jpg');
    expect(DownloadFileLayout.coverExtension('https://x/c.PNG'), 'png');
    expect(DownloadFileLayout.coverExtension('https://x/c'), 'jpg');
    expect(DownloadFileLayout.coverExtension('不是 URL'), 'jpg');
  });

  test('唯一基名：磁盘同名或记录占用时追加 (2)、(3)（大小写不敏感）', () async {
    Future<String> unique({
      Iterable<String?> reserved = const [],
      String desired = '歌手 - 测试歌曲',
    }) =>
        layout.uniqueBaseName(
          root: '/downloads',
          desiredBase: desired,
          extension: 'mp3',
          reservedPaths: reserved,
        );

    expect(await unique(), '歌手 - 测试歌曲');

    // 磁盘上已有同名文件：追加 (2)。
    storage.files['/downloads/歌手 - 测试歌曲.mp3'] = [1];
    expect(await unique(), '歌手 - 测试歌曲 (2)');
    storage.files['/downloads/歌手 - 测试歌曲 (2).mp3'] = [1];
    expect(await unique(), '歌手 - 测试歌曲 (3)');

    // 记录占用的基名（不含扩展名、大小写不敏感）同样跳过。
    storage.files.clear();
    expect(
      await unique(reserved: ['/downloads/歌手 - 测试歌曲.FLAC']),
      '歌手 - 测试歌曲 (2)',
    );
  });

  test('唯一基名：999 次递增后时间戳兜底', () async {
    final reserved = <String>[
      '/x/歌手 - 测试歌曲.mp3',
      for (var i = 2; i <= 999; i++) '/x/歌手 - 测试歌曲 ($i).mp3',
    ];
    final name = await layout.uniqueBaseName(
      root: '/downloads',
      desiredBase: '歌手 - 测试歌曲',
      extension: 'mp3',
      reservedPaths: reserved,
    );
    expect(name, matches(RegExp(r'^歌手 - 测试歌曲 \(\d+\)$')));
    expect(name, isNot('歌手 - 测试歌曲 (999)'));
  });

  test('分项基名：跟随音频 → 复用已有分项 → 目标子目录内查重', () async {
    Future<String> part({
      String? audioPath,
      String? existingPath,
      String subdir = downloadsLyricsDirName,
      String extension = 'lrc',
    }) =>
        layout.partBaseName(
          root: '/downloads',
          track: makeTrack(),
          audioPath: audioPath,
          existingPath: existingPath,
          subdir: subdir,
          extension: extension,
        );

    // 已有音频：sidecar 跟随音频基名（含查重后的 ` (2)` 后缀）。
    expect(await part(audioPath: '/downloads/歌手 - 测试歌曲 (2).mp3'),
        '歌手 - 测试歌曲 (2)');
    // 音频优先于已有分项路径。
    expect(
      await part(
        audioPath: '/downloads/跟随音频.mp3',
        existingPath: '/downloads/lyrics/旧分项.lrc',
      ),
      '跟随音频',
    );
    // 只有已有分项：复用它的基名（重复下载同一分项不产生 ` (2)` 副本）。
    expect(await part(existingPath: '/downloads/lyrics/已有歌词.lrc'), '已有歌词');
    // 都没有：按曲目名在子目录内查重。
    expect(await part(), '歌手 - 测试歌曲');
    storage.files['/downloads/lyrics/歌手 - 测试歌曲.lrc'] = [1];
    expect(await part(), '歌手 - 测试歌曲 (2)');
    // 查重只认目标子目录：covers 里的同名文件不影响歌词命名。
    expect(
      await part(subdir: downloadsCoversDirName, extension: 'jpg'),
      '歌手 - 测试歌曲',
    );
  });

  test('路径约定：音频 / 半成品 / 歌词 / 封面', () {
    expect(
      DownloadFileLayout.audioPath('/downloads', 'A', 'flac'),
      '/downloads/A.flac',
    );
    expect(
      DownloadFileLayout.partPath('/downloads/A.flac'),
      '/downloads/A.flac.part',
    );
    expect(
      DownloadFileLayout.lyricsPath('/downloads', 'A'),
      '/downloads/lyrics/A.lrc',
    );
    expect(
      DownloadFileLayout.coverPath('/downloads', 'A', 'https://x/c.jpeg'),
      '/downloads/covers/A.jpg',
    );
  });

  test('写歌词：主文件 + 翻译边车；空白翻译不写边车', () async {
    final path = await layout.writeLyrics(
      '/downloads',
      'A',
      lyric: '[00:01]原文',
      translation: '[00:01]译文',
    );
    expect(path, '/downloads/lyrics/A.lrc');
    expect(storage.files.containsKey('/downloads/lyrics/A.t.lrc'), isTrue);
    expect(await storage.readString('/downloads/lyrics/A.lrc'), '[00:01]原文');
    expect(await storage.readString('/downloads/lyrics/A.t.lrc'), '[00:01]译文');

    final noTranslation = await layout.writeLyrics(
      '/downloads',
      'B',
      lyric: '[00:01]词',
      translation: '   ',
    );
    expect(noTranslation, '/downloads/lyrics/B.lrc');
    expect(storage.files.containsKey('/downloads/lyrics/B.t.lrc'), isFalse);
  });

  test('写歌词失败：回滚主文件与翻译边车并返回 null（best-effort）', () async {
    // 主文件写入失败。
    final failing = _FailingWriteStorage(failSuffix: '.lrc');
    final failingLayout = DownloadFileLayout(storage: failing);
    final path = await failingLayout.writeLyrics(
      '/downloads',
      'A',
      lyric: '词',
      translation: '译',
    );
    expect(path, isNull);
    expect(failing.files, isEmpty);
    expect(failing.deleted, contains('/downloads/lyrics/A.lrc'));

    // 翻译边车写入失败：已写的主文件一起回滚。
    final half = _FailingWriteStorage(failSuffix: '.t.lrc');
    final halfLayout = DownloadFileLayout(storage: half);
    expect(
      await halfLayout.writeLyrics(
        '/downloads',
        'A',
        lyric: '词',
        translation: '译',
      ),
      isNull,
    );
    expect(half.files, isEmpty);
    expect(half.deleted, containsAll([
      '/downloads/lyrics/A.lrc',
      '/downloads/lyrics/A.t.lrc',
    ]));
  });

  test('写封面：covers 子目录；失败清理并返回 null', () async {
    final path = await layout.writeCover(
      root: '/downloads',
      base: 'A',
      coverUrl: 'https://x/c.png',
      bytes: Uint8List.fromList([9, 9]),
    );
    expect(path, '/downloads/covers/A.png');
    expect(storage.files[path], [9, 9]);

    final failing = _FailingWriteStorage(failSuffix: '.jpg');
    final failingLayout = DownloadFileLayout(storage: failing);
    expect(
      await failingLayout.writeCover(
        root: '/downloads',
        base: 'B',
        coverUrl: 'https://x/c.jpg',
        bytes: Uint8List.fromList([1]),
      ),
      isNull,
    );
    expect(failing.files, isEmpty);
    expect(failing.deleted, contains('/downloads/covers/B.jpg'));
  });

  test('记录引用文件集 / 失败清理文件集：与 sidecar 约定同源', () {
    const record = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: '1',
      title: 'A',
      filePath: '/downloads/A.mp3',
      lyricPath: '/downloads/lyrics/A.lrc',
      coverPath: '/downloads/covers/A.jpg',
      downloadedAt: 1,
    );
    expect(DownloadFileLayout.referencedFiles(record), [
      '/downloads/A.mp3',
      '/downloads/lyrics/A.lrc',
      '/downloads/lyrics/A.t.lrc',
      '/downloads/covers/A.jpg',
    ]);
    // 分项记录：只含歌词时没有音频 / 封面。
    const lyricOnly = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: '1',
      title: 'A',
      lyricPath: '/downloads/lyrics/A.lrc',
      downloadedAt: 1,
    );
    expect(DownloadFileLayout.referencedFiles(lyricOnly), [
      '/downloads/lyrics/A.lrc',
      '/downloads/lyrics/A.t.lrc',
    ]);

    expect(
      DownloadFileLayout.failedDownloadFiles(
        partPath: '/downloads/A.mp3.part',
        filePath: '/downloads/A.mp3',
        lyricPath: '/downloads/lyrics/A.lrc',
        coverPath: '/downloads/covers/A.jpg',
      ),
      [
        '/downloads/A.mp3.part',
        '/downloads/A.mp3',
        '/downloads/lyrics/A.lrc',
        '/downloads/lyrics/A.t.lrc',
        '/downloads/covers/A.jpg',
      ],
    );
    expect(
      DownloadFileLayout.failedDownloadFiles(partPath: '/downloads/A.mp3.part'),
      ['/downloads/A.mp3.part'],
    );
  });
}

/// 指定后缀写入失败（验证 sidecar 写失败的回滚路径）。
class _FailingWriteStorage extends FakeDownloadStorage {
  _FailingWriteStorage({required this.failSuffix});

  final String failSuffix;

  @override
  Future<void> writeString(String path, String content) async {
    if (path.endsWith(failSuffix)) throw Exception('写入失败: $path');
    return super.writeString(path, content);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (path.endsWith(failSuffix)) throw Exception('写入失败: $path');
    return super.writeBytes(path, bytes);
  }
}
