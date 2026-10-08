import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logger/logger.dart';

final logger = Logger();

/// 本地数据库状态：只保留「最近播放上下文（play_contexts）」。
///
/// 笔记 / 记录 / 翻译等数据表已随相关功能移除（见 wave6a）。
class LocalDatabaseProvider with ChangeNotifier {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  bool _isRecentContextsLoading = false;
  bool get isRecentContextsLoading => _isRecentContextsLoading;

  List<Map<String, dynamic>> _recentContexts = [];
  List<Map<String, dynamic>> get recentContexts => _recentContexts;

  void _setRecentContextsLoading(bool value) {
    if (_isRecentContextsLoading == value) {
      return;
    }
    _isRecentContextsLoading = value;
    notifyListeners();
  }

  Future<void> insertOrUpdatePlayContext({
    required String contextUri,
    required String contextType,
    required String contextName,
    required String? imageUrl,
    required int lastPlayedAt,
  }) async {
    try {
      await _dbHelper.insertOrUpdatePlayContext(
        contextUri: contextUri,
        contextType: contextType,
        contextName: contextName,
        imageUrl: imageUrl,
        lastPlayedAt: lastPlayedAt,
      );
      await fetchRecentContexts();
    } catch (e, s) {
      logger.e('Error in insertOrUpdatePlayContext', error: e, stackTrace: s);
    }
  }

  Future<void> fetchRecentContexts({int limit = 15}) async {
    _setRecentContextsLoading(true);
    try {
      final contextsFromDb = await _dbHelper.getRecentPlayContexts(limit);
      _recentContexts = contextsFromDb;
      notifyListeners();
    } catch (e, s) {
      logger.e('Error fetching recent contexts', error: e, stackTrace: s);
      _recentContexts = [];
      notifyListeners();
    } finally {
      _setRecentContextsLoading(false);
    }
  }

  /// 导出最近播放上下文为 JSON 并分享。
  Future<bool> exportDataToJson() async {
    try {
      final playContexts = await _dbHelper.getAllPlayContexts();

      final exportData = {
        'play_contexts': playContexts,
      };

      const jsonEncoder = JsonEncoder.withIndent('  ');
      final jsonString = jsonEncoder.convert(exportData);

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final filePath = '${tempDir.path}/molia_backup_$timestamp.json';

      final file = File(filePath);
      await file.writeAsString(jsonString);

      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath, mimeType: 'application/json')],
          subject: 'Molia Data Backup $timestamp',
        ),
      );

      return result.status == ShareResultStatus.success;
    } catch (e) {
      logger.d('Error during data export: $e');
      return false;
    }
  }

  /// 从 JSON 备份恢复最近播放上下文（兼容只含 play_contexts 的旧备份）。
  Future<bool> importDataFromJson() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (files.isEmpty || files.first.path == null) {
        return false;
      }

      final filePath = files.first.path!;
      final file = File(filePath);
      final jsonString = await file.readAsString();
      final dynamic jsonData = jsonDecode(jsonString);

      if (jsonData is! Map<String, dynamic>) {
        throw Exception('Invalid JSON format: Root object is not a Map.');
      }

      final playContextsData = jsonData['play_contexts'] as List?;

      if (playContextsData == null) {
        throw Exception('Invalid JSON format: Missing play_contexts key.');
      }

      List<Map<String, dynamic>> contextsToImport = [];
      for (var contextMap in playContextsData) {
        if (contextMap is Map<String, dynamic> &&
            contextMap['contextUri'] is String &&
            contextMap['contextType'] is String &&
            contextMap['contextName'] is String &&
            contextMap['lastPlayedAt'] != null) {
          int? lastPlayedAtInt;
          if (contextMap['lastPlayedAt'] is int) {
            lastPlayedAtInt = contextMap['lastPlayedAt'] as int;
          } else if (contextMap['lastPlayedAt'] is String) {
            lastPlayedAtInt = int.tryParse(contextMap['lastPlayedAt']);
          } else if (contextMap['lastPlayedAt'] is double) {
            lastPlayedAtInt = (contextMap['lastPlayedAt'] as double).toInt();
          }

          if (lastPlayedAtInt != null) {
            contextsToImport.add({
              'contextUri': contextMap['contextUri'],
              'contextType': contextMap['contextType'],
              'contextName': contextMap['contextName'],
              'imageUrl': contextMap['imageUrl'],
              'lastPlayedAt': lastPlayedAtInt,
            });
          }
        }
      }

      await _dbHelper.batchInsertOrReplacePlayContexts(contextsToImport);
      await fetchRecentContexts();
      return true;
    } catch (e) {
      logger.d('Error during data import: $e');
      return false;
    }
  }
}
