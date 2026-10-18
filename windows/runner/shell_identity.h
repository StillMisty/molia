#ifndef RUNNER_SHELL_IDENTITY_H_
#define RUNNER_SHELL_IDENTITY_H_

#include <string>

// 应用在 Windows shell 里的身份（AppUserModelID + 显示名 + 图标来源）。
//
// 为什么必须显式注册：任务栏按钮的右键菜单与悬浮预览头部，图标和名字都不是
// 「现取 exe 资源」——shell 按 AUMID 解析一次后缓存下来。进程只调
// SetCurrentProcessExplicitAppUserModelID 而不落地身份注册时，shell 会退回
// 上一次解析的结果（换图标前的旧构建留下的是 Flutter 默认图，
// 见 docs/pitfalls.md「Windows 任务栏图标」条）。
namespace shell_identity {

// 与 windows/installer/molia.iss 的 AppUserModelID、main.cpp 的
// SetCurrentProcessExplicitAppUserModelID 必须一致。
inline constexpr wchar_t kAppUserModelId[] = L"top.stillmisty.molia";
inline constexpr wchar_t kAppDisplayName[] = L"Molia";

// 写 HKCU\Software\Classes\AppUserModelId\<kAppUserModelId>：DisplayName +
// IconUri（REG_EXPAND_SZ，指向当前 exe）。
//
// 值未变化时不写（注册表写入会刷新键时间戳，每次启动都写没有意义）；失败静默
// 返回——缺这个键只影响图标解析的兜底路径，不该影响启动。
void RegisterAppUserModelId(const std::wstring& icon_path);

}  // namespace shell_identity

#endif  // RUNNER_SHELL_IDENTITY_H_
