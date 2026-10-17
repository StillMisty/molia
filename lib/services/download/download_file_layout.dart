/// 下载文件命名 / 放置模块：文件名模板、清洗、去重命名与 sidecar 路径约定的
/// 唯一实现。
///
/// 为什么独立成模块：下载链路有六种生命周期（远程抓取 / 缓存拷贝 / 分项下载 /
/// 失败清理 / 删除 / 维护迁移）都要碰文件布局，散在 1561 行的服务里时同一约定
/// （`lyrics/` 下的 `.lrc` + `.t.lrc` 翻译边车、`covers/`、`.part` 半成品、
/// 磁盘与记录双重查重的 ` (2)` 递增）会各写一份；命名此前还有两份实现——
/// 下载真正走的模板版（`DownloadService._baseNameFor`）与只为测试存在的静态
/// 双胞胎（`DownloadService.baseNameFor`），测的不是生产路径。
///
/// 边界：只管「文件叫什么、放在哪、sidecar 怎么写」，不知道下载编排与网络；
/// 记录引用的文件集由 [referencedFiles] 从 `DownloadedTrack` 派生，让删除 /
/// 失败清理 / 孤儿判定复用同一份约定。
library;

import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/downloads/download_storage.dart';
import '../../domain/models/download.dart';
import '../../domain/models/track.dart';
import 'download_settings.dart';

/// 下载目录布局：模板 → 基名 → 去重 → 最终路径 / sidecar 路径。
///
/// [settings] 每次使用时即时读取（设置页改文件名模板后立即生效）；
/// [storage] 只用于「这个名字在磁盘上是否已存在」的存在性探测——与随后真正
/// 写文件的必须是同一个文件系统视图。
class DownloadFileLayout {
  DownloadFileLayout({
    required DownloadStorage storage,
    DownloadSettings? settings,
  })  : _storage = storage,
        _settings = settings;

  final DownloadStorage _storage;
  final DownloadSettings? _settings;
  final Logger _logger = Logger('molia.download_file_layout');

  // ── 命名 ────────────────────────────────────────────────

  /// 曲目文件名基名：按下载设置模板（默认 `{artist} - {title}`）生成并清洗。
  ///
  /// 未知占位符原样保留（用户可能想要字面量 `{}` 文本，见
  /// `DownloadSettings.applyTemplate`）；文件名完全由模板表达——默认模板在
  /// 无歌手时同样保留 `- ` 前缀，这是既有行为，不在这里另做「无歌手只用歌名」
  /// 的隐式兜底。
  String baseNameFor(Track track) {
    final template = _settings?.filenameTemplate ?? kDefaultFilenameTemplate;
    final raw = DownloadSettings.applyTemplate(template, {
      'artist': track.artistLabel,
      'title': track.title,
      'album': track.album ?? '',
    });
    return sanitizeFileName(raw);
  }

  /// 唯一音频基名：磁盘上已有同名音频（或 [reservedPaths] 已占用）时追加
  /// ` (2)`、` (3)`；递增超过 999 用时间戳兜底（几乎不可能出现）。
  ///
  /// [reservedPaths] 是下载记录里的音频路径：查重只看基名（不含扩展名、
  /// 大小写不敏感）——同名不同扩展名在部分平台会互相覆盖 / 混淆，记录占用的
  /// 名字也不能重新分配。
  Future<String> uniqueBaseName({
    required String root,
    required String desiredBase,
    required String extension,
    Iterable<String?> reservedPaths = const [],
  }) async {
    final used = <String>{
      for (final path in reservedPaths)
        if (path != null) p.basenameWithoutExtension(path).toLowerCase(),
    };
    var candidate = desiredBase;
    var index = 2;
    while (true) {
      if (!used.contains(candidate.toLowerCase()) &&
          !await _storage.fileExists(
            p.join(root, '$candidate.$extension'),
          )) {
        return candidate;
      }
      if (index > 999) {
        return '$desiredBase (${DateTime.now().millisecondsSinceEpoch})';
      }
      candidate = '$desiredBase ($index)';
      index++;
    }
  }

  /// 分项文件基名：已有音频 → 跟随音频基名（sidecar 同目录同基名约定）；
  /// 已有同分项文件 → 复用（重复下载同一分项不产生 ` (2)` 副本）；否则按曲目
  /// 名在 [subdir] 内查重。
  Future<String> partBaseName({
    required String root,
    required Track track,
    required String subdir,
    required String extension,
    String? audioPath,
    String? existingPath,
  }) async {
    if (audioPath != null && audioPath.isNotEmpty) {
      return p.basenameWithoutExtension(audioPath);
    }
    if (existingPath != null && existingPath.isNotEmpty) {
      return p.basenameWithoutExtension(existingPath);
    }
    final desired = baseNameFor(track);
    var candidate = desired;
    var index = 2;
    while (await _storage.fileExists(
      p.join(root, subdir, '$candidate.$extension'),
    )) {
      if (index > 999) {
        return '$desired (${DateTime.now().millisecondsSinceEpoch})';
      }
      candidate = '$desired ($index)';
      index++;
    }
    return candidate;
  }

  // ── 放置（路径约定）──────────────────────────────────────

  /// 音频最终路径（下载根目录下）。
  static String audioPath(String root, String base, String extension) =>
      p.join(root, '$base.$extension');

