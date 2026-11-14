/// 听歌同步栈：偏好 / 发件箱 / 协议适配器 / 观察者服务。
///
/// 凭证键走设置注册表（凭证类别），设备本地开关留在
/// [ScrobblePreferences]；服务在首帧后 `init()`，在此之前完全惰性。
library;

import 'package:url_launcher/url_launcher.dart';

import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_module.dart';
import '../../data/settings/settings_registry.dart';
import '../../domain/models/scrobble.dart';
import '../../services/scrobble/listenbrainz_sink.dart';
import '../../services/scrobble/scrobble_outbox.dart';
import '../../services/scrobble/scrobble_preferences.dart';
import '../../services/scrobble/scrobble_service.dart';

typedef ScrobbleStack = ({ScrobbleService service});

ScrobbleStack buildScrobbleStack({required SettingsRegistry settings}) {
  late final ScrobbleService service;
  // 远端凭证应用后重读；重载钩子必须先于服务创建绑定。
  final scope = settings.mount(
    SettingsModule(
      keys: [kListenBrainzToken],
      reload: () => service.reloadFromPreferences(),
    ),
  );
  final preferences = ScrobblePreferences(settings: scope);
  final outbox = ScrobbleOutbox();
  final listenBrainz = ListenBrainzSink(
    token: () => service.credentialFor(ScrobbleTarget.listenBrainz),
  );
  service = ScrobbleService(
    preferences: preferences,
    outbox: outbox,
    listenBrainzSink: listenBrainz,
    openBrowser: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
  );
  return (service: service);
}
