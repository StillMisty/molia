import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/covers/cover_image_fetcher.dart';

/// 封面原图读取：本地 / data URL / 网络直取与保存命名。
void main() {
  test('data URL：base64 解码；非 base64 返回 null', () async {
    final fetcher = CoverImageFetcher();
    final payload = base64Encode(const [1, 2, 3, 4]);
    expect(await fetcher.read('data:image/jpeg;base64,$payload'), [1, 2, 3, 4]);
    expect(await fetcher.read('data:text/plain,hello'), isNull);
  });

  test('file URL：读取本地文件；超过上限返回 null', () async {
    final dir = await Directory.systemTemp.createTemp('molia_cover_fetcher_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cover.jpg')
      ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0x00]);
    final url = Uri.file(file.path).toString();

    expect(await CoverImageFetcher().read(url), [0xFF, 0xD8, 0xFF, 0x00]);
    expect(await CoverImageFetcher(maxBytes: 2).read(url), isNull);
  });

  test('网络：allowNetwork=false 不触网；允许时走注入下载', () async {
    var calls = 0;
    final fetcher = CoverImageFetcher(
      downloadBytes: (url) async {
        calls++;
        return Uint8List.fromList(const [9, 8, 7]);
      },
    );
    const url = 'https://example.com/cover.jpg';

    expect(await fetcher.read(url, allowNetwork: false), isNull);
    expect(calls, 0);
    expect(await fetcher.read(url), [9, 8, 7]);
    expect(calls, 1);
  });

  test('扩展名：字节魔数优先，未知回退 URL 后缀', () {
    final jpeg = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0x00]);
    final png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]);
    final unknown = Uint8List.fromList(const [1, 2, 3]);

    expect(
      CoverImageFetcher.extensionFor(url: 'https://x/a.webp', bytes: jpeg),
      'jpg',
    );
    expect(
      CoverImageFetcher.extensionFor(url: 'https://x/a.jpg', bytes: png),
      'png',
    );
    expect(
      CoverImageFetcher.extensionFor(url: 'https://x/a.webp', bytes: unknown),
      'webp',
    );
    expect(
      CoverImageFetcher.extensionFor(url: 'https://x/a', bytes: unknown),
      'jpg',
    );
  });

  test('MIME / 文件名：按嗅探结果映射并清洗标题', () {
    expect(CoverImageFetcher.mimeTypeFor('png'), 'image/png');
    expect(CoverImageFetcher.mimeTypeFor('webp'), 'image/webp');
    expect(CoverImageFetcher.mimeTypeFor('jpg'), 'image/jpeg');
    expect(
      CoverImageFetcher.fileNameFor(base: 'A/B', extension: 'png'),
      'A_B.png',
    );
    expect(
      CoverImageFetcher.fileNameFor(base: '  ', extension: 'webp'),
      'cover.webp',
    );
  });
}
