import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/save_as_io.dart';
import 'package:molia/services/save_as_types.dart';
import 'package:path/path.dart' as p;

import '../support/fake_downloads_publisher.dart';

/// 另存服务：桌面直接写 / 对话框取消与回退 / 文件名清洗 / Android 通道。
void main() {
  late Directory root;
  late List<int> bytes;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('molia_save_as_test_');
    bytes = [1, 2, 3, 4];
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  IoSaveAs buildDesktop({SaveFileDialog? dialog}) => IoSaveAs(
        publisher: FakeDownloadsPublisher(supported: false),
        customRoot: () => root.path,
        dialog: dialog,
        android: false,
        ios: false,
      );

  test('桌面无对话框：直接写入另存目录的子目录', () async {
    final saveAs = buildDesktop();
    final result = await saveAs.saveBytes(
      fileName: 'molia_backup.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
    );

    expect(result, isA<SaveAsSaved>());
    final saved = result as SaveAsSaved;
    expect(saved.kind, SaveLocationKind.fileSystem);
    expect(saved.path, p.join(root.path, 'exports', 'molia_backup.json'));
    expect(await File(saved.path).readAsBytes(), bytes);
  });

  test('文件名清洗：标题里的路径分隔符不会写出子目录', () async {
    final saveAs = buildDesktop();
    final result = await saveAs.saveBytes(
      fileName: 'a/b:c.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
    );

    final saved = result as SaveAsSaved;
    expect(p.basename(saved.path), 'a_b_c.json');
    expect(p.dirname(saved.path), p.join(root.path, 'exports'));
    expect(
        await Directory(p.join(root.path, 'exports', 'a')).exists(), isFalse);
  });

  test('桌面对话框选中路径：按用户选择保存', () async {
    final target = p.join(root.path, 'chosen.json');
    String? initialDirectorySeen;
    final saveAs = buildDesktop(
      dialog: ({
        required fileName,
        required bytes,
        required mimeType,
        initialDirectory,
        dialogTitle,
        allowedExtensions,
      }) async {
        initialDirectorySeen = initialDirectory;
        await File(target).writeAsBytes(bytes);
        return target;
      },
    );

    final result = await saveAs.saveBytes(
      fileName: 'backup.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
    );

    expect(result, isA<SaveAsSaved>());
    expect((result as SaveAsSaved).path, target);
    expect(await File(target).readAsBytes(), bytes);
    expect(initialDirectorySeen, p.join(root.path, saveAsExportsDirName));
  });

  test('桌面对话框取消：返回取消且不写默认目录', () async {
    final saveAs = buildDesktop(
      dialog: ({
        required fileName,
        required bytes,
        required mimeType,
        initialDirectory,
        dialogTitle,
        allowedExtensions,
      }) async =>
          null,
    );

    final result = await saveAs.saveBytes(
      fileName: 'backup.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
    );

    expect(result, isA<SaveAsCancelled>());
    expect(
      await File(p.join(root.path, 'backup.json')).exists(),
      isFalse,
    );
  });

  test('桌面对话框不可用：回退直接写默认目录', () async {
    final saveAs = buildDesktop(
      dialog: ({
        required fileName,
        required bytes,
        required mimeType,
        initialDirectory,
        dialogTitle,
        allowedExtensions,
      }) async =>
          throw UnsupportedError('no portal'),
    );

    final result = await saveAs.saveBytes(
      fileName: 'backup.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
    );

    expect(result, isA<SaveAsSaved>());
    expect(
      await File(p.join(root.path, 'backup.json')).exists(),
      isTrue,
    );
  });

  test('Android：写临时文件后经发布器进公共 Downloads', () async {
    final publisher = FakeDownloadsPublisher();
    final saveAs = IoSaveAs(
      publisher: publisher,
      android: true,
      ios: false,
      temporaryDirectory: () async => root,
      customRoot: () => '/ignored',
    );

    final result = await saveAs.saveBytes(
      fileName: 'stats.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
    );

    expect(result, isA<SaveAsSaved>());
    final saved = result as SaveAsSaved;
    expect(saved.kind, SaveLocationKind.downloads);
    expect(saved.displayPath, 'Download/Molia/exports/stats.json');
    expect(publisher.relativeDirs, [saveAsExportsDirName]);
    expect(publisher.displayNames, ['stats.json']);
    expect(publisher.mimeTypes, ['application/json']);
    // 临时文件在发布后清理。
    expect(await File(publisher.published.single).exists(), isFalse);
  });

  test('Android 发布失败：返回失败', () async {
    final saveAs = IoSaveAs(
      publisher: FakeDownloadsPublisher(failPublish: true),
      android: true,
      ios: false,
      temporaryDirectory: () async => root,
    );

    final result = await saveAs.saveBytes(
      fileName: 'stats.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
    );

    expect(result, isA<SaveAsFailed>());
  });

  test('iOS：显示文件 App 相对路径', () async {
    final saveAs = IoSaveAs(
      publisher: FakeDownloadsPublisher(supported: false),
      ios: true,
      android: false,
      customRoot: () => root.path,
    );

    final result = await saveAs.saveBytes(
      fileName: 'stats.json',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
    );

    expect(result, isA<SaveAsSaved>());
    final saved = result as SaveAsSaved;
    expect(saved.kind, SaveLocationKind.filesApp);
    expect(saved.displayPath, 'Molia/exports/stats.json');
    expect(
      await File(p.join(root.path, 'exports', 'stats.json')).exists(),
      isTrue,
    );
  });

  test('根目录：桌面自定义目录优先', () async {
    final saveAs = buildDesktop();
    expect(await saveAs.rootPath(), root.path);
  });

  test('saveFile：已有文件复制到另存目录', () async {
    final source = File(p.join(root.path, 'source', 'song.mp3'));
    await source.parent.create(recursive: true);
    await source.writeAsBytes(bytes);

    final saveAs = buildDesktop();
    final result = await saveAs.saveFile(
      sourcePath: source.path,
      fileName: 'song.mp3',
      mimeType: 'audio/mpeg',
    );

    expect(result, isA<SaveAsSaved>());
    final target = p.join(root.path, 'song.mp3');
    expect(await File(target).readAsBytes(), bytes);
    expect(await source.exists(), isTrue);
  });
}
