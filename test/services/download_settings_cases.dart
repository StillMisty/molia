import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/download/download_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载设置：默认值、持久化与文件名模板占位符替换。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认值：默认目录 / 默认模板 / 嵌入开启 / 公共目录发布开启', () async {
    final settings = DownloadSettings();
    await settings.init();
    expect(settings.saveDir, '');
    expect(settings.filenameTemplate, kDefaultFilenameTemplate);
    expect(settings.embedTags, isTrue);
    expect(settings.publishToPublicDir, isTrue);
    expect(settings.notifications, isTrue);
  });

  test('持久化：设置后重新加载仍生效', () async {
    final settings = DownloadSettings();
    await settings.init();
    await settings.setSaveDir('/home/user/Music/Molia');
    await settings.setFilenameTemplate('{title} - {artist}');
    await settings.setEmbedTags(false);
    await settings.setPublishToPublicDir(false);
    await settings.setNotifications(false);

    final reloaded = DownloadSettings();
    await reloaded.init();
    expect(reloaded.saveDir, '/home/user/Music/Molia');
    expect(reloaded.filenameTemplate, '{title} - {artist}');
    expect(reloaded.embedTags, isFalse);
    expect(reloaded.publishToPublicDir, isFalse);
    expect(reloaded.notifications, isFalse);
  });

  test('模板替换：多占位符 / 未知占位符原样保留 / 空模板回默认', () async {
    expect(
      DownloadSettings.applyTemplate('{artist} - {title}', const {
        'artist': '歌手',
        'title': '歌名',
        'album': '专辑',
      }),
      '歌手 - 歌名',
    );
    expect(
      DownloadSettings.applyTemplate('{album}/{title}', const {
        'artist': '歌手',
        'title': '歌名',
        'album': '专辑',
      }),
      '专辑/歌名',
    );
    expect(
      DownloadSettings.applyTemplate('{artist} - {unknown}', const {
        'artist': '歌手',
      }),
      '歌手 - {unknown}',
    );

    final settings = DownloadSettings();
    await settings.init();
    await settings.setFilenameTemplate('   ');
    expect(settings.filenameTemplate, kDefaultFilenameTemplate);
  });
}
