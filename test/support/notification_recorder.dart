import 'package:material_ui/material_ui.dart';
import 'package:molia/services/notification_service.dart';

/// 记录型提示服务（测试用）。
///
/// 生产实现经 `hostContextKey` 展示 `M3ESnackbar`，而默认构造缺这个 key
/// （展示是空操作）；测试只收文案与动作，用于断言「弹了什么、点了什么」。
class RecordingNotificationService extends NotificationService {
  RecordingNotificationService()
      : super(GlobalKey<ScaffoldMessengerState>());

  /// 依序收到的提示文案。
  final List<String> messages = [];

  /// 最近一条提示的动作标签（null = 无动作）。
  String? lastActionLabel;

  /// 最近一条提示的动作回调（点它模拟用户点动作）。
  VoidCallback? lastAction;

  bool get isEmpty => messages.isEmpty;

  String get last => messages.isEmpty ? '' : messages.last;

  void clear() {
    messages.clear();
    lastActionLabel = null;
    lastAction = null;
  }

  @override
  void showSnackBar(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    void Function()? onActionPressed,
  }) {
    messages.add(message);
    lastActionLabel = actionLabel;
    lastAction = onActionPressed;
  }
}
