/// 封面解析：全 App「这一首用哪张封面」的唯一实现。
///
/// 来源优先级固定为 **自定义封面 > 曲目原始封面 > 全局默认封面**，并且把
/// 「真实封面」与「展示封面」做成两个类型，而不是一个 bool：
///
/// - [RealCover]：取色 / 下载 / 标签 / 系统媒体补图等真实封面消费方只接受
///   这个类型。它的构造器禁止 `defaultCover` 来源——默认封面是占位，不能
///   被误用来取色、下载或写进标签；
/// - [DisplayCover]：展示面（列表 / 顶栏 / 播放页 / 海报 / 小组件）使用，
///   内部持有 [RealCover]，默认封面只作为「没有真实封面」时的兜底。
///
/// 这样「默认封面不参与取色 / 下载 / 标签」不再靠调用方自觉遵守，而是由
/// 类型与解析顺序保证。封面键规范化（`local:` 下载副本剥一层、本地导入
/// 保留 `local:<path>` 记录键）也只在这里实现；[CoverIndex] 的实现
/// （`CustomCoverStore`）只管写入、持久化与同步落地，不再决定展示优先级。
///
/// 本文件保持纯 Dart（只依赖领域模型与 `dart:typed_data`），变更信号用
/// 回调而不是 Flutter 的 `Listenable`，方便数据层与 widget 层共用。
library;

import 'dart:typed_data';

import '../../domain/models/download.dart' show kLocalSourceKey;
import '../../domain/models/track.dart';

/// 封面来源（优先级从高到低）。
enum CoverOrigin {
  /// 用户为这一首设置的自定义封面。
  custom,

  /// 曲目自带的原始封面（网络 / data URL 等）。
  original,

  /// 设置里的全局默认封面；只允许出现在 [DisplayCover]。
  defaultCover,

  /// 没有任何封面。
  none,
}

/// 一次封面解析的结果。
///
/// 具体只有 [RealCover] / [DisplayCover] 两个子类：真实与展示是类型差异，
/// 不是运行期布尔标记。
sealed class CoverResolution {
  const CoverResolution();

  /// 最终地址；[DisplayCover] 在没有真实封面时返回默认封面。
  String? get url;

  CoverOrigin get origin;

  bool get hasCover => url != null;
}

/// 真实封面：自定义或原始，**永远不会**是全局默认封面。
final class RealCover extends CoverResolution {
  const RealCover({required this.url, required this.origin})
      : assert(
          (url == null) == (origin == CoverOrigin.none),
          'RealCover 的 url 与 origin 必须同时为空 / 非空',
        ),
        assert(
          origin != CoverOrigin.defaultCover,
          '默认封面只属于展示面，不能作为真实封面',
        );

  /// 无真实封面。
  const RealCover.none()
      : url = null,
        origin = CoverOrigin.none;

  @override
  final String? url;

  @override
  final CoverOrigin origin;

  bool get isCustom => origin == CoverOrigin.custom;
  bool get isOriginal => origin == CoverOrigin.original;

  @override
  bool operator ==(Object other) =>
      other is RealCover && other.url == url && other.origin == origin;

  @override
  int get hashCode => Object.hash(url, origin);

  @override
  String toString() => 'RealCover($origin, $url)';
}

/// 展示封面：真实封面 + 仅展示面允许的默认封面兜底。
final class DisplayCover extends CoverResolution {
  const DisplayCover({required this.real, this.defaultUrl});

  /// 真实封面（取色 / 下载 / 标签只认它）。
  final RealCover real;

  /// 真实封面缺失 / 加载失败时的占位；不参与取色、下载与标签。
  final String? defaultUrl;

  /// 主图必须用 [real] 的地址，默认封面只作为失败回退：直接把
  /// [url] 当主图会让远端封面加载失败时看不出「这首其实有封面」。
  String? get primaryUrl => real.url;

  bool get usesDefaultCover => real.url == null && defaultUrl != null;

  @override
  String? get url => real.url ?? defaultUrl;

  @override
  CoverOrigin get origin => real.url != null
      ? real.origin
      : (defaultUrl != null ? CoverOrigin.defaultCover : CoverOrigin.none);

  @override
  bool operator ==(Object other) =>
      other is DisplayCover &&
      other.real == real &&
      other.defaultUrl == defaultUrl;

  @override
  int get hashCode => Object.hash(real, defaultUrl);

  @override
  String toString() => 'DisplayCover($origin, $url, real: $real)';
}

/// 封面索引的只读端口（生产实现：`CustomCoverStore`）。
///
/// [customCoverUrlForKey] 的 key 必须是**已规范化**的封面键；规范化由
/// [CoverResolver] 负责，存储不重复判断 `local:` 规则。
abstract interface class CoverIndex {
  /// 全局默认封面 `file://` 地址；null = 没有设置。
  String? get defaultCoverUrl;

