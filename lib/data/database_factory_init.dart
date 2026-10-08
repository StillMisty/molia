/// 桌面端数据库工厂初始化（Linux/Windows 使用 sqflite FFI；其余平台为空操作）。
library;

export 'database_factory_init_stub.dart'
    if (dart.library.io) 'database_factory_init_io.dart';
