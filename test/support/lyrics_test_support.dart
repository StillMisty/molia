/// 歌词会话测试支撑：真 provider + 固定状态覆盖。
library;

import 'package:riverpod/misc.dart' show Override;
import 'package:molia/domain/models/lyric_line.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics_service.dart';

import 'provider_test_scope.dart';

/// 用给定服务构造真实 `LyricsProvider`（返回 notifier）。
LyricsProvider buildLyricsProvider(LyricsService service) {
  final scope = ProviderTestScope();
  scope.put<LyricsService>(service);
  return scope.container.read(lyricsProvider.notifier);
}

/// 测试用固定会话状态。
class FixedLyricsProvider extends LyricsProvider {
  FixedLyricsProvider(this.fixed);

  final LyricsState fixed;

  @override
  LyricsState build() => fixed;
}

/// 在测试容器里把歌词会话替换为固定状态。
Override fixedLyricsOverride(LyricsState state) =>
    lyricsProvider.overrideWith(() => FixedLyricsProvider(state));

LyricsState testLyricsState({
  String trackId = '',
  LyricsStatus status = LyricsStatus.idle,
  List<LyricLine> lines = const [],
}) => LyricsState(trackId: trackId, status: status, lines: lines);