  /// 半成品路径（`.part` 后缀；完成后原子改名成 [audioPath]）。
  static String partPath(String audioPath) => '$audioPath$downloadPartSuffix';

  /// 歌词路径（`lyrics/` 子目录，长期存储）；翻译边车由
  /// `translationLyricPathOf` 从本路径派生。
  static String lyricsPath(String root, String base) =>
      p.join(root, downloadsLyricsDirName, '$base.lrc');

  /// 封面路径（`covers/` 子目录；扩展名从封面 URL 推断）。
  static String coverPath(String root, String base, String coverUrl) =>
      p.join(root, downloadsCoversDirName, '$base.${coverExtension(coverUrl)}');

  /// 写入歌词主文件 + 翻译边车；失败回滚已写文件并返回 null（best-effort：
  /// 歌词缺失不阻断音频下载，对应路径记为 null）。
  Future<String?> writeLyrics(
    String root,
    String base, {
    required String lyric,
    String? translation,
  }) async {
    String? path;
    try {
      path = lyricsPath(root, base);
      await _storage.writeString(path, lyric);
      if (translation != null && translation.trim().isNotEmpty) {
        final translationPath = translationLyricPathOf(path);
        if (translationPath != null) {
          await _storage.writeString(translationPath, translation);
        }
      }
      return path;
    } catch (e) {
      _logger.warning('下载歌词失败: $e');
      if (path != null) {
        await _storage.deleteQuietly(path);
        final translationPath = translationLyricPathOf(path);
        if (translationPath != null) {
          await _storage.deleteQuietly(translationPath);
        }
      }
      return null;
    }
  }

  /// 写入封面文件；失败清理并返回 null（best-effort）。
  Future<String?> writeCover({
    required String root,
    required String base,
    required String coverUrl,
    required Uint8List bytes,
  }) async {
    String? path;
    try {
      path = coverPath(root, base, coverUrl);
      await _storage.writeBytes(path, bytes);
      return path;
    } catch (e) {
      _logger.warning('下载封面失败: $e');
      if (path != null) await _storage.deleteQuietly(path);
      return null;
    }
  }

  // ── 记录引用的文件集（删除 / 清理 / 孤儿判定共用）─────────

  /// [record] 引用的本地文件：音频 / 歌词 / 翻译边车 / 封面（按序、跳过空值）。
  static List<String> referencedFiles(DownloadedTrack record) => [
        if (record.filePath != null) record.filePath!,
        if (record.lyricPath != null) record.lyricPath!,
        if (record.translationLyricPath != null) record.translationLyricPath!,
        if (record.coverPath != null) record.coverPath!,
      ];

  /// 失败下载的残留文件集：半成品 / 最终音频 / 歌词 + 翻译边车 / 封面。
  static List<String> failedDownloadFiles({
    String? partPath,
    String? filePath,
    String? lyricPath,
    String? coverPath,
  }) {
    final translation = translationLyricPathOf(lyricPath);
    return [
      if (partPath != null) partPath,
      if (filePath != null) filePath,
      if (lyricPath != null) lyricPath,
      if (translation != null) translation,
      if (coverPath != null) coverPath,
    ];
  }

  // ── 扩展名与清洗 ─────────────────────────────────────────

  /// 可下载 / 可导入的音频后缀（小写、不含点）。
  ///
  /// 唯一来源：直链扩展名推断（[extensionFor]）与本地导入校验共用。
  static const Set<String> audioExtensions = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'oga',
    'opus',
    'wav',
    'ape',
    'wma',
    'mka',
    'mp4',
  };

  /// 扩展名：URL 路径里的音频后缀优先，否则按音质推断（默认 mp3）。
  static String extensionFor(Uri url, String quality) {
    final ext = p.extension(url.path).toLowerCase().replaceFirst('.', '');
    if (audioExtensions.contains(ext)) return ext == 'oga' ? 'ogg' : ext;
    return extensionForQuality(quality);
  }

  /// 音频扩展名：缓存命中无法从 URL 推断时按音质映射
  /// （flac/wav/ape/其余 mp3）。
  static String extensionForQuality(String quality) {
    switch (quality) {
      case 'flac24bit':
      case 'flac':
        return 'flac';
      case 'wav':
        return 'wav';
      case 'ape':
        return 'ape';
      default:
        return 'mp3';
    }
  }

  /// 封面扩展名：URL 里的图片后缀优先（`jpeg` 归一为 `jpg`），否则 `jpg`。
  static String coverExtension(String url) {
    const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
    final ext = p
        .extension(Uri.tryParse(url)?.path ?? '')
        .toLowerCase()
        .replaceFirst('.', '');
    if (imageExtensions.contains(ext)) return ext == 'jpeg' ? 'jpg' : ext;
    return 'jpg';
  }

  static final RegExp _illegalFileNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
  static final RegExp _whitespaceRun = RegExp(r'\s+');

  /// 文件系统非法字符替换为 `_`，空白折叠，空名回退 `unknown`，限长 120。
  static String sanitizeFileName(String name) {
    final replaced = name.replaceAll(_illegalFileNameChars, '_');
    final collapsed = replaced.replaceAll(_whitespaceRun, ' ').trim();
    if (collapsed.isEmpty) return 'unknown';
    const maxLength = 120;
    if (collapsed.length <= maxLength) return collapsed;
    // 按 rune 截断，避免切断代理对。
    return String.fromCharCodes(collapsed.runes.take(maxLength)).trim();
  }
}
