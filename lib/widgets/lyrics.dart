/// 歌词页公开入口：页面组件与 FAB 动作模型。
///
/// 实现按职责拆在 `lyrics/`：`lyrics_view`（页面组合）、`lyrics_scroll`
/// （滚动测量与落点）、`lyrics_controls`（空态 / 扩展行 / 操作项）、
/// `lyrics_models`（动作与行角色）。
library;

export 'lyrics/lyrics_models.dart';
export 'lyrics/lyrics_view.dart';
