/// 壳层底部导航的三个一级目的地。
///
/// 声明顺序 = 导航条目的固定子页顺序：调整顺序 / 可见性只影响底栏渲染与
/// 选中映射，不移动页面栈子节点，页面状态天然保持。
///
/// 放在 domain：壳层展示决策、导航偏好与页面栈都消费同一个枚举，避免
/// `ShellPresentation` 为了一个枚举反向依赖 provider 层。
library;

enum ShellDestination { nowPlaying, favorites, library }
