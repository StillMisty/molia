import 'package:flutter_test/flutter_test.dart';

import 'album_service_cases.dart' as album_service;
import 'artist_service_cases.dart' as artist_service;

void main() {
  group('album service', album_service.main);
  group('artist service', artist_service.main);
}
