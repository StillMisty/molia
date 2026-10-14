/// 歌词来源展示名：兼容两套 provider 标识。
///
/// - 原生取词 / 内置平台：曲目音源 key（`wy`/`tx`/`kg`/`kw`/`mg`）；
/// - 跨平台名字搜索回退与手动选择：provider 名
///   （`netease`/`qq`/`kugou`/`kuwo`/`migu`/`lrclib`）；
/// - 本地下载曲目：`local`；
/// - LX 脚本 / any-listen：脚本 key，经渠道列表查显示名，查不到回退 key。
library;

import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';

String lyricsProviderLabel(
  AppLocalizations l10n,
  Iterable<SourceEntry> channels,
  String providerKey,
) {
  final known = switch (providerKey) {
    'netease' || 'wy' => l10n.providerNetease,
    'qq' || 'tx' => l10n.providerQQMusic,
    'kugou' || 'kg' => l10n.providerKugou,
    'kuwo' || 'kw' => l10n.providerKuwo,
    'migu' || 'mg' => l10n.providerMigu,
    'lrclib' => l10n.providerLRCLIB,
    'local' => l10n.downloadSourceLocal,
    _ => null,
  };
  if (known != null) return known;
  if (providerKey.isEmpty) return providerKey;
  for (final entry in channels) {
    if (entry.key == providerKey) return entry.name;
  }
  return providerKey;
}
