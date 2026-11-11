#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"
#include "taskbar_thumb_bar.h"
#include "utils.h"

namespace {

// 任务栏通道：与 Dart 侧 `lib/services/window/taskbar_thumb_bar_io.dart` 的通道名
// 成对出现，改一处必须改两处。
constexpr char kTaskbarChannelName[] = "top.stillmisty.molia/taskbar";

// 窗口显示通道：与 Dart 侧 `lib/services/window/window_chrome_io.dart` 成对。
constexpr char kWindowChannelName[] = "top.stillmisty.molia/window";

// 首帧没到达时的恢复兜底：避免 DWM cloak 残留导致窗口一直不可见。
constexpr UINT_PTR kShowFallbackTimerId = 0x4D4F4C49;  // 'MOLI'
constexpr UINT kShowFallbackTimeoutMs = 300;

// 平台通道里请求真正退出后，投递到消息循环再销毁窗口。不能在这个通道
// 回调里直接 DestroyWindow：WM_DESTROY 会同步拆掉正在回调的引擎。
constexpr UINT kDestroyWindowMessage = WM_APP + 0x4D;  // 'M'

#ifndef DWMWA_CLOAK
#define DWMWA_CLOAK 13
#endif

bool ReadBool(const flutter::EncodableMap& arguments, const char* key) {
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) {
    return false;
  }
  const bool* value = std::get_if<bool>(&entry->second);
  return value != nullptr && *value;
}

std::wstring ReadString(const flutter::EncodableMap& arguments,
                        const char* key) {
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) {
    return std::wstring();
  }
  const std::string* value = std::get_if<std::string>(&entry->second);
  return value == nullptr ? std::wstring() : Utf16FromUtf8(*value);
}

std::string ActionName(TaskbarThumbBar::Action action) {
  switch (action) {
    case TaskbarThumbBar::Action::kFavorite:
      return "favorite";
    case TaskbarThumbBar::Action::kPrevious:
      return "previous";
    case TaskbarThumbBar::Action::kPlayPause:
      return "playPause";
    case TaskbarThumbBar::Action::kNext:
      return "next";
  }
  return std::string();
}

