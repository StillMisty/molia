import 'package:flutter/widgets.dart';

import 'app/bootstrap/app_bootstrap.dart';

/// 唯一 composition root：初始化绑定后交给 `runMoliaApp()`。
/// 各平台装配与业务栈的顺序调用见 `lib/app/bootstrap/app_bootstrap.dart`。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runMoliaApp();
}
