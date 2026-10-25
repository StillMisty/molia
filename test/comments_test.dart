import 'package:flutter_test/flutter_test.dart';

import 'comments_provider_cases.dart' as comments_provider;
import 'comments_service_cases.dart' as comments_service;

void main() {
  group('comments provider', comments_provider.main);
  group('comments service', comments_service.main);
}
