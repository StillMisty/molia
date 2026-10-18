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
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
