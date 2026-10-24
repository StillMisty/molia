import 'dart:typed_data';

import 'package:molia/services/save_as.dart';

/// 另存服务测试替身：记录调用，返回可配置结果。
class FakeSaveAs implements SaveAs {
  FakeSaveAs({this.root, this.result});

  /// [rootPath] 返回值。
  String? root;

  /// [saveBytes] / [saveFile] 的返回值；null 时按成功生成。
  SaveAsResult? result;

  /// [saveBytes] 调用记录（按调用顺序）。
  final List<FakeSaveAsBytesCall> saves = [];

  /// [saveFile] 调用记录。
  final List<FakeSaveAsFileCall> savesFile = [];

  /// [reveal] 收到的路径。
  final List<String> revealed = [];

  @override
  Future<String?> rootPath() async => root;

  @override
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir = '',
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    saves.add(
      FakeSaveAsBytesCall(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        relativeDir: relativeDir,
        dialogTitle: dialogTitle,
        allowedExtensions: allowedExtensions,
      ),
    );
    return result ??
        SaveAsSaved(
          path: '/tmp/$relativeDir/$fileName',
          displayPath: '$relativeDir/$fileName',
          kind: SaveLocationKind.fileSystem,
        );
  }

  @override
  Future<SaveAsResult> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    savesFile.add(
      FakeSaveAsFileCall(
        sourcePath: sourcePath,
        fileName: fileName,
        mimeType: mimeType,
        relativeDir: relativeDir,
      ),
    );
    return result ??
        SaveAsSaved(
          path: '/tmp/$relativeDir/$fileName',
          displayPath: '$relativeDir/$fileName',
          kind: SaveLocationKind.fileSystem,
        );
  }

  @override
  Future<bool> reveal(String path) async {
    revealed.add(path);
    return true;
  }
}

/// 一次 `saveBytes` 的入参快照。
class FakeSaveAsBytesCall {
  const FakeSaveAsBytesCall({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.relativeDir,
    required this.dialogTitle,
    required this.allowedExtensions,
  });

  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final String relativeDir;
  final String? dialogTitle;
  final List<String>? allowedExtensions;
}

/// 一次 `saveFile` 的入参快照。
class FakeSaveAsFileCall {
  const FakeSaveAsFileCall({
    required this.sourcePath,
    required this.fileName,
    required this.mimeType,
    required this.relativeDir,
  });

  final String sourcePath;
  final String fileName;
  final String mimeType;
  final String relativeDir;
}
