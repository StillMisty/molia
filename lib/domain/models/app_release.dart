/// 应用自更新的纯领域模型：发布清单、可下载产物与版本比较。
///
/// 只描述「有什么可更新、怎么挑产物」，不感知 HTTP（data 层）、安装策略
/// （services 层）与界面（providers/pages）；清单的 JSON 解析在
/// `lib/data/update/update_manifest_client.dart`，领域层保持纯 Dart。
library;

/// 发布渠道：稳定版 / 测试版（清单里的 `channel` 字段）。
enum UpdateChannel {
  stable('stable'),
  beta('beta');

  const UpdateChannel(this.wireName);

  /// 清单与偏好里持久化的字符串值。
  final String wireName;

  /// 解析渠道；未知值回退稳定版（坏配置不应把用户锁在测试渠道）。
  static UpdateChannel fromWire(String value) =>
      value == beta.wireName ? beta : stable;
}

/// 清单里的一个可下载产物。
class ReleaseAsset {
  const ReleaseAsset({
    required this.platform,
    required this.arch,
    required this.kind,
    required this.url,
    this.file,
    this.size,
    this.sha256,
  });

  /// android / windows / linux / ios / macos。
  final String platform;

  /// arm64 / armv7 / x86_64 / x64 / any。
  final String arch;

  /// apk / zip / tar.gz。
  final String kind;

  /// 资产下载地址（GitHub Release）。
  final Uri url;

  /// 文件名（仅作本地临时文件名，取 basename 使用）。
  final String? file;

  /// 字节数（清单可选字段）。
  final int? size;

  /// sha256（清单可选字段；有值时必须校验）。
  final String? sha256;

  bool get hasChecksum => sha256 != null && sha256!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ReleaseAsset &&
      other.platform == platform &&
      other.arch == arch &&
      other.kind == kind &&
      other.url == url &&
      other.file == file &&
      other.size == size &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(platform, arch, kind, url, file, size, sha256);

  @override
  String toString() => 'ReleaseAsset($platform/$arch/$kind, $url)';
}

/// 一次发布（latest.json 的领域视图）。
class AppRelease {
  const AppRelease({
    required this.channel,
    required this.version,
    required this.build,
    this.assets = const [],
    this.notes = '',
    this.notesUrl,
    this.releasedAt,
    this.schema = 1,
  });

  final int schema;
  final UpdateChannel channel;

  /// 语义化版本（不含 build 号），如 `1.2.3` / `1.2.3-beta.1`。
  final String version;

  /// 构建号：与 Android versionCode 同源，版本号相同时用来判定新旧。
  final int build;

  final List<ReleaseAsset> assets;

  /// 发布说明（markdown 原文，展示为纯文本）。
  final String notes;

  /// 发布页地址（打开下载页用）。
  final Uri? notesUrl;

  final DateTime? releasedAt;

  /// 是否比当前安装的版本更新（版本号优先，其次构建号）。
  bool isNewerThan({required String currentVersion, required int currentBuild}) {
    final byVersion = compareAppVersions(version, currentVersion);
    if (byVersion != 0) return byVersion > 0;
    return build > currentBuild;
  }

  /// 按平台与架构挑产物：精确匹配优先，其次该平台下任意架构。
  ReleaseAsset? assetFor({required String platform, required String arch}) {
    ReleaseAsset? fallback;
    for (final asset in assets) {
      if (asset.platform != platform) continue;
      if (asset.arch == arch) return asset;
      fallback ??= asset;
    }
    return fallback;
  }

  /// 按平台、架构与产物类别挑产物（同一平台可能有多种分发形态，如
  /// Windows 的安装器 `exe` 与便携 `zip`）。
  ReleaseAsset? assetOfKind({
    required String platform,
    required String arch,
    required String kind,
  }) {
    ReleaseAsset? fallback;
    for (final asset in assets) {
      if (asset.platform != platform || asset.kind != kind) continue;
      if (asset.arch == arch) return asset;
      fallback ??= asset;
    }
    return fallback;
  }

  @override
  String toString() =>
      'AppRelease(${channel.wireName}, $version+$build, ${assets.length} assets)';
}

/// 更新链路的失败类别：UI 映射为本机化文案，不展示原始异常（仓库约定）。
enum UpdateFailureKind {
  /// 取清单或下载时的网络失败。
  network,

  /// 清单格式非法 / 渠道不符。
  manifestInvalid,

  /// 当前平台没有适配产物（含 iOS 不支持应用内安装）。
  unsupported,

  /// 下载产物 sha256 校验失败（文件已删除）。
  checksumMismatch,

  /// 缺少安装权限（Android「安装未知应用」）。
  permission,

  /// 安装目录不可写（系统包管理器安装等）。
  notWritable,

  /// 安装 / 替换失败。
  installFailed,
}

/// 更新链路的领域异常：调用方按 [kind] 映射文案，[message] 只进日志。
class UpdateFailureException implements Exception {
  const UpdateFailureException(this.kind, this.message);

  final UpdateFailureKind kind;
  final String message;

  @override
  String toString() => 'UpdateFailureException($kind, $message)';
}

/// 比较两个语义化版本号（忽略 `v` 前缀与 `+build` 元数据）。
///
/// 规则与 semver 一致：数字段逐位比较；有预发布标识的版本小于同号正式版
/// （`1.0.0-beta.2 < 1.0.0`），预发布标识数字段按数值、字母段按字典序比较。
int compareAppVersions(String a, String b) {
  final pa = _ParsedVersion.parse(a);
  final pb = _ParsedVersion.parse(b);

  for (var i = 0; i < 3; i++) {
    final cmp = pa.core[i].compareTo(pb.core[i]);
    if (cmp != 0) return cmp;
  }

  if (pa.preRelease.isEmpty && pb.preRelease.isEmpty) return 0;
  if (pa.preRelease.isEmpty) return 1;
  if (pb.preRelease.isEmpty) return -1;

  final length = pa.preRelease.length < pb.preRelease.length
      ? pa.preRelease.length
      : pb.preRelease.length;
  for (var i = 0; i < length; i++) {
    final left = pa.preRelease[i];
    final right = pb.preRelease[i];
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      final cmp = leftNumber.compareTo(rightNumber);
      if (cmp != 0) return cmp;
      continue;
    }
    if (leftNumber != null) return -1; // 数字段小于字母段
    if (rightNumber != null) return 1;
    final cmp = left.compareTo(right);
    if (cmp != 0) return cmp;
  }
  return pa.preRelease.length.compareTo(pb.preRelease.length);
}

class _ParsedVersion {
  const _ParsedVersion(this.core, this.preRelease);

  final List<int> core;
  final List<String> preRelease;

  static _ParsedVersion parse(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    // 构建元数据（+xxx）不参与比较：构建号由 AppRelease.build 单独承载。
    final plus = value.indexOf('+');
    if (plus >= 0) value = value.substring(0, plus);
    final dash = value.indexOf('-');
    final coreText = dash >= 0 ? value.substring(0, dash) : value;
    final preText = dash >= 0 ? value.substring(dash + 1) : '';

    final core = List<int>.filled(3, 0);
    final segments = coreText.split('.');
    for (var i = 0; i < 3 && i < segments.length; i++) {
      core[i] = int.tryParse(segments[i]) ?? 0;
    }
    final preRelease = preText.isEmpty ? const <String>[] : preText.split('.');
    return _ParsedVersion(core, preRelease);
  }
}
