/// LX 音源脚本管理的纯领域模型。
///
/// 音源管理页与 `SourcesProvider` 只依赖这里的纯数据视图，不感知
/// `lib/sources/**` 的引擎/仓库实现（分层 R5）。脚本原文（script）刻意
/// 不进入领域模型：UI 展示与操作都不需要它。
library;

import 'source.dart' show SourceKind;

/// 脚本声明的一个音乐源（`inited` 事件 name/actions/qualitys 的纯数据视图）。
class SourceScriptDecl {
  /// kw / kg / tx / wy / mg / local / 自定义 key。
  final String key;
  final String name;

  /// musicUrl / lyric / pic / search / musicSearch ...
  final List<String> actions;
  final List<String> qualitys;

  const SourceScriptDecl({
    required this.key,
    required this.name,
    required this.actions,
    required this.qualitys,
  });

  bool supports(String action) => actions.contains(action);

  bool get canSearch => supports('search') || supports('musicSearch');

  bool get canResolveUrl => supports('musicUrl');

  bool get canFetchLyric => supports('lyric');

  bool get canFetchPic => supports('pic');
}

/// 一个已导入音源脚本的纯数据视图（不含脚本原文）。
class SourceScriptInfo {
  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;
  final int importedAt;

  /// 脚本声明的更新地址（`@updateUrl` 或运行时 `updateAlert` 上报），
  /// 为空表示该脚本未提供在线更新能力。
  final String? updateUrl;

  /// 脚本初始化后声明的源（`inited` 事件之后才有值）。
  final Map<String, SourceScriptDecl> sources;

  const SourceScriptInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.author,
    required this.homepage,
    required this.importedAt,
    this.updateUrl,
    this.sources = const {},
  });

  bool get hasUpdateUrl => updateUrl?.isNotEmpty ?? false;
}

/// 在线更新检查的领域化结果（不含下载到的脚本原文，原文由 provider 内部保留）。
class SourceUpdateCheck {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;

  const SourceUpdateCheck({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
  });
}

/// 运行期 `updateAlert` 的纯数据视图。
class SourceUpdateAlert {
  final String log;
  final String? updateUrl;

  const SourceUpdateAlert({required this.log, this.updateUrl});
}

/// 排序 / 展示用的音源条目（内置平台 / 脚本源 / any-listen）。
class SourceEntry {
  final String key;
  final String name;
  final SourceKind kind;
  final bool canSearch;

  /// 是否具备内置「发现」能力（热榜 / 歌单 / 热搜：wy/tx/kg/kw/mg）。
  final bool discoverable;

  /// 是否启用（停用后不出现在资料页渠道选择与搜索结果中）。
  final bool enabled;

  const SourceEntry({
    required this.key,
    required this.name,
    required this.kind,
    required this.canSearch,
    this.discoverable = false,
    this.enabled = true,
  });
}

/// 音质选项：值 + 通用显示名（本地化文案由 UI 层按 value 覆盖）。
class SourceQualityOption {
  final String value;
  final String displayName;

  const SourceQualityOption({required this.value, required this.displayName});
}

/// 音源操作失败的可读异常：sources 层异常在 provider 边界归一化为它，
/// UI 只 catch 这个类型（`htmlPage` 用于「更新地址指向网页」的本地化提示）。
class SourceScriptException implements Exception {
  final String message;

  /// 更新地址返回的是网页而非脚本（页面据此展示「手动导入」提示）。
  final bool htmlPage;

  const SourceScriptException(this.message, {this.htmlPage = false});

  @override
  String toString() => message;
}

/// 音质通用显示名（覆盖原 `kxQualityDisplayName` 的音质文案与未知回退）。
String qualityDisplayName(String quality) {
  switch (quality) {
    case 'flac24bit':
      return 'Hi-Res';
    case 'flac':
      return '无损';
    case 'wav':
      return 'WAV';
    case 'ape':
      return 'APE';
    case '320k':
      return '320K';
    case '192k':
      return '192K';
    case '128k':
      return '128K';
    default:
      return quality;
  }
}
