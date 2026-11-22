import 'package:flutter_test/flutter_test.dart';

import 'custom_cover_store_cases.dart' as services_custom_cover_store;
import 'local_metadata_service_cases.dart' as services_local_metadata_service;
import 'music_folder_cases.dart' as services_music_folder;
import 'saf_local_library_cases.dart' as services_saf_local_library;
import 'track_local_data_service_cases.dart'
    as services_track_local_data_service;

void main() {
  group('custom cover store', services_custom_cover_store.main);
  group('local metadata service', services_local_metadata_service.main);
  group('music folder', services_music_folder.main);
  group('saf local library', services_saf_local_library.main);
  group('track local data service', services_track_local_data_service.main);
}
