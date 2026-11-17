/// 播放页封面堆叠（cover deck）的公开入口。
///
/// 实现拆在 `player_cover_deck/` 下；这个文件只做 barrel，避免播放器与测试
/// 大范围改 import。封面身份 / 占位工具仍从这里再导出（迷你条、飞行副本共用）。
library;

export 'cover_appearance.dart' show trackKeyOf;
export 'cover_fallback.dart' show buildDefaultArtwork, buildFallbackArtwork;
export 'player_cover_deck/player_cover_deck.dart' show PlayerCoverDeck;
