/// 本地音频 locator 的纯 Dart 规则：路径与 Android SAF `content://` 共用。
///
/// 本地曲库的 `path` 字段在桌面是绝对路径、在 Android 是树授权下的文档
/// URI。比较、扩展名、展示名都必须按 locator 类型分派，不能把 `content://`
/// 丢给 `package:path` 或 `dart:io`。
library;

import 'package:path/path.dart' as p;

import '../local_identity.dart';

/// 是否为 SAF `content://` locator。
bool isContentLocator(String locator) => locator.startsWith('content://');

/// 是否为可交给播放器的本地 locator（绝对路径 / `file:` / `content:`）。
bool isLocalPlayableLocator(String locator) {
  if (isContentLocator(locator)) return true;
  if (locator.startsWith('file://')) return true;
  return p.isAbsolute(locator);
}

/// 本地音频 locator → 播放器 URI。
///
/// `content://` / `file://` 原样解析；桌面裸路径转 `file:`。
Uri playableUriForLocator(String locator) {
  if (isContentLocator(locator) || locator.startsWith('file://')) {
    return Uri.parse(locator);
  }
  return Uri.file(locator);
}

/// 比较 / 去重键；内容 URI 原样保留（provider 决定大小写语义），
/// 路径沿用平台大小写规则。
String localLocatorKey(String locator) {
  if (isContentLocator(locator)) return locator;
  if (locator.startsWith('file://')) {
    final uri = Uri.tryParse(locator);
    if (uri != null) return localPathKey(uri.toFilePath());
  }
  return localPathKey(locator);
}

/// locator 剩余的相对路径（`root` 不存在于 [locator] 时返回 null）。
String? relativeLocatorPath(String root, String locator) {
  if (isContentLocator(root) || isContentLocator(locator)) {
    if (!isContentLocator(root) || !isContentLocator(locator)) return null;
    final rootTree = _contentTreeIdOf(root);
    final locatorTree = _contentTreeIdOf(locator);
    if (rootTree == null || rootTree != locatorTree) return null;
    final rootDoc = _contentDocumentIdOf(root);
    final locatorDoc = _contentDocumentIdOf(locator);
    if (rootDoc == null || locatorDoc == null) return null;
    if (locatorDoc == rootDoc) return '';
    final prefix = '$rootDoc/';
    return locatorDoc.startsWith(prefix)
        ? locatorDoc.substring(prefix.length)
        : null;
  }
  final rootKey = localLocatorKey(root);
  final locatorKey = localLocatorKey(locator);
  if (locatorKey == rootKey) return '';
  final prefix = rootKey.endsWith(p.separator)
      ? rootKey
      : '$rootKey${p.separator}';
  return locatorKey.startsWith(prefix)
      ? locatorKey.substring(prefix.length)
      : null;
}

/// [locator] 是否在 [root] 之下（含根自身）。
bool isLocatorUnder(String root, String locator) =>
    relativeLocatorPath(root, locator) != null;

/// 由文档 URI 推出树 URI（SAF 权限是按树授予的）。
///
/// `content://auth/tree/<treeId>/document/<docId>` → `content://auth/tree/<treeId>`；
/// 树 URI 本身原样返回。无法解析时返回 null。
String? contentTreeUriOf(String locator) {
  if (!isContentLocator(locator)) return null;
  // 保留原始百分号编码：树 URI 会与 picker 返回值 / 持久化值直接比较。
  final marker = '/tree/';
  final index = locator.indexOf(marker);
  if (index < 0) return null;
  final rest = locator.substring(index + marker.length);
  final slash = rest.indexOf('/');
  final end = slash < 0 ? locator.length : index + marker.length + slash;
  return locator.substring(0, end);
}

/// SAF 文档 URI 的展示名（文档 id 的最后一段；树 URI 去掉 `primary:` 前缀）。
String? contentDisplayNameOf(String locator) {
  final id = _contentDocumentIdOf(locator);
  if (id == null || id.isEmpty) return null;
  final segment = id.split('/').last;
  final colon = segment.lastIndexOf(':');
  final name = colon >= 0 ? segment.substring(colon + 1) : segment;
  return name.isEmpty ? null : name;
}

/// 用户可见的文件夹名：路径原样返回（桌面习惯看完整路径），
/// `content://` 只返回 provider 名 / 文档 id 尾段。
String folderDisplayName(String root, {String? storedName}) {
  if (!isContentLocator(root)) return root;
  final stored = storedName?.trim() ?? '';
  if (stored.isNotEmpty) return stored;
  return contentDisplayNameOf(root) ?? '';
}

/// 音频扩展名（不带点）；从显示名 / 路径取，绝不解析 `content://` 整串。
String audioExtensionOfLocator(String locator) {
  final name = _fileNameOfLocator(locator);
  return p.extension(name).toLowerCase().replaceFirst('.', '');
}

/// 无扩展名的文件名（标签缺失时的标题回退）。
String audioBaseNameOfLocator(String locator) =>
    p.basenameWithoutExtension(_fileNameOfLocator(locator));

/// 含扩展名的文件名。
String audioFileNameOfLocator(String locator) => _fileNameOfLocator(locator);

String _fileNameOfLocator(String locator) {
  if (isContentLocator(locator)) {
    final id = _contentDocumentIdOf(locator);
    if (id == null || id.isEmpty) return '';
    return id.split('/').last;
  }
  if (locator.startsWith('file://')) {
    final uri = Uri.tryParse(locator);
    if (uri != null) return p.basename(uri.toFilePath());
  }
  return p.basename(locator);
}

String? _contentTreeIdOf(String locator) {
  final segments = Uri.tryParse(locator)?.pathSegments ?? const [];
  final index = segments.indexOf('tree');
  return index >= 0 && index + 1 < segments.length ? segments[index + 1] : null;
}

String? _contentDocumentIdOf(String locator) {
  final segments = Uri.tryParse(locator)?.pathSegments ?? const [];
  final treeIndex = segments.indexOf('tree');
  if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;
  final documentIndex = segments.indexOf('document', treeIndex + 2);
  if (documentIndex >= 0 && documentIndex + 1 < segments.length) {
    return segments.sublist(documentIndex + 1).join('/');
  }
  // 树 URI 自身：文档 id 就是树 id。
  return segments.sublist(treeIndex + 1).join('/');
}