  /// 规范化封面键 → 自定义封面 `file://` 地址。
  String? customCoverUrlForKey(String key);

  /// 读取自定义封面原始字节（同步 / 备份使用同一索引）。
  Future<Uint8List?> readTrackCoverByKey(String key);

  /// 订阅索引变化；返回取消订阅函数。
  void Function() addRevisionListener(void Function() listener);
}

/// 曲目键 → 规范封面键。
///
/// `TrackId(local, 'wy:123')` 是下载副本：剥掉一层 `local:` 后沿用下载前
/// 设置的封面；本地导入 `TrackId(local, 'local:/path')` 记录键本身就是
/// `local:/path`，不能再剥第二次。
String coverKeyOf(TrackId id) =>
    id.sourceKey == kLocalSourceKey ? id.id : id.uri;

/// 字符串形态的规范封面键（只认 `TrackId.uri` 形状，剥一层 `local:`）。
String normalizeCoverKey(String key) => key.startsWith('$kLocalSourceKey:')
    ? key.substring(kLocalSourceKey.length + 1)
    : key;

/// 封面解析器（无状态；每次查询都读当前索引，替换封面立即生效）。
class CoverResolver {
  const CoverResolver(this._index);

  final CoverIndex _index;

  /// 全局默认封面地址（展示面兜底；真实封面消费方不应直接使用）。
  String? get defaultCoverUrl => _nonEmpty(_index.defaultCoverUrl);

  /// 索引变化信号（自定义 / 默认封面替换、恢复、远端同步落地都会触发）。
  void Function() addChangeListener(void Function() listener) =>
      _index.addRevisionListener(listener);

  /// 真实封面（不包含默认封面）。
  RealCover realOf(Track? track) => realForId(
        track?.id,
        originalUrl: track?.artwork?.uri.toString(),
      );

  /// 展示封面（真实封面缺失时附加默认封面兜底）。
  DisplayCover displayOf(Track? track) => displayForId(
        track?.id,
        originalUrl: track?.artwork?.uri.toString(),
      );

  /// 按 [TrackId] 解析真实封面。
  RealCover realForId(TrackId? id, {String? originalUrl}) => _real(
        _customUrlOfId(id),
        originalUrl,
      );

  /// 按 [TrackId] 解析展示封面。
  DisplayCover displayForId(TrackId? id, {String? originalUrl}) =>
      _display(realForId(id, originalUrl: originalUrl));

  /// 按字符串封面键解析真实封面（列表行 / 换源候选只有键的场景）。
  RealCover realForKey(String? coverKey, {String? originalUrl}) => _real(
        _customUrlOfKey(coverKey),
        originalUrl,
      );

  /// 按字符串封面键解析展示封面。
  DisplayCover displayForKey(String? coverKey, {String? originalUrl}) =>
      _display(realForKey(coverKey, originalUrl: originalUrl));

  /// 读取当前曲目的自定义封面字节（下载 / 标签使用；没有时返回 null）。
  ///
  /// 只返回自定义封面：原始封面由下载链路按 `ArtworkCache` / 取图端口
  /// 处理，默认封面永远不在这里出现。
  Future<Uint8List?> readCustomCoverBytes(Track? track) {
    final id = track?.id;
    if (id == null) return Future<Uint8List?>.value(null);
    return _index.readTrackCoverByKey(coverKeyOf(id));
  }

  /// 按字符串封面键读取自定义封面字节（键可以带 `local:` 前缀）。
  Future<Uint8List?> readCustomCoverBytesForKey(String? coverKey) {
    final normalized = _normalizeKey(coverKey);
    if (normalized == null) return Future<Uint8List?>.value(null);
    return _index.readTrackCoverByKey(normalized);
  }

  DisplayCover _display(RealCover real) => DisplayCover(
        real: real,
        defaultUrl: defaultCoverUrl,
      );

  RealCover _real(String? customUrl, String? originalUrl) {
    if (customUrl != null) {
      return RealCover(url: customUrl, origin: CoverOrigin.custom);
    }
    final original = _nonEmpty(originalUrl);
    if (original == null) return const RealCover.none();
    return RealCover(url: original, origin: CoverOrigin.original);
  }

  String? _customUrlOfId(TrackId? id) {
    if (id == null) return null;
    return _nonEmpty(_index.customCoverUrlForKey(coverKeyOf(id)));
  }

  String? _customUrlOfKey(String? coverKey) {
    final normalized = _normalizeKey(coverKey);
    if (normalized == null) return null;
    return _nonEmpty(_index.customCoverUrlForKey(normalized));
  }

  static String? _normalizeKey(String? key) {
    if (key == null || key.isEmpty) return null;
    return normalizeCoverKey(key);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
