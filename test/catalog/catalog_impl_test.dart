import 'package:flutter_test/flutter_test.dart';

import 'catalog_service_cases.dart' as catalog_catalog_service;
import 'local_music_source_cases.dart' as catalog_local_music_source;
import 'manager_catalog_source_cases.dart' as catalog_manager_catalog_source;
import 'search_provider_reroute_cases.dart' as catalog_search_provider_reroute;
import 'search_results_cases.dart' as catalog_search_results;
import 'source_registry_impl_cases.dart' as catalog_source_registry_impl;
import '../catalog_detail_services_cases.dart' as catalog_detail_services;
import 'request_cache_cases.dart' as catalog_request_cache;

void main() {
  group('catalog service', catalog_catalog_service.main);
  group('local music source', catalog_local_music_source.main);
  group('manager catalog source', catalog_manager_catalog_source.main);
  group('search provider reroute', catalog_search_provider_reroute.main);
  group('search results', catalog_search_results.main);
  group('source registry impl', catalog_source_registry_impl.main);
  group('catalog detail services', catalog_detail_services.main);
  group('request cache', catalog_request_cache.main);
}
