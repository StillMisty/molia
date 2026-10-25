import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/cover_resolution.dart';

import '../support/fake_cover_index.dart';

Track _track({
  String sourceKey = 'wy',
  String songId = '1',
  String? artwork,
}) =>
    Track(
      id: TrackId(sourceKey, songId),
      title: 'T',
      origin: TrackOrigin.builtin,
      artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
    );

void main() {
  test('来源顺序：自定义 > 原始 > 默认；默认只在展示面出现', () {
    const original = 'https://img.example/original.jpg';
    const custom = 'file:///covers/custom.jpg';
    const defaultCover = 'file:///covers/default.jpg';
    final index = FakeCoverIndex(
      defaultUrl: defaultCover,
      customUrls: const {'wy:1': custom},
    );
    final covers = CoverResolver(index);
    final track = _track(artwork: original);

    final withCustom = covers.displayOf(track);
    expect(withCustom.url, custom);
    expect(withCustom.origin, CoverOrigin.custom);
    expect(withCustom.real.isCustom, isTrue);
    expect(covers.realOf(track).url, custom);

    index.customUrls.clear();
    final withOriginal = covers.displayOf(track);
    expect(withOriginal.url, original);
    expect(withOriginal.origin, CoverOrigin.original);
    expect(covers.realOf(track).origin, CoverOrigin.original);

    final withoutArtwork = covers.displayOf(_track());
    expect(withoutArtwork.url, defaultCover);
    expect(withoutArtwork.origin, CoverOrigin.defaultCover);
    expect(withoutArtwork.usesDefaultCover, isTrue);
    expect(withoutArtwork.primaryUrl, isNull, reason: '默认封面只做回退，不能成为主图');
    expect(withoutArtwork.real, const RealCover.none());
  });

  test('只有默认封面：展示可取，真实封面为空（取色 / 下载拿不到）', () {
    final index = FakeCoverIndex(defaultUrl: 'file:///covers/default.jpg');
    final covers = CoverResolver(index);
    final track = _track();

    expect(covers.realOf(track), const RealCover.none());
    expect(covers.realOf(track).url, isNull);

    final display = covers.displayOf(track);
    expect(display.url, 'file:///covers/default.jpg');
    expect(display.origin, CoverOrigin.defaultCover);
  });

  test('local 下载副本剥一层前缀，命中下载前的原曲封面', () {
    const custom = 'file:///covers/wy-123.jpg';
    final index = FakeCoverIndex(customUrls: const {'wy:123': custom});
    final covers = CoverResolver(index);

    final byId = covers.realForId(const TrackId('local', 'wy:123'));
    expect(byId.url, custom);
    expect(byId.origin, CoverOrigin.custom);

    final byKey = covers.realForKey(
      'local:wy:123',
      originalUrl: 'https://img.example/original.jpg',
    );
    expect(byKey.url, custom);
    expect(normalizeCoverKey('local:wy:123'), 'wy:123');
  });

  test('本地导入保持 local:<path> 记录键，不二次剥离', () {
    const importedKey = 'local:/music/a.mp3';
    const custom = 'file:///covers/imported.jpg';
    final index = FakeCoverIndex(customUrls: const {importedKey: custom});
    final covers = CoverResolver(index);
    const id = TrackId('local', importedKey);

    expect(coverKeyOf(id), importedKey);
    expect(covers.realForId(id).url, custom);

    // 字符串入口传的是 TrackId.uri 形状（local:local:/...），只剥一层。
    expect(normalizeCoverKey('local:$importedKey'), importedKey);
    expect(covers.realForKey('local:$importedKey').url, custom);
  });

  test('变更信号来自索引，取消订阅后不再回调', () {
    final index = FakeCoverIndex();
    final covers = CoverResolver(index);
    var changes = 0;
    final remove = covers.addChangeListener(() => changes++);

    index.notifyChanged();
    expect(changes, 1);

    remove();
    index.notifyChanged();
    expect(changes, 1);
  });

  test('读取自定义封面字节按规范键查询（下载 / 标签入口）', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final index = FakeCoverIndex(
      customBytes: {'wy:9': bytes},
    );
    final covers = CoverResolver(index);

    expect(
      await covers.readCustomCoverBytes(_track(songId: '9')),
      bytes,
    );
    expect(
      await covers.readCustomCoverBytesForKey('local:wy:9'),
      bytes,
    );
    expect(index.readCount, 2);
  });
}
