import 'package:flutter_test/flutter_test.dart';

import 'static_settings_attachment_cases.dart'
    as services_static_settings_attachment;

/// 全静态设置服务的接线契约。
///
/// 单独成文件：会构造真实组合根并触发凭据存储的异步初始化，与其它服务
/// 用例同进程时泄漏的异步异常会被算到本用例头上。
void main() {
  group('static settings attachment', services_static_settings_attachment.main);
}
