import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lx_script_info.dart';

/// 在线更新脚本时的错误类型（UI 可据此给出可读文案）。
enum ScriptUpdateError {
  /// 目标脚本不存在（可能已被删除）。
  scriptNotFound,

  /// 脚本未声明 `@updateUrl`，也没有通过 `updateAlert` 上报过更新地址。
  noUpdateUrl,

  /// 网络错误 / 非 200 响应 / 超时。
  downloadFailed,

  /// 下载内容超过大小上限。
  tooLarge,

  /// 下载内容缺少 LX 脚本元信息或 `lx` 用法，不是合法脚本。
  notAScript,

  /// 更新地址指向网页（HTML），需要用户打开更新页手动导入。
  htmlPage,
}

/// 在线更新流程的可读异常：message 直接用于展示（中文），
/// [kind] 供 UI 做本地化映射（如 HTML 地址提示走 l10n）。
class ScriptUpdateException implements Exception {
  final ScriptUpdateError kind;
  final String message;

  const ScriptUpdateException(this.kind, this.message);

  @override
  String toString() => message;
}

/// 一次脚本更新检查的结果。
class ScriptUpdateCheck {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;

  /// 下载并解析后的最新脚本（id 沿用当前脚本，importedAt 为下载时刻，仅作载体）。
  final LxScriptInfo latestScript;

  const ScriptUpdateCheck({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.latestScript,
  });
}

/// 在线更新下载的大小上限：1MB（LX 脚本通常几十 KB，超过必为异常内容）。
const int kLxScriptMaxBytes = 1024 * 1024;

/// 在线更新下载超时。
const Duration kLxScriptDownloadTimeout = Duration(seconds: 10);

/// 下载脚本原文。
///
/// - 10s 超时（响应头与响应体分别计时）；
/// - 跟随重定向（http 包默认行为，显式开启以免被改动）；
/// - 响应体超过 [kLxScriptMaxBytes] 立即中止，避免内存被异常内容占满。
///
/// 所有失败统一抛 [ScriptUpdateException]（可读 message）。
Future<String> downloadLxScriptText(String url, {http.Client? client}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw const ScriptUpdateException(
        ScriptUpdateError.downloadFailed, '更新地址不是有效的 HTTP(S) 链接');
  }
  final ownClient = client ?? http.Client();
  try {
    final request = http.Request('GET', uri)..followRedirects = true;
    final response =
        await ownClient.send(request).timeout(kLxScriptDownloadTimeout);
    if (response.statusCode != 200) {
      throw ScriptUpdateException(ScriptUpdateError.downloadFailed,
          '下载失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(kLxScriptDownloadTimeout)) {
      bytes.addAll(chunk);
      if (bytes.length > kLxScriptMaxBytes) {
        throw const ScriptUpdateException(ScriptUpdateError.tooLarge,
            '脚本文件超过 1MB 上限，已中止下载');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on ScriptUpdateException {
    rethrow;
  } on TimeoutException {
    throw const ScriptUpdateException(
        ScriptUpdateError.downloadFailed, '下载超时，请检查网络后重试');
  } catch (e) {
    throw ScriptUpdateException(
        ScriptUpdateError.downloadFailed, '下载失败：$e');
  } finally {
    if (client == null) ownClient.close();
  }
}

/// 粗略判断下载内容是否为网页（而非脚本文件）。
bool looksLikeHtml(String text) {
  final head = text.trimLeft().toLowerCase();
  if (head.startsWith('<!doctype html') || head.startsWith('<html')) {
    return true;
  }
  return head.contains('<head') && head.contains('</html>');
}

/// 是否包含 LX 脚本应有的 `lx` 用法（`lx.on/send/request` 或 `globalThis.lx`）。
bool looksLikeLxScript(String text) {
  if (text.contains('globalThis.lx') || text.contains('window.lx')) {
    return true;
  }
  return RegExp(r'\blx\s*\.\s*(on|send|request|utils)\b').hasMatch(text);
}

/// 把下载内容解析为 LX 脚本；内容非法时抛可读的 [ScriptUpdateException]。
///
/// 校验顺序：元信息（`/** @name ... */`）→ `lx` 用法 → 网页特征。
LxScriptInfo parseDownloadedScript(String text, {required String id}) {
  final parsed = LxScriptInfo.parse(text, id: id);
  if (parsed == null) {
    if (looksLikeHtml(text)) {
      throw const ScriptUpdateException(ScriptUpdateError.htmlPage,
          '该地址不是脚本文件，请打开更新页手动导入');
    }
    throw const ScriptUpdateException(
        ScriptUpdateError.notAScript, '下载的内容不是有效的 LX 音源脚本（缺少元信息）');
  }
  if (!looksLikeLxScript(text)) {
    throw const ScriptUpdateException(
        ScriptUpdateError.notAScript, '下载的内容不是有效的 LX 音源脚本（未使用 lx 接口）');
  }
  return parsed;
}
