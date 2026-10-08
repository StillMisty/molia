import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Linux/Windows 桌面端：sqflite 无原生实现，改用 FFI（Linux 走系统
/// libsqlite3.so；Windows 需要 sqlite3.dll 或 sqlite3_flutter_libs）。
/// 移动端与 macOS 使用原生 sqflite，无需处理。
void initDatabaseFactoryIfNeeded() {
  if (Platform.isLinux || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