// 单实例宿主窗口只接收注册消息；收到后请 FlutterWindow 转 Dart 恢复窗口。
LRESULT CALLBACK InstanceHostWndProc(HWND window,
                                     UINT const message,
                                     WPARAM const wparam,
                                     LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(
        window, GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  } else if (message == single_instance::ActivateMessage()) {
    auto* flutter_window = reinterpret_cast<FlutterWindow*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (flutter_window != nullptr) {
      flutter_window->RequestActivate();
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 任务栏缩略图工具栏（悬浮任务栏按钮时预览浮层里的播放控制按钮）：
  // 按钮状态由 Dart 侧下发（播放 / 收藏 / 语言），点击回调经通道回 Dart。
  taskbar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kTaskbarChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  taskbar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "update") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "update 需要 map 参数");
          return;
        }
        TaskbarThumbBar::State state;
        state.has_track = ReadBool(*arguments, "hasTrack");
        state.is_playing = ReadBool(*arguments, "isPlaying");
        state.is_favorite = ReadBool(*arguments, "isFavorite");
        state.tooltip_previous = ReadString(*arguments, "tooltipPrevious");
        state.tooltip_play_pause = ReadString(*arguments, "tooltipPlayPause");
        state.tooltip_next = ReadString(*arguments, "tooltipNext");
        state.tooltip_favorite = ReadString(*arguments, "tooltipFavorite");
        if (thumb_bar_ != nullptr) {
          thumb_bar_->UpdateState(state);
        }
        result->Success();
      });

  // 窗口显示通道：托盘恢复时 Dart 侧调 showAfterFirstFrame，先 cloak 再
  // ShowWindow，首帧光栅化后 uncloak（避免白色空窗闪一下）。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "showAfterFirstFrame") {
          ShowAfterFirstFrame(std::move(result));
        } else if (call.method_name() == "destroy") {
          if (GetHandle() == nullptr) {
            result->Error("window_unavailable", "窗口尚未就绪");
          } else {
            RequestDestroy();
            result->Success();
          }
        } else {
          result->NotImplemented();
        }
      });

  // 单实例宿主窗口必须早于托盘隐藏创建：第二实例启动时靠它找到本进程。
  CreateInstanceHostWindow();

  thumb_bar_ = std::make_unique<TaskbarThumbBar>();
  thumb_bar_->Attach(
      GetHandle(),
      [this](TaskbarThumbBar::Action action) {
        if (taskbar_channel_ != nullptr) {
          taskbar_channel_->InvokeMethod(
              "pressed",
              std::make_unique<flutter::EncodableValue>(ActionName(action)));
        }
      },
      // 诊断：原生只上报事件名与 HRESULT（文案在 Dart 侧组，原生不碰 l10n）。
      // 真机排查时靠它区分「TaskbarButtonCreated 没来」与「调用失败」。
      [this](const char* event, HRESULT hr) {
        if (taskbar_channel_ == nullptr) {
          return;
        }
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("event")] =
            flutter::EncodableValue(std::string(event));
        payload[flutter::EncodableValue("hr")] =
            flutter::EncodableValue(static_cast<int32_t>(hr));
        taskbar_channel_->InvokeMethod(
            "debug", std::make_unique<flutter::EncodableValue>(payload));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::CreateInstanceHostWindow() {
  const std::wstring& class_name = single_instance::HostWindowClassName();
  HINSTANCE instance = GetModuleHandleW(nullptr);

  WNDCLASSW window_class{};
  window_class.hInstance = instance;
  window_class.lpfnWndProc = InstanceHostWndProc;
  window_class.lpszClassName = class_name.c_str();
  // 同一进程只建一次；失败（类已存在）不影响后续 CreateWindowExW。
  RegisterClassW(&window_class);

  instance_host_window_ = ::CreateWindowExW(
      0, class_name.c_str(), L"Molia", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      instance, this);
  if (instance_host_window_ != nullptr) {
    SetWindowLongPtrW(instance_host_window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
  }
}

void FlutterWindow::RequestActivate() {
  if (window_channel_ == nullptr) {
    return;
  }
  window_channel_->InvokeMethod("reopen", nullptr);
}

void FlutterWindow::RequestDestroy() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  destroy_pending_ = true;
  ::PostMessageW(window, kDestroyWindowMessage, 0, 0);
}

void FlutterWindow::OnDestroy() {
  if (instance_host_window_ != nullptr) {
    ::DestroyWindow(instance_host_window_);
    instance_host_window_ = nullptr;
  }
  // 通道先于引擎销毁，并显式摘掉处理函数：MethodChannel 的析构**不会**注销
  // 注册到 messenger 的回调（句柄归 messenger 所有，见 method_channel.h），
  // 不摘会在退出路径上回调到已析构的窗口。
  if (taskbar_channel_ != nullptr) {
    taskbar_channel_->SetMethodCallHandler(nullptr);
    taskbar_channel_.reset();
  }
  if (window_channel_ != nullptr) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }
  if (GetHandle() != nullptr) {
    ::KillTimer(GetHandle(), kShowFallbackTimerId);
  }
  thumb_bar_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowAfterFirstFrame(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND window = GetHandle();
  if (window == nullptr || flutter_controller_ == nullptr ||
      flutter_controller_->engine() == nullptr) {
    result->Error("window_unavailable", "窗口尚未就绪");
    return;
  }

  if (::IsWindowVisible(window)) {
    // 启动首帧 / 重复 show：窗口已经可见，不能再 cloak 一次。
    SetWindowCloaked(false);
    ::SetForegroundWindow(window);
    result->Success();
    return;
  }

  if (!SetWindowCloaked(true)) {
    // DWM cloak 不可用：退回直接显示，保留原有行为而不是把窗口藏住。
    ::ShowWindow(window, SW_SHOW);
    ::SetForegroundWindow(window);
    result->Success();
    return;
  }

  flutter_controller_->engine()->SetNextFrameCallback(
      [this]() { FinishShowAfterFirstFrame(); });
  // SW_SHOW 保留当前最大化状态；不要用 Win32Window::Show() 的 SW_SHOWNORMAL，
  // 那会把最大化窗口还原成普通尺寸。
  ::ShowWindow(window, SW_SHOW);
  if (::SetTimer(window, kShowFallbackTimerId, kShowFallbackTimeoutMs,
                 nullptr) == 0) {
    // 定时器都建不起来时至少别把窗口留在 cloak 状态。
    FinishShowAfterFirstFrame();
  }
  result->Success();
}

void FlutterWindow::FinishShowAfterFirstFrame() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  ::KillTimer(window, kShowFallbackTimerId);
  // 等待首帧期间用户可能又把它关到托盘：这时只解除 cloak，不能再 show。
  const bool was_visible = ::IsWindowVisible(window) != FALSE;
  SetWindowCloaked(false);
  if (was_visible) {
    ::ShowWindow(window, SW_SHOW);
    ::SetForegroundWindow(window);
  }
}

