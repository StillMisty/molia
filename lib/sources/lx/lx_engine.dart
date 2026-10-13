/// LX 音源引擎入口：原生平台使用 QuickJS（flutter_qjs_next），Web 使用占位实现。
library;

export 'lx_engine_stub.dart' if (dart.library.io) 'lx_engine_native.dart'
    show LxEngine;
