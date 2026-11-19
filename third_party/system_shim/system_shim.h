// 桌面系统调用的 vendored 声明（ADR-0038）。
//
// 只声明 libc / allocator 的真实符号，供 `dart run tool/ffigen_system.dart`
// 生成 `lib/platform/desktop/system_ffi.g.dart`。这里带条件编译宏会被 FFIgen
// 的平台探测绕过，因此不引入任何头文件，只保留跨平台的等价签名：
//
// - `kill` / errno：POSIX（Linux `__errno_location`、macOS `__error`）；
// - `malloc_trim`：glibc（musl 没有该符号，调用方保守跳过）；
// - `malloc_zone_pressure_relief`：macOS。
//
// Windows 的 Win32 绑定不走这里，直接复用 `package:win32` 的上游生成物。

#ifndef MOLIA_SYSTEM_SHIM_H_
#define MOLIA_SYSTEM_SHIM_H_

// 不包含 <stddef.h>：FFIgen 的 libclang 在部分环境找不到编译器内置头目录，
// 而 `size_t` 只需要 ABI 宽度。clang 预定义的 `__SIZE_TYPE__` 在
// Linux / macOS（LP64）与 Windows（LLP64）上都是正确的无符号字长。
typedef __SIZE_TYPE__ size_t;

int kill(int pid, int sig);

int* __errno_location(void);

int* __error(void);

int malloc_trim(size_t pad);

size_t malloc_zone_pressure_relief(void* zone, size_t goal);

#endif  // MOLIA_SYSTEM_SHIM_H_
