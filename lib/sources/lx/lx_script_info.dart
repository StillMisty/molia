import 'dart:convert';

import 'package:crypto/crypto.dart';

/// LX Music 自定义源脚本支持的音乐源声明（来自脚本 `inited` 事件）。
class LxSourceDecl {
  final String key; // kw / kg / tx / wy / mg / local / 自定义 key
  final String name;
  final List<String> actions; // musicUrl / lyric / pic / search / musicSearch ...
  final List<String> qualitys;

  const LxSourceDecl({
    required this.key,
    required this.name,
    required this.actions,
    required this.qualitys,
  });

  factory LxSourceDecl.fromJson(String key, dynamic json) {
    final map = (json is Map) ? json : const {};
    return LxSourceDecl(
      key: key,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? map['name'] as String
          : key,
      actions: ((map['actions'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      qualitys: ((map['qualitys'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
    );
  }

  bool supports(String action) => actions.contains(action);

  bool get canSearch => supports('search') || supports('musicSearch');

  bool get canResolveUrl => supports('musicUrl');

  bool get canFetchLyric => supports('lyric');

  bool get canFetchPic => supports('pic');

  Map<String, dynamic> toJson() => {
        'name': name,
        'actions': actions,
        'qualitys': qualitys,
      };
}

/// 一个已导入的 LX 音源脚本及其元信息。
class LxScriptInfo {
  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;
  final String script;
  final int importedAt;

  /// 脚本声明的更新地址（`@updateUrl` 或运行时 `updateAlert` 上报），
  /// 为空表示该脚本未提供在线更新能力。
  final String? updateUrl;

  /// 脚本初始化后声明的源（`inited` 事件之后才有值）。
  final Map<String, LxSourceDecl> sources;

  const LxScriptInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.author,
    required this.homepage,
    required this.script,
    required this.importedAt,
    this.updateUrl,
    this.sources = const {},
  });

  LxScriptInfo copyWith({
    Map<String, LxSourceDecl>? sources,
    String? updateUrl,
  }) {
    return LxScriptInfo(
      id: id,
      name: name,
      description: description,
      version: version,
      author: author,
      homepage: homepage,
      script: script,
      importedAt: importedAt,
      updateUrl: updateUrl ?? this.updateUrl,
      sources: sources ?? this.sources,
    );
  }

  /// 解析脚本头部注释中的元信息。
  ///
  /// 形如：
  /// ```
  /// /**
  ///  * @name 测试脚本
  ///  * @description 我只是一个测试脚本
  ///  * @version 1.0.0
  ///  * @author xxx
  ///  * @homepage http://xxx
  ///  * @updateUrl http://xxx/source.js
  ///  */
  /// ```
  static LxScriptInfo? parse(String script, {String? id}) {
    final headerMatch = RegExp(r'^\s*/\*\*?([\s\S]*?)\*/').firstMatch(script);
    if (headerMatch == null) return null;
    final header = headerMatch.group(1) ?? '';
    final meta = <String, String>{};
    for (final line in header.split('\n')) {
      final m = RegExp(r'@(\w+)\s*:?\s+(.*)').firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2)!.trim();
      if (value.isNotEmpty) meta.putIfAbsent(key, () => value);
    }
    final name = meta['name'];
    if (name == null || name.trim().isEmpty) return null;
    final updateUrl = (meta['updateurl'] ?? '').trim();
    return LxScriptInfo(
      id: id ?? _fingerprint(script),
      name: name.trim(),
      description: (meta['description'] ?? '').trim(),
      version: (meta['version'] ?? '').trim(),
      author: (meta['author'] ?? '').trim(),
      homepage: (meta['homepage'] ?? '').trim(),
      script: script,
      importedAt: DateTime.now().millisecondsSinceEpoch,
      updateUrl: updateUrl.isEmpty ? null : updateUrl,
    );
  }

  static String _fingerprint(String script) {
    final digest = md5.convert(utf8.encode(script)).toString();
    return 'lx_${digest.substring(0, 12)}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'version': version,
        'author': author,
        'homepage': homepage,
        'script': script,
        'importedAt': importedAt,
        'updateUrl': updateUrl,
        'sources': sources.map((key, value) => MapEntry(key, value.toJson())),
      };

  factory LxScriptInfo.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'];
    final sources = <String, LxSourceDecl>{};
    if (rawSources is Map) {
      for (final entry in rawSources.entries) {
        sources[entry.key.toString()] =
            LxSourceDecl.fromJson(entry.key.toString(), entry.value);
      }
    }
    final updateUrl = (json['updateUrl'] as String?)?.trim();
    return LxScriptInfo(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      version: json['version'] as String? ?? '',
      author: json['author'] as String? ?? '',
      homepage: json['homepage'] as String? ?? '',
      script: json['script'] as String? ?? '',
      importedAt: json['importedAt'] as int? ?? 0,
      updateUrl: (updateUrl?.isEmpty ?? true) ? null : updateUrl,
      sources: sources,
    );
  }
}
