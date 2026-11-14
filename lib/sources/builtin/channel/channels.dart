/// 内置歌曲渠道注册表：渠道声明的唯一聚合点。
///
/// 渠道身份 / 能力实现只在自己的 `{key}_channel.dart` 里声明；本文件只按
/// 展示顺序聚合，并派生各 facade 需要的查表视图。新增渠道只改两处：
/// 新增声明文件 + 往 [all] 里加一行。
///
/// 平台顺序就是音源页渠道、搜索渠道候选与发现页的默认顺序；用户可在音源页
/// 自定义排序，重置后回到这里。
library;

import 'bili_channel.dart';
import 'kg_channel.dart';
import 'kw_channel.dart';
import 'mg_channel.dart';
import 'qs_channel.dart';
import 'song_channel.dart';
import 'tx_channel.dart';
import 'wy_channel.dart';

export 'song_channel.dart';

class SongChannels {
  SongChannels._();

  /// 规范渠道顺序：QQ → 网易 → 酷狗 → 酷我 → 咪咕 → 汽水 → 哔哩哔哩。
  static const List<SongChannel> all = [
    txChannel,
    wyChannel,
    kgChannel,
    kwChannel,
    mgChannel,
    qsChannel,
    biliChannel,
  ];

  static final Map<String, SongChannel> byKey = Map.unmodifiable({
    for (final channel in all) channel.key: channel,
  });

  /// 规范键顺序（发现页 / 默认渠道顺序）。
  static final List<String> keys = List.unmodifiable(byKey.keys);

  /// 规范键集合（只读；不要另行声明渠道矩阵）。
  static final Set<String> keySet = Set.unmodifiable(byKey.keys);

  /// 渠道展示名（键顺序同 [keys]）。
  static final Map<String, String> displayNames = Map.unmodifiable({
    for (final channel in all) channel.key: channel.displayName,
  });

  /// 音乐平台 key（不含视频站 B 站），按规范顺序。
  ///
  /// 跨渠道补封面等「按名字找歌」的场景使用：这些渠道的搜索不依赖 LX 脚本
  /// 取链，可直接搜到带封面的曲目。B 站搜索结果是视频，不参与自动找歌匹配。
  static final List<String> musicKeys = List.unmodifiable([
    for (final channel in all)
      if (channel.key != 'bili') channel.key,
  ]);

  static bool isSupported(String key) => byKey.containsKey(key);

  static SongChannel? forKey(String key) => byKey[key];

  static String displayName(String key) => byKey[key]?.displayName ?? key;
}
