import 'package:flutter_test/flutter_test.dart';

import 'artwork/artwork_cache_cases.dart' as services_artwork_artwork_cache;
import 'artwork_palette_seed_store_cases.dart'
    as services_artwork_palette_seed_store;
import 'artwork_palette_service_cases.dart' as services_artwork_palette_service;

void main() {
  group('artwork cache', services_artwork_artwork_cache.main);
  group('artwork palette seed store', services_artwork_palette_seed_store.main);
  group('artwork palette service', services_artwork_palette_service.main);
}
