import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/playback_order.dart';
import 'package:molia/sources/source_track.dart';

/// 播放顺序栈：压栈 / 弹栈 / 上限 / 清空 / 队列还原（越界忽略）。
SourceTrack _source(String id) => SourceTrack(
      sourceKey: 'fake',
      origin: 'lx',
      title: 'Title $id',
      artist: 'Artist',
      album: 'Album',
      raw: {'id': id},
    );

void main() {
  test('record 压栈、popPrevious 弹栈（后进先出）', () {
    final order = PlaybackOrder();

    expect(order.isEmpty, isTrue);
    expect(order.popPrevious(), isNull);

    order.record(0);
    order.record(2);
    expect(order.isEmpty, isFalse);
    expect(order.popPrevious(), 2);
    expect(order.popPrevious(), 0);
    expect(order.popPrevious(), isNull);
    expect(order.isEmpty, isTrue);
  });

  test('栈深上限：超出后丢弃最早记录', () {
    final order = PlaybackOrder(maxEntries: 3);
    for (var i = 0; i < 5; i++) {
      order.record(i);
    }
    expect(order.popPrevious(), 4);
    expect(order.popPrevious(), 3);
    expect(order.popPrevious(), 2);
    expect(order.popPrevious(), isNull);
  });

  test('clear 清空；tracksOf 按队列还原且忽略越界下标', () {
    final queue = [_source('a'), _source('b')];
    final order = PlaybackOrder();

    order.record(0);
    order.record(1);
    expect(order.tracksOf(queue).map((track) => track.id), ['fake:a', 'fake:b']);

    order.record(9); // 越界（模拟队列被替换）
    expect(order.tracksOf(queue).map((track) => track.id), ['fake:a', 'fake:b']);

    order.clear();
    expect(order.isEmpty, isTrue);
    expect(order.tracksOf(queue), isEmpty);
  });
}
