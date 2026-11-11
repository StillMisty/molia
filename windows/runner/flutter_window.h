#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "taskbar_thumb_bar.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 单实例激活：主实例收到第二实例的消息后调用，转 Dart 的
  // WindowChrome.show()（含托盘休眠树重建与最大化恢复）。
  void RequestActivate();

  // 真正退出：Dart 的 WindowChrome.quit() 走通道调用。原生投递销毁消息，
  // 避免在平台通道回调里同步销毁引擎。
  void RequestDestroy();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 任务栏缩略图工具栏（悬浮预览浮层里的播放控制）与它的 Dart 通道：
  // Dart 侧 `lib/services/window/taskbar_thumb_bar_io.dart` 下发状态 / 收点击。
  std::unique_ptr<TaskbarThumbBar> thumb_bar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      taskbar_channel_;

  // 窗口显示通道：Dart 侧 `window_chrome_io.dart` 在托盘恢复时先 cloak，
  // ShowWindow 后等首帧光栅化再 uncloak，避免白色空窗闪一下。
  void ShowAfterFirstFrame(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void FinishShowAfterFirstFrame();
  bool SetWindowCloaked(bool cloak);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // 单实例宿主窗口：隐藏的顶层窗口，只用来接收第二实例的注册消息。
  // 它必须早于 Flutter 窗口的托盘隐藏存在，否则第二实例找不到通知目标。
  void CreateInstanceHostWindow();
  HWND instance_host_window_ = nullptr;

  // 已请求真正退出：之后的 WM_CLOSE 不再转发给 Dart 关闭策略，直接交给
  // 默认窗口过程销毁，避免退出路径被「关闭到托盘」再次拦截。
  bool destroy_pending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
