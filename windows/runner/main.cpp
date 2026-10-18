#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <iterator>

#include "flutter_window.h"
#include "shell_identity.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Windows 系统媒体浮层（SMTC）按 AppUserModelID 归档应用。必须在创建任何
  // 窗口 / 初始化 SMTC 之前设置，且与安装器快捷方式的 AppUserModelID 一致；
  // 否则媒体浮层显示为 "Unknown Application"，通知归属也会错乱。
  ::SetCurrentProcessExplicitAppUserModelID(shell_identity::kAppUserModelId);

  // 把身份落到注册表（DisplayName + IconUri = 本 exe）：任务栏按钮的右键菜单
  // 与悬浮预览头部按这个身份解析图标 / 名字，只设 AUMID 不注册时会退回 shell
  // 缓存的旧图（见 shell_identity.h 与 docs/pitfalls.md）。
  wchar_t executable_path[1024] = {};
  const DWORD executable_path_length =
      ::GetModuleFileNameW(nullptr, executable_path,
                           static_cast<DWORD>(std::size(executable_path)));
  if (executable_path_length > 0 &&
      executable_path_length < std::size(executable_path)) {
    shell_identity::RegisterAppUserModelId(executable_path);
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"molia", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
