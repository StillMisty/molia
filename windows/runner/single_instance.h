#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// Windows 原生单实例快速路径。
//
// 命名 mutex 由内核在进程退出时自动释放，不存在锁文件残留；第二实例在
// Flutter 引擎创建前退出，并通过隐藏宿主窗口的注册消息请主实例恢复窗口。
// 名称带当前用户 SID：同一会话里用 RunAs 启动另一个用户时不能互相误认。
// Dart 侧的文件锁仍是跨会话（同一用户两份桌面会话）的最终仲裁。
namespace single_instance {

// 返回 false 表示已有实例在运行（已尝试通知它），调用方应立即退出。
// mutex 创建失败时返回 true：单实例不能成为启动的前置条件。
bool AcquireOrActivate();

// 主实例的隐藏宿主窗口类名 / 激活消息名（均带用户 SID）。
const std::wstring& HostWindowClassName();
const std::wstring& ActivateMessageName();

// RegisterWindowMessageW 的结果；0 表示注册失败。
UINT ActivateMessage();

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
