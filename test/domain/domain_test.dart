import 'package:flutter_test/flutter_test.dart';

import 'annual_report_cases.dart' as domain_annual_report;
import 'models_cases.dart' as domain_models;
import 'search_assist_cases.dart' as domain_search_assist;

void main() {
  group('annual report', domain_annual_report.main);
  group('models', domain_models.main);
  group('search assist', domain_search_assist.main);
}
