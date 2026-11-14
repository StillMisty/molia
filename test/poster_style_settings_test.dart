import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/services/poster/poster_style_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 海报样式三键：登记默认值 / 本地写入 / 远端应用后的重载。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late SettingsRegistry registry;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    registry = SettingsRegistry(
      keys: [kPosterColorSourceKey, kPosterSeedColor, kPosterFontFamily],
      preferences: prefs,
    );
    PosterStyleSettings.attachSettings(registry);
    await PosterStyleSettings.ensureLoaded();
  });

  test('缺键回默认：跟随应用主题 / 默认种子色 / 跟随应用字体', () {
    expect(PosterStyleSettings.colorSource, PosterColorSource.appTheme);
    expect(PosterStyleSettings.seed, kPosterSeedColor.defaultValue);
    expect(PosterStyleSettings.fontFamily, isNull);
  });

  test('默认值与登记键默认值同源', () {
    expect(
      PosterStyleSettings.parseSource(kPosterColorSourceKey.defaultValue),
      PosterStyleSettings.defaultSource,
    );
    expect(PosterStyleSettings.defaultSeed, kPosterSeedColor.defaultValue);
    expect(kPosterFontFamily.defaultValue, isNull);
  });

  test('本地写入落到登记键，并原样读回', () async {
    await PosterStyleSettings.setCustomColor(0xFF112233);
    await PosterStyleSettings.setFontFamily('Inter');

    expect(prefs.getString('poster_color_source'), 'custom');
    expect(prefs.getInt('poster_seed_color'), 0xFF112233);
    expect(prefs.getString('poster_font_family'), 'Inter');
    expect(PosterStyleSettings.colorSource, PosterColorSource.custom);
    expect(PosterStyleSettings.seed, 0xFF112233);
    expect(PosterStyleSettings.fontFamily, 'Inter');
  });

  test('同值写入不重复落盘：避免额外同步记录', () async {
    await PosterStyleSettings.setColorSource(PosterColorSource.artwork);
    expect(prefs.getString('poster_color_source'), 'artwork');

    final before = prefs.getString('poster_color_source');
    await PosterStyleSettings.setColorSource(PosterColorSource.artwork);
    expect(prefs.getString('poster_color_source'), before);
  });

  test('远端应用后 reload 重读三键', () async {
    await registry.applyRemote(kPosterColorSourceKey, 'artwork');
    await registry.applyRemote(kPosterSeedColor, 0xFF445566);
    await registry.applyRemote(kPosterFontFamily, '');
    await PosterStyleSettings.reload();

    expect(PosterStyleSettings.colorSource, PosterColorSource.artwork);
    expect(PosterStyleSettings.seed, 0xFF445566);
    expect(PosterStyleSettings.fontFamily, '');
  });

  test('未知取色来源回退跟随应用主题', () async {
    await registry.applyRemote(kPosterColorSourceKey, 'future-source');
    await PosterStyleSettings.reload();

    expect(PosterStyleSettings.colorSource, PosterColorSource.appTheme);
  });
}
