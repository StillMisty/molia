import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart';
import '../data/molia_database.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';

final logger = Logger('molia.local_database_provider');

/// 本地数据库状态：只保留「最近播放上下文（play_contexts）」。
class LocalDatabaseProvider with ChangeNotifier {
  /// [database] 仅测试注入；生产走 [MoliaDatabase.instance]（懒加载单例）。
  LocalDatabaseProvider({MoliaDatabase? database})
      : _db = database ?? MoliaDatabase.instance;

  final MoliaDatabase _db;

  bool _isRecentContextsLoading = false;
  bool get isRecentContextsLoading => _isRecentContextsLoading;

  List<PlayContext> _recentContexts = [];
  List<PlayContext> get recentContexts => _recentContexts;

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
      await _db.insertOrUpdatePlayContext(
        contextUri: contextUri,
        contextType: contextType,
        contextName: contextName,
        imageUrl: imageUrl,
        lastPlayedAt: lastPlayedAt,
      );
      await fetchRecentContexts();
    } catch (e, s) {
      logger.severe('Error in insertOrUpdatePlayContext', e, s);
    }
  }

  Future<void> fetchRecentContexts({int limit = 15}) async {
    _setRecentContextsLoading(true);
    try {
      final contextsFromDb = await _db.getRecentPlayContexts(limit);
      _recentContexts = contextsFromDb;
      notifyListeners();
    } catch (e, s) {
      logger.severe('Error fetching recent contexts', e, s);
      _recentContexts = [];
      notifyListeners();
    } finally {
      _setRecentContextsLoading(false);
    }
  }

  /// 分享一份 JSON 文本为备份文件（跨设备同步的完整备份走这里）。
  Future<bool> shareJsonBackup(
    String jsonString, {
    String prefix = 'molia_backup',
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final filePath = '${tempDir.path}/${prefix}_$timestamp.json';

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
      logger.fine('Error during data export: $e');
      return false;
    }
  }

  /// 选择并读取一份 JSON 备份文件；取消/读取失败返回 null。
  Future<String?> pickJsonBackup() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = files.isEmpty ? null : files.first.path;
      if (path == null) return null;
      return await File(path).readAsString();
    } catch (e) {
      logger.fine('Error during data import: $e');
      return null;
    }
  }

  /// 导出最近播放上下文为 JSON 并分享。
  Future<bool> exportDataToJson() async {
    try {
      final playContexts = await _db.getAllPlayContexts();

      final exportData = {
        'play_contexts': [for (final context in playContexts) context.toJson()],
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
      logger.fine('Error during data export: $e');
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

      await _db.batchInsertOrReplacePlayContexts(contextsToImport);
      await fetchRecentContexts();
      return true;
    } catch (e) {
      logger.fine('Error during data import: $e');
      return false;
    }
  }
}
