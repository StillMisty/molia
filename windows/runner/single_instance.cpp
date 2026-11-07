#include "single_instance.h"

#include <sddl.h>

#include <iterator>
#include <vector>

namespace single_instance {
namespace {

// 主实例的 mutex 句柄：不显式关闭，随进程退出由内核释放。
HANDLE g_mutex = nullptr;

std::wstring CurrentUserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return L"unknown";
  }

  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  if (size == 0) {
    CloseHandle(token);
    return L"unknown";
  }

  std::vector<BYTE> buffer(size);
  std::wstring result = L"unknown";
  if (GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    auto* user = reinterpret_cast<TOKEN_USER*>(buffer.data());
    LPWSTR sid_string = nullptr;
    if (ConvertSidToStringSidW(user->User.Sid, &sid_string)) {
      result = sid_string;
      LocalFree(sid_string);
    }
  }
  CloseHandle(token);
  return result;
}

const std::wstring& SidSuffix() {
  static const std::wstring sid = CurrentUserSid();
  return sid;
}

const std::wstring& MutexName() {
  static const std::wstring name =
      L"Local\\Molia.SingleInstance." + SidSuffix();
  return name;
}

bool IsDisabled() {
  wchar_t value[8] = {};
  const DWORD length = GetEnvironmentVariableW(
      L"MOLIA_SINGLE_INSTANCE_DISABLED", value, std::size(value));
  return length == 1 && value[0] == L'1';
}

}  // namespace

const std::wstring& HostWindowClassName() {
  static const std::wstring name =
      L"Molia.SingleInstance.Host." + SidSuffix();
  return name;
}

const std::wstring& ActivateMessageName() {
  static const std::wstring name =
      L"Molia.SingleInstance.Activate." + SidSuffix();
  return name;
}

UINT ActivateMessage() {
  static const UINT message =
      RegisterWindowMessageW(ActivateMessageName().c_str());
  return message;
}

bool AcquireOrActivate() {
  if (IsDisabled()) {
    return true;
  }

  HANDLE mutex = CreateMutexW(nullptr, FALSE, MutexName().c_str());
  if (mutex == nullptr) {
    // 内核对象不可用（受限环境）：让 Dart 文件锁兜底，不阻断启动。
    return true;
  }

  if (GetLastError() != ERROR_ALREADY_EXISTS) {
    g_mutex = mutex;
    return true;
  }
  CloseHandle(mutex);

  // 主实例已经建好隐藏宿主窗口：把前台权限交给它，再投递激活消息。
  // 如果它还在启动（宿主窗口尚未创建），直接退出即可——首帧回调自己会显示。
  HWND host = FindWindowW(HostWindowClassName().c_str(), nullptr);
  if (host == nullptr) {
    return false;
  }

  DWORD pid = 0;
  GetWindowThreadProcessId(host, &pid);
  if (pid != 0) {
    AllowSetForegroundWindow(pid);
  }

  const UINT message = ActivateMessage();
  if (message != 0) {
    PostMessageW(host, message, 0, 0);
  }
  return false;
}

}  // namespace single_instance
