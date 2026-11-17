/// 应用壳的对外入口：实现按职责拆在 `shell/` 下，main / bootstrap / 测试
/// 继续从这里取壳层公开类型与全局 key。
library;

export 'shell/app_shell.dart' show MyApp, MyThemedApp, ProgressIndicator;
export 'shell/app_shell.dart' show IncomingPairingQueue, navigatorKey;
export 'shell/app_shell.dart' show appRootKey, scaffoldMessengerKey;
