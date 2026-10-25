import 'package:flutter_test/flutter_test.dart';

import 'app_release_cases.dart' as app_release;
import 'update_downloader_cases.dart' as update_downloader;
import 'update_manifest_client_cases.dart' as update_manifest_client;
import 'update_provider_cases.dart' as update_provider;
import 'update_service_cases.dart' as update_service;

void main() {
  group('app release', app_release.main);
  group('update downloader', update_downloader.main);
  group('update manifest client', update_manifest_client.main);
  group('update provider', update_provider.main);
  group('update service', update_service.main);
}
