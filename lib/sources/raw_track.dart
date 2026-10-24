/// 平台 raw 对象的统一约定（唯一入口）。
///
/// `SourceTrack.raw`、持久化历史 / 我的列表、`.lxmc` 导入与发现曲目都携带
/// 平台原始对象（LX `musicInfo` 约定），本模块集中它们共用的规则：
///
/// - **id**：[rawIdOf] 是 `SourceTrack.id`、`TrackId`、收藏/列表 `songId`、
///   发现曲目 `songId` 共用的取键优先级；[platformRawIdOf] 是 `.lxmc`
///   导出场景的平台优先顺序；
/// - **规范字段**：[withCanonicalId] 补齐脚本取链读取的字段
///   （wy/tx/kw → songmid、kg → hash、mg → copyrightId），只增不删；
/// - **音质**：[qualitiesFromRaw] 解析 `qualitys/_qualitys`（LX）与
///   `_types`（内置平台）映射。
library;

/// LX 平台搜索返回的音质信息。
class SourceQuality {
  final String type; // 128k / 320k / flac / flac24bit ...
  final String? size;
  final String? hash; // kg 等平台不同音质对应不同 hash

  const SourceQuality({required this.type, this.size, this.hash});

  Map<String, dynamic> toJson() => {'type': type, 'size': size, 'hash': hash};

  factory SourceQuality.fromJson(Map<String, dynamic> json) => SourceQuality(
        type: json['type'] as String? ?? '',
        size: json['size'] as String?,
        hash: json['hash'] as String?,
      );
}

/// 通用取键优先级（`SourceTrack.id` / `TrackId` / 发现曲目共用，不含兜底）。
///
/// `bvid` 在最前：B 站同一视频同时带 bvid / aid，取链与页面地址都以 bvid
/// 为准；其余平台没有该字段，顺序对它们无影响。
const List<String> _rawIdFields = [
  'bvid',
  'aid',
  'songmid',
  'hash',
  'songId',
  'id',
  'mid',
];

