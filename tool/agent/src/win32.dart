/// Windows 采样用的最小 Win32 / psapi 绑定（dart:ffi）。
///
/// 为什么不用 PowerShell：`.ps1` 是 Windows 侧唯一跑得通的实现，但它把同一套
/// 采样逻辑与 Linux 的 cli.dart 分成两套；这里只绑定真正需要系统调用的几个
/// 函数（找窗口、前景、滚轮、按键、进程内存），其余编排留在 Dart 里。
///
/// 只在 `Platform.isWindows` 下加载；其它平台调用会抛 UnsupportedError。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

class Rect {
  const Rect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  (int, int) get center => ((left + right) ~/ 2, (top + bottom) ~/ 2);
}

class ProcessMemory {
  const ProcessMemory({
    required this.workingSet,
    required this.privateBytes,
    required this.commit,
  });

  final int workingSet;
  final int privateBytes;
  final int commit;

  double get workingSetMb => workingSet / (1024 * 1024);
  double get privateMb => privateBytes / (1024 * 1024);
  double get commitMb => commit / (1024 * 1024);
}

class Win32 {
  Win32._() {
    _disableDpiVirtualization();
  }

  static Win32? _instance;

  static Win32 get instance {
    if (!Platform.isWindows) {
      throw UnsupportedError('Win32 采样只在 Windows 上可用');
    }
    return _instance ??= Win32._();
  }

  final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  final DynamicLibrary _psapi = DynamicLibrary.open('psapi.dll');
  final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  late final int Function() _setProcessDpiAware = _user32
      .lookupFunction<Int32 Function(), int Function()>('SetProcessDPIAware');
  late final int Function(int) _setForegroundWindow = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow',
      );
  late final int Function(int) _isWindowVisible = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible',
      );
  late final int Function(int, Pointer<Uint8>) _getWindowRect = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('GetWindowRect');
  late final int Function(int, int) _setCursorPos = _user32
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'SetCursorPos',
      );
  late final void Function(int, int, int, int, int) _mouseEvent = _user32
      .lookupFunction<
        Void Function(Uint32, Uint32, Uint32, Int32, IntPtr),
        void Function(int, int, int, int, int)
      >('mouse_event');
  late final void Function(int, int, int, int) _keybdEvent = _user32
      .lookupFunction<
        Void Function(Uint8, Uint8, Uint32, IntPtr),
        void Function(int, int, int, int)
      >('keybd_event');
  late final int Function(int, int, int, int) _postMessage = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)
      >('PostMessageW');
  late final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId =
      _user32.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  late final int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, int)
  _enumWindows = _user32
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, IntPtr),
        int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, int)
      >('EnumWindows');

  late final int Function(int, int, int) _openProcess = _kernel32
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
  late final int Function(int) _closeHandle = _kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final int Function(int, int) _localAlloc = _kernel32
      .lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>(
        'LocalAlloc',
      );
  late final int Function(int) _localFree = _kernel32
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('LocalFree');
  late final int Function(int, Pointer<Uint8>, int) _getProcessMemoryInfo =
      _psapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)
      >('GetProcessMemoryInfo');

  void _disableDpiVirtualization() => _setProcessDpiAware();

  /// 用 LocalAlloc 而不是 package:ffi 的 calloc：工具链不引第三方包。
  Pointer<Uint8> _alloc(int bytes) {
    final address = _localAlloc(
      0x0040,
      bytes,
    ); // LPTR = LMEM_FIXED | LMEM_ZEROINIT
    if (address == 0) throw StateError('LocalAlloc 失败（$bytes 字节）');
    return Pointer<Uint8>.fromAddress(address);
  }

  void _free(Pointer<Uint8> pointer) => _localFree(pointer.address);

  /// 找属于 [pid] 的第一个可见顶层窗口。
  int? findMainWindow(int pid) {
    int? found;
    final callback = NativeCallable<_EnumWindowsProcNative>.isolateLocal((
      int hwnd,
      int _,
    ) {
      if (found != null) return 1;
      if (_isWindowVisible(hwnd) == 0) return 1;
      final owner = _alloc(4).cast<Uint32>();
      try {
        _getWindowThreadProcessId(hwnd, owner);
        if (owner.value == pid) {
          found = hwnd;
          return 0;
        }
      } finally {
        _free(owner.cast<Uint8>());
      }
      return 1;
    }, exceptionalReturn: -1);
    try {
      _enumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    return found;
  }

  Rect windowRect(int hwnd) {
    final buffer = _alloc(16);
    try {
      if (_getWindowRect(hwnd, buffer) == 0) {
        throw StateError('GetWindowRect 失败');
      }
      final data = buffer.asTypedList(16).buffer.asByteData();
      return Rect(
        data.getInt32(0, Endian.little),
        data.getInt32(4, Endian.little),
        data.getInt32(8, Endian.little),
        data.getInt32(12, Endian.little),
      );
    } finally {
      _free(buffer);
    }
  }

  void activate(int hwnd) => _setForegroundWindow(hwnd);

  void moveCursor(int x, int y) => _setCursorPos(x, y);

  /// 滚轮：`mouse_event(MOUSEEVENTF_WHEEL, 0, 0, delta)`。
  void wheel(int delta) => _mouseEvent(0x0800, 0, 0, delta, 0);

  /// 媒体键：VK_MEDIA_PLAY_PAUSE = 0xB3，按下 + 抬起。
  void mediaPlayPause() {
    _keybdEvent(0xB3, 0, 0, 0);
    _keybdEvent(0xB3, 0, 2, 0);
  }

  /// 关闭到托盘：发 WM_SYSCOMMAND + SC_CLOSE（等价点顶栏关闭键）。
  /// 不能用 WM_CLOSE——nativeapi 会当成不可取消的系统关闭直接销毁窗口。
  void closeToTray(int hwnd) => _postMessage(hwnd, 0x0112, 0xF060, 0);

  /// 进程内存：工作集 / 私有字节 / 提交。
  ProcessMemory processMemory(int pid) {
    const processQueryInformation = 0x0400;
    const processVmRead = 0x0010;
    const structSize = 80;
    final handle = _openProcess(
      processQueryInformation | processVmRead,
      0,
      pid,
    );
    if (handle == 0) throw StateError('OpenProcess 失败（pid=$pid）');
    final buffer = _alloc(structSize);
    try {
      final bytes = buffer.asTypedList(structSize).buffer.asByteData();
      bytes.setUint32(0, structSize, Endian.little);
      if (_getProcessMemoryInfo(handle, buffer, structSize) == 0) {
        throw StateError('GetProcessMemoryInfo 失败（pid=$pid）');
      }
      // PROCESS_MEMORY_COUNTERS_EX（x64）：8 字节头 + 9 个 SIZE_T。
      int field(int index) => bytes.getUint64(8 + index * 8, Endian.little);
      return ProcessMemory(
        workingSet: field(1),
        privateBytes: field(8),
        commit: field(6),
      );
    } finally {
      _free(buffer);
      _closeHandle(handle);
    }
  }
}