bool FlutterWindow::SetWindowCloaked(bool cloak) {
  HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }
  BOOL value = cloak ? TRUE : FALSE;
  return SUCCEEDED(::DwmSetWindowAttribute(window, DWMWA_CLOAK, &value,
                                           sizeof(value)));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 任务栏缩略图按钮点击：WM_COMMAND 的低字是按钮 id、高字是 THBN_CLICKED，
  // 命中本工具栏时直接吃掉（其余 WM_COMMAND 照旧交给 Flutter / 基类）。
  if (message == WM_COMMAND && thumb_bar_ != nullptr &&
      thumb_bar_->HandleCommand(wparam)) {
    return 0;
  }

  // 任务栏按钮建好（或重建）后 shell 才认工具栏：MSDN 要求先收到这条注册消息，
  // 此前调用 ThumbBarAddButtons 一律无效（返回 E_INVALIDARG、按钮永不出现）。
  const UINT taskbar_button_created =
      TaskbarThumbBar::TaskbarButtonCreatedMessage();
  if (taskbar_button_created != 0 && message == taskbar_button_created) {
    if (thumb_bar_ != nullptr) {
      thumb_bar_->OnTaskbarButtonCreated();
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  // Explorer 重启：整个任务栏重建，旧工具栏随旧任务栏一起没了，复位门闩等
  // 新任务栏再发 TaskbarButtonCreated（注册消息由 TaskbarThumbBar 提供）。
  const UINT taskbar_created = TaskbarThumbBar::TaskbarCreatedMessage();
  if (taskbar_created != 0 && message == taskbar_created) {
    if (thumb_bar_ != nullptr) {
      thumb_bar_->OnTaskbarRestarted();
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  // 隐藏到托盘再显示：任务栏按钮会重建，工具栏按需重挂（Update 失败回落 Add）。
  if (message == WM_SHOWWINDOW && wparam != 0 && thumb_bar_ != nullptr) {
    thumb_bar_->OnShow();
  }

  // 恢复显示的兜底：引擎极端情况下没出帧也不能让窗口一直 cloak。
  if (message == WM_TIMER && wparam == kShowFallbackTimerId) {
    FinishShowAfterFirstFrame();
    return 0;
  }

  // 挂载失败后的退避重试（只认本工具栏的定时器 id，其余 WM_TIMER 照旧下传）。
  if (message == WM_TIMER && thumb_bar_ != nullptr &&
      thumb_bar_->HandleTimer(wparam)) {
    return 0;
  }

  // 任务栏亮暗切换：按钮图标是原样绘制的，要换一套字形。
  if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE ||
      message == WM_DWMCOLORIZATIONCOLORCHANGED) {
    if (thumb_bar_ != nullptr) {
      thumb_bar_->RefreshThemeIcons();
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // 原生 WM_CLOSE（任务栏「关闭窗口」、外部 CloseMainWindow 等）不经过
  // nativeapi 的 SC_CLOSE 拦截。转发给 Dart 的关闭策略，否则「关闭到
  // 托盘」会被系统直接退出绕过。真正退出时 destroy_pending_ 为真，放行
  // 给默认窗口过程销毁。
  if (message == WM_CLOSE && !destroy_pending_) {
    if (window_channel_ != nullptr) {
      window_channel_->InvokeMethod("closeRequested", nullptr);
      return 0;
    }
  }

  if (message == kDestroyWindowMessage) {
    ::DestroyWindow(hwnd);
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
