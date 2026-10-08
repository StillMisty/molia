import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lx_script_info.dart';

/// LX 音源脚本的持久化管理（导入、删除、启用状态）。
///
/// 存储于应用支持目录下的 `lx_sources.json`，脚本原文一并保存，
/// 便于导出与引擎每次激活时重新执行。
class LxScriptRepository {
  static const _fileName = 'lx_sources.json';

  final List<LxScriptInfo> _scripts = [];
  String? _activeId;
  File? _file;

  List<LxScriptInfo> get scripts => List.unmodifiable(_scripts);
  String? get activeId => _activeId;

  LxScriptInfo? get activeScript {
    final id = _activeId;
    if (id == null) return null;
    for (final script in _scripts) {
      if (script.id == id) return script;
    }
    return null;
  }

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      _file = file;
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;
      final json = jsonDecode(content);
      if (json is! Map) return;
      _activeId = json['activeId'] as String?;
      final list = json['scripts'];
      if (list is List) {
        _scripts.clear();
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            _scripts.add(LxScriptInfo.fromJson(item));
          } else if (item is Map) {
            _scripts.add(LxScriptInfo.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('[LxScriptRepository] 读取音源失败: $e');
    }
  }

  Future<LxScriptInfo> add(LxScriptInfo script) async {
    final index = _scripts.indexWhere((s) => s.id == script.id);
    if (index >= 0) {
      _scripts[index] = script;
    } else {
      _scripts.add(script);
    }
    await _persist();
    return script;
  }

  /// 用 [updated] 的内容替换 [id] 对应脚本，保留原条目的 id、导入时间与激活态。
  ///
  /// 语义说明：
  /// - [id]/[importedAt] 始终以原条目为准（更新不应改变脚本身份）；
  /// - [updated] 未声明 updateUrl 时保留原条目的 updateUrl（更新源不变）；
  /// - 旧的源声明缓存（[LxScriptInfo.sources]）保留，脚本被重新激活时由
  ///   [cacheSources] 覆盖为最新声明；未激活脚本的缓存不参与 UI 展示。
  ///
  /// 找不到 [id] 时抛 [StateError]（调用方应先确认脚本存在）。
  Future<LxScriptInfo> replace(String id, LxScriptInfo updated) async {
    final index = _scripts.indexWhere((s) => s.id == id);
    if (index < 0) {
      throw StateError('音源脚本不存在: $id');
    }
    final existing = _scripts[index];
    final replaced = LxScriptInfo(
      id: existing.id,
      name: updated.name,
      description: updated.description,
      version: updated.version,
      author: updated.author,
      homepage: updated.homepage,
      script: updated.script,
      importedAt: existing.importedAt,
      updateUrl: updated.updateUrl ?? existing.updateUrl,
      sources: existing.sources,
    );
    _scripts[index] = replaced;
    await _persist();
    return replaced;
  }

  Future<void> remove(String id) async {
    _scripts.removeWhere((s) => s.id == id);
    if (_activeId == id) {
      _activeId = null;
    }
    await _persist();
  }

  Future<void> setActive(String? id) async {
    _activeId = id;
    await _persist();
  }

  Future<void> cacheSources(String id, Map<String, LxSourceDecl> sources) async {
    final index = _scripts.indexWhere((s) => s.id == id);
    if (index < 0) return;
    _scripts[index] = _scripts[index].copyWith(sources: sources);
    await _persist();
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'activeId': _activeId,
        'scripts': _scripts.map((s) => s.toJson()).toList(),
      }));
    } catch (e) {
      debugPrint('[LxScriptRepository] 保存音源失败: $e');
    }
  }
}