/// 从 raw 取平台 id：按 [_rawIdFields] 取第一个非空值；找不到返回 `''`。
String rawIdOf(Map<String, dynamic> raw) {
  for (final field in _rawIdFields) {
    final value = raw[field];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 各平台脚本取链的规范 id 字段（内置搜索 / LX 脚本 `musicInfo` 约定）。
const Map<String, String> _canonicalIdFields = {
  'wy': 'songmid',
  'tx': 'songmid',
  'kg': 'hash',
  'kw': 'songmid',
  'mg': 'copyrightId',
};

/// `.lxmc` 导出 / 持久化 raw 的平台优先取键顺序（比通用优先级更贴近导出）。
const Map<String, List<String>> _platformIdFields = {
  'wy': ['songId', 'id', 'songmid'],
  'tx': ['songmid', 'songId', 'strMediaMid', 'id', 'mid'],
  'kg': ['hash', 'songmid', 'id'],
  'kw': ['songmid', 'musicId', 'id'],
  'mg': ['copyrightId', 'songId', 'songmid', 'id'],
  // B 站取链优先 bvid；收藏夹条目没有 bvid 时用 aid（导入时已归一为 aid）。
  'bili': ['bvid', 'aid', 'id'],
};

/// 未登记平台的取键顺序（`.lxmc` 导入共用此顺序）。
const List<String> _defaultPlatformIdFields = [
  'songId',
  'songmid',
  'hash',
  'musicId',
  'copyrightId',
  'mid',
  'id',
];

/// 平台优先的 id（`.lxmc` 导出等场景）；找不到返回 `''`。
String platformRawIdOf(String sourceKey, Map<String, dynamic> raw) {
  for (final field
      in _platformIdFields[sourceKey] ?? _defaultPlatformIdFields) {
    final value = raw[field];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 规范字段的别名顺序（songmid 优先；沿用 `.lxmc` 导入的取键口径）。
const List<String> _aliasIdFields = [
  'songmid',
  'hash',
  'songId',
  'musicId',
  'copyrightId',
  'mid',
  'id',
];

/// 补齐平台规范 id 字段（**只增不删**）：缺少 `_canonicalIdFields[sourceKey]`
/// 时用别名顺序取到的 id 填充；已有值或无法识别时返回原引用。
Map<String, dynamic> withCanonicalId({
  required String sourceKey,
  required Map<String, dynamic> raw,
}) {
  final field = _canonicalIdFields[sourceKey];
  if (field == null) return raw;
  final existing = raw[field];
  if (existing != null && existing.toString().trim().isNotEmpty) return raw;
  var id = '';
  for (final alias in _aliasIdFields) {
    final value = raw[alias];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) {
      id = text;
      break;
    }
  }
  if (id.isEmpty) return raw;
  return {...raw, field: id};
}

/// 项目内部歌手引用字段（与 `_types` / `_interval` 同约定：内置平台解析时
/// 增补、LX 约定的 [raw] 字段只增不删；取链脚本不读取该字段）。
///
/// 值形如 `[{'name': '周杰伦', 'id': '336'}]`：名字与 `singer` 串同序，
/// `id` 为平台内歌手 id（脚本源 / 平台未提供时缺省）。
const String kRawArtistsField = '_artists';

/// 音源曲目内的歌手引用（名字 + 平台内 id）。
class SourceArtistRef {
  final String name;

  /// 平台内歌手 id；平台未提供时为 null（脚本源 / 部分入口）。
  final String? id;

  const SourceArtistRef({required this.name, this.id});

  Map<String, dynamic> toJson() => {
        'name': name,
        if (id != null && id!.isNotEmpty) 'id': id,
      };

  factory SourceArtistRef.fromJson(Map<dynamic, dynamic> json) =>
      SourceArtistRef(
        name: json['name']?.toString() ?? '',
        id: json['id']?.toString(),
      );

  @override
  bool operator ==(Object other) =>
      other is SourceArtistRef && other.name == name && other.id == id;

  @override
  int get hashCode => Object.hash(name, id);

  @override
  String toString() => id == null ? name : '$name($id)';
}

/// 从 raw 还原歌手引用（[kRawArtistsField]）。
///
/// 缺省 / 结构不符返回空列表：调用方回退 `SourceTrack.artist` 整串
/// （脚本扩展源的搜索返回没有结构化歌手字段）。
List<SourceArtistRef> artistsFromRaw(Map<String, dynamic> raw) {
  final list = raw[kRawArtistsField];
  if (list is! List) return const [];
  final artists = <SourceArtistRef>[];
  for (final item in list) {
    if (item is! Map) continue;
    final ref = SourceArtistRef.fromJson(item);
    if (ref.name.isEmpty) continue;
    artists.add(ref);
  }
  return artists;
}

/// 从 raw 还原音质列表（`qualitys` 数组 + `_qualitys` 映射，映射带 hash；
/// 内置平台源的 `_types` 映射同样兼容）。按 type 去重保序，首次出现优先。
List<SourceQuality> qualitiesFromRaw(Map<String, dynamic> raw) {
  final result = <SourceQuality>[];
  final seen = <String>{};

  void add(String type, Object? size, Object? hash) {
    if (type.isEmpty || !seen.add(type)) return;
    result.add(SourceQuality(
      type: type,
      size: size?.toString(),
      hash: hash?.toString(),
    ));
  }

  final list = raw['qualitys'];
  if (list is List) {
    for (final item in list) {
      if (item is Map) add(item['type']?.toString() ?? '', item['size'], null);
    }
  }
  for (final key in const ['_qualitys', '_types']) {
    final map = raw[key];
    if (map is Map) {
      map.forEach((type, value) {
        final info = value is Map ? value : const {};
        add(type.toString(), info['size'], info['hash']);
      });
    }
  }
  return result;
}
