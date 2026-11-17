/// 设置行公开入口：分组容器 + 各类 tile。
///
/// 实现按职责拆在 `tiles/`：`settings_tiles_support`（分组 / 行骨架 / 图标与
/// 标签）、`switch_tile`、`slider_tile`、`navigation_tile`、`action_tile`
/// （复制 / 值 / 颜色）、`info_tile`、`choice_tile`、`dropdown_tile`。
library;

export 'tiles/action_tile.dart';
export 'tiles/choice_tile.dart';
export 'tiles/dropdown_tile.dart';
export 'tiles/info_tile.dart';
export 'tiles/navigation_tile.dart';
export 'tiles/settings_tiles_support.dart';
export 'tiles/slider_tile.dart';
export 'tiles/switch_tile.dart';
