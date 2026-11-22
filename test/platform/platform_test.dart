import 'package:flutter_test/flutter_test.dart';

import 'abi_cases.dart' as platform_abi;
import 'widget_adapter_cases.dart' as platform_widget_adapter;

void main() {
  group('abi', platform_abi.main);
  group('widget adapter', platform_widget_adapter.main);
}
