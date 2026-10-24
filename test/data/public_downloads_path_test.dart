import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/files/public_downloads_path.dart';
import 'package:path/path.dart' as p;

/// 公共下载目录解析：自定义目录优先、桌面 Known Folder 注入、回退可解析。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('molia_public_downloads_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('自定义保存位置优先', () async {
    final resolved = await resolvePublicDownloadsRoot(
      customRoot: () => '/home/user/Music',
      downloadsDirectory: () async => temp,
    );

    expect(resolved, '/home/user/Music');
  });

  test('桌面：path_provider 的下载目录下 Molia/', () async {
    final resolved = await resolvePublicDownloadsRoot(
      downloadsDirectory: () async => temp,
    );

    expect(resolved, p.join(temp.path, 'Molia'));
  });

  test('桌面：下载目录解析失败时仍有回退路径', () async {
    final resolved = await resolvePublicDownloadsRoot(
      downloadsDirectory: () async => null,
    );

    expect(resolved, isNotNull);
    expect(resolved, endsWith(p.join('Molia')));
  });
}
