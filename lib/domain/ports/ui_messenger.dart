import '../models/failure.dart';

/// UI 反馈端口：provider 不 import main.dart / 不拿 BuildContext，
/// 通过注入的实现弹条（composition root 内用 navigatorKey/scaffoldMessengerKey 适配）。
abstract interface class UiMessenger {
  void showMessage(String message);
  void showFailure(SourceFailure failure);
}
