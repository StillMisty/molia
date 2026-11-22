import 'package:flutter_test/flutter_test.dart';

import 'lan_discovery_protocol_cases.dart' as lan_discovery_protocol;
import 'lan_pairing_packet_cases.dart' as lan_pairing_packet;
import 'lan_pairing_service_cases.dart' as lan_pairing_service;
import 'lan_pairing_transport_cases.dart' as lan_pairing_transport;
import 'lan_sync_transport_cases.dart' as lan_sync_transport;
import 'pairing_crypto_cases.dart' as pairing_crypto;
import 'pairing_http_cases.dart' as pairing_http;
import 'webdav_sync_cases.dart' as webdav_sync;

void main() {
  group('lan discovery protocol', lan_discovery_protocol.main);
  group('lan pairing packet', lan_pairing_packet.main);
  group('lan pairing service', lan_pairing_service.main);
  group('lan pairing transport', lan_pairing_transport.main);
  group('lan sync transport', lan_sync_transport.main);
  group('pairing crypto', pairing_crypto.main);
  group('pairing http', pairing_http.main);
  group('webdav sync', webdav_sync.main);
}
