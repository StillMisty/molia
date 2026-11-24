import 'package:flutter_test/flutter_test.dart';

import 'download_file_layout_cases.dart' as services_download_file_layout;
import 'download_manager_state_cases.dart' as services_download_manager_state;
import 'download_notification_presenter_cases.dart'
    as services_download_notification_presenter;
import 'download_record_assembler_cases.dart'
    as services_download_record_assembler;
import 'download_records_cases.dart' as services_download_records;
import 'download_requests_cases.dart' as services_download_requests;
import 'download_task_artifacts_cases.dart' as services_download_task_artifacts;
import 'audio_cache_store_cases.dart' as services_audio_cache_store;
import 'download_services_cases.dart' as services_download_services;
import 'download_service_cases.dart' as services_download_service;

void main() {
  group('download file layout', services_download_file_layout.main);
  group(
    'download notification presenter',
    services_download_notification_presenter.main,
  );
  group('download record assembler', services_download_record_assembler.main);
  group('download manager state', services_download_manager_state.main);
  group('download records', services_download_records.main);
  group('download requests', services_download_requests.main);
  group('download task artifacts', services_download_task_artifacts.main);
  group('audio cache store', services_audio_cache_store.main);
  group('download services', services_download_services.main);
  group('download service', services_download_service.main);
}
