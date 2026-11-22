import 'package:flutter_test/flutter_test.dart';

import 'sync_backup_cases.dart' as sync_backup;
import 'sync_codec_isolate_cases.dart' as sync_codec_isolate;
import 'sync_crypto_cases.dart' as sync_crypto;
import 'sync_journal_model_cases.dart' as sync_journal_model;
import 'sync_labels_cases.dart' as sync_labels;
import 'sync_peer_candidate_cases.dart' as sync_peer_candidate;
import 'sync_pipeline_reset_cases.dart' as sync_pipeline_reset;
import 'sync_pull_plan_cases.dart' as sync_pull_plan;
import 'sync_transport_runtime_cases.dart' as sync_transport_runtime;
import 'sync_webdav_e2e_cases.dart' as sync_webdav_e2e;

void main() {
  group('sync backup', sync_backup.main);
  group('sync codec isolate', sync_codec_isolate.main);
  group('sync crypto', sync_crypto.main);
  group('sync journal model', sync_journal_model.main);
  group('sync labels', sync_labels.main);
  group('sync peer candidate', sync_peer_candidate.main);
  group('sync pipeline reset', sync_pipeline_reset.main);
  group('sync pull plan', sync_pull_plan.main);
  group('sync transport runtime', sync_transport_runtime.main);
  group('sync webdav e2e', sync_webdav_e2e.main);
}
