import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent/src/apk_size.dart';
import '../../tool/agent/src/zip_index.dart';

/// 只写「中央目录 + EOCD」的合法 zip：`apk_size` 只读中央目录，
/// 不需要本地文件头，测试因此不用造真实压缩数据。
List<int> _buildCentralDirectoryZip(
  List<(String name, int compressed, int uncompressed)> entries,
) {
  final central = BytesBuilder();
  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.$1);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint32(20, entry.$2, Endian.little)
      ..setUint32(24, entry.$3, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(nameBytes);
  }
  final directory = central.toBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, 0, Endian.little);
  return (BytesBuilder()
        ..add(directory)
        ..add(end.buffer.asUint8List()))
      .toBytes();
}

void main() {
  group('groupOf', () {
    test('按已知前缀归类', () {
      expect(groupOf('lib/arm64-v8a/libapp.so'), 'lib/');
      expect(groupOf('assets/flutter_assets/fonts/x.ttf'), 'flutter_assets/');
      expect(groupOf('res/drawable/icon.png'), 'res/');
      expect(groupOf('META-INF/MANIFEST.MF'), 'META-INF/');
      expect(groupOf('kotlin/reflect.kotlin_module'), 'kotlin/');
    });

    test('dex 与未知顶层目录', () {
      expect(groupOf('classes.dex'), 'dex');
      expect(groupOf('classes2.dex'), 'dex');
      expect(groupOf('AndroidManifest.xml'), 'AndroidManifest.xml');
    });
  });

  group('humanBytes', () {
    test('1024 进制与两位小数', () {
      expect(humanBytes(0), '0B');
      expect(humanBytes(1023), '1023B');
      expect(humanBytes(1024), '1.00KB');
      expect(humanBytes(1536), '1.50KB');
      expect(humanBytes(3 * 1024 * 1024), '3.00MB');
    });
  });

  group('readZipDirectory', () {
    test('读出条目名与压缩前后大小', () {
      final dir = Directory.systemTemp.createTempSync('molia-zip-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/fake.zip')
        ..writeAsBytesSync(
          _buildCentralDirectoryZip([
            ('lib/arm64-v8a/libapp.so', 100, 400),
            ('classes.dex', 50, 200),
          ]),
        );

      final entries = readZipDirectory(file);
      expect(entries.map((entry) => entry.name), [
        'lib/arm64-v8a/libapp.so',
        'classes.dex',
      ]);
      expect(entries.first.compressedSize, 100);
      expect(entries.first.uncompressedSize, 400);
    });

    test('非 ZIP 文件报格式错误', () {
      final dir = Directory.systemTemp.createTempSync('molia-zip-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/not.zip')
        ..writeAsBytesSync(List<int>.filled(64, 0));
      expect(() => readZipDirectory(file), throwsA(isA<FormatException>()));
    });
  });

  group('checkApk', () {
    ApkReport reportWith(List<String> libNames) => ApkReport(
      path: 'app.apk',
      size: 1,
      groups: {'lib/': SizeGroup()},
      libs: [
        for (final name in libNames)
          ZipSizeEntry(
            name: 'lib/arm64-v8a/$name',
            compressedSize: 1,
            uncompressedSize: 1,
          ),
      ],
      top: const [],
    );

    test('约束通过时没有错误', () {
      expect(
        checkApk(
          reportWith(const ['libsqlite3.so', 'libquickjs_c_bridge_plugin.so']),
        ),
        isEmpty,
      );
    });

    test('报告禁止库与缺失必需库', () {
      final errors = checkApk(
        reportWith(const ['libmpv.so', 'libcnativeapi.so']),
      );
      expect(errors, hasLength(4));
      expect(errors.any((error) => error.contains('libmpv.so')), isTrue);
      expect(
        errors.any((error) => error.contains('缺少必需库 libsqlite3.so')),
        isTrue,
      );
    });
  });

  group('inspectApk', () {
    test('汇总分组、lib 明细与最大条目', () {
      final dir = Directory.systemTemp.createTempSync('molia-apk-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/app.apk')
        ..writeAsBytesSync(
          _buildCentralDirectoryZip([
            ('lib/arm64-v8a/libapp.so', 300, 900),
            ('lib/arm64-v8a/libsqlite3.so', 100, 200),
            ('classes.dex', 500, 2000),
            ('assets/flutter_assets/x', 50, 100),
          ]),
        );

      final report = inspectApk(file);
      expect(report.libs.map((lib) => lib.name), [
        'lib/arm64-v8a/libapp.so',
        'lib/arm64-v8a/libsqlite3.so',
      ]);
      expect(report.sortedGroups.map((entry) => entry.key), [
        'dex',
        'lib/',
        'flutter_assets/',
      ]);
      expect(report.top.first.name, 'classes.dex');
    });
  });
}
