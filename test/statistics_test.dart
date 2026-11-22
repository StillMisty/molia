import 'package:flutter_test/flutter_test.dart';

import 'annual_report_repository_cases.dart' as annual_report_repository;
import 'play_statistics_formula_cases.dart' as play_statistics_formula;
import 'play_statistics_repository_cases.dart' as play_statistics_repository;
import 'statistics_sync_store_cases.dart' as statistics_sync_store;
import 'services/statistics_services_cases.dart'
    as services_statistics_services;

void main() {
  group('annual report repository', annual_report_repository.main);
  group('play statistics formula', play_statistics_formula.main);
  group('play statistics repository', play_statistics_repository.main);
  group('statistics sync store', statistics_sync_store.main);
  group('statistics service', services_statistics_services.main);
}
