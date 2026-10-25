import 'package:flutter_test/flutter_test.dart';

// 主题相关用例合并到一个测试套件：`flutter test` 每个测试文件都要付一次
// engine / kernel 装载开销（~1s，与文件大小无关），小而散的文件会让全量
// 测试的时间几乎都花在装载上。用例本身仍留在各自的 *_cases.dart 里。
import 'app_theme_cases.dart' as app_theme;
import 'm3e_theme_wiring_cases.dart' as m3e_theme_wiring;
import 'predictive_back_page_transitions_cases.dart' as predictive_back;
import 'scheme_builder_cases.dart' as scheme_builder;

void main() {
  group('app theme', app_theme.main);
  group('m3e theme wiring', m3e_theme_wiring.main);
  group('predictive back transitions', predictive_back.main);
  group('scheme builder', scheme_builder.main);
}
