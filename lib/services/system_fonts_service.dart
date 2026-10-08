/// 设备已安装字体枚举入口：原生实现走 [system_fonts_service_io.dart]
/// （Android 解析系统字体配置、iOS 走通道、Linux 调 fc-list），
/// Web 等平台使用空实现 [system_fonts_service_stub.dart]。
library;

export 'system_fonts_service_stub.dart'
    if (dart.library.io) 'system_fonts_service_io.dart';
