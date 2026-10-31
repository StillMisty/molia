import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';

/// 音源音质的本地化显示名（设置 / 音源 / 省流页共用）。
///
/// 值域是 LX 音质标识（见 `kLxQualityOrder`）；未知值沿用值本身，
/// 保证新增音质标签也能显示。
String sourceQualityLabel(AppLocalizations l10n, String quality) {
  return switch (quality) {
    'flac24bit' => l10n.sourcesQualityHiRes,
    'flac' => l10n.sourcesQualityLossless,
    'wav' => l10n.sourcesQualityWav,
    'ape' => l10n.sourcesQualityApe,
    '320k' => l10n.sourcesQuality320k,
    '192k' => l10n.sourcesQuality192k,
    '128k' => l10n.sourcesQuality128k,
    '64k' => l10n.sourcesQuality64k,
    _ => quality,
  };
}

/// 曲目可用音质按「高 → 低」排序并去重（未知档位保持原顺序排在末尾）。
///
/// 各平台返回顺序并不一致（酷我低→高、B 站高→低、脚本自定义），展示面
/// 统一走这里，避免同一个弹层在不同平台看起来档位顺序相反。
List<AudioQuality> sortedQualityOptions(Iterable<AudioQuality> qualities) {
  final known = <AudioQuality>[];
  final unknown = <AudioQuality>[];
  final seen = <String>{};
  for (final quality in qualities) {
    if (quality.type.isEmpty || !seen.add(quality.type)) continue;
    if (kLxQualityOrder.contains(quality.type)) {
      known.add(quality);
    } else {
      unknown.add(quality);
    }
  }
  known.sort(
    (a, b) => kLxQualityOrder
        .indexOf(a.type)
        .compareTo(kLxQualityOrder.indexOf(b.type)),
  );
  return [...known, ...unknown];
}

const Map<String, String> _sizeUnits = {
  'B': 'B',
  'K': 'KB',
  'KB': 'KB',
  'KIB': 'KB',
  'M': 'MB',
  'MB': 'MB',
  'MIB': 'MB',
  'G': 'GB',
  'GB': 'GB',
  'GIB': 'GB',
  'T': 'TB',
  'TB': 'TB',
  'TIB': 'TB',
};

final RegExp _sizePattern = RegExp(
  r'^([0-9]+(?:\.[0-9]+)?)\s*([KMG]i?B|[KMG]|B)$',
  caseSensitive: false,
);

/// 统一音质体积写法：`9.80 MiB` / `9.17Mb` / `9.8MB` → `9.8 MB`。
///
/// 只统一单位写法与尾零，不做二进制 / 十进制换算（源数据本身是估算值，
/// 换数会让同一档位在不同平台看起来跳变）。无法识别（如酷我 `zpMb`）
/// 返回 null，由调用方隐藏体积而不是展示脏数据。
String? formatQualitySize(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  final match = _sizePattern.firstMatch(text);
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!);
  if (value == null || value <= 0) return null;
  final unit = _sizeUnits[match.group(2)!.toUpperCase()];
  if (unit == null) return null;
  return '${_trimTrailingZeros(match.group(1)!)} $unit';
}

String _trimTrailingZeros(String number) {
  if (!number.contains('.')) return number;
  return number
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
