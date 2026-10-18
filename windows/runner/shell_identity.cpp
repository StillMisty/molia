#include "shell_identity.h"

#include <windows.h>

#include <cstring>
#include <cwchar>

namespace {

// AUMID 注册表键：DisplayName 是任务栏/媒体浮层显示的名字，IconUri 是 shell
// 解析这个身份图标时的首选来源（指向 exe 即取 exe 里的 IDI_APP_ICON）。
constexpr const wchar_t kAppUserModelIdKey[] =
    L"Software\\Classes\\AppUserModelId\\top.stillmisty.molia";

// 值相同则不写：避免每次启动都刷新注册表键的时间戳。
void SetValueIfChanged(HKEY key, const wchar_t* name, const wchar_t* value,
                       DWORD type) {
  wchar_t existing[1024] = {};
  DWORD size = sizeof(existing);
  DWORD existing_type = 0;
  const LONG read = RegQueryValueExW(
      key, name, nullptr, &existing_type,
      reinterpret_cast<LPBYTE>(existing), &size);
  if (read == ERROR_SUCCESS && existing_type == type) {
    // RegQueryValueExW 的 size 含结尾 '\0'，按宽字符长度比较。
    const size_t length = size / sizeof(wchar_t);
    const size_t existing_length = length > 0 ? wcsnlen(existing, length) : 0;
    if (existing_length == wcslen(value) &&
        wcsncmp(existing, value, existing_length) == 0) {
      return;
    }
  }
  RegSetValueExW(key, name, 0, type,
                 reinterpret_cast<const BYTE*>(value),
                 static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t)));
}

}  // namespace

void shell_identity::RegisterAppUserModelId(const std::wstring& icon_path) {
  if (icon_path.empty()) {
    return;
  }
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kAppUserModelIdKey, 0, nullptr, 0,
                      KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  SetValueIfChanged(key, L"DisplayName", shell_identity::kAppDisplayName,
                    REG_SZ);
  SetValueIfChanged(key, L"IconUri", icon_path.c_str(), REG_EXPAND_SZ);
  RegCloseKey(key);
}
