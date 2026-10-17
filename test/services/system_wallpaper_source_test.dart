import 'package:flutter/foundation.dart' show Brightness, TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/system_wallpaper_service.dart';

/// 系统壁纸探测的纯逻辑测试：gsettings / environment / 存在性 / 平台全部注入，
/// 不碰真实桌面会话。
void main() {
  /// 全注入探测：gsettings 值表（未配置的键 = 非零退出 → null）、
  /// 存在的文件集合、平台与 environment 可直接覆盖。
  SystemWallpaperSource source({
    TargetPlatform platform = TargetPlatform.linux,
    Map<String, String> gsettings = const <String, String>{},
    Set<String> existing = const <String>{},
    Map<String, String> environment = const <String, String>{},
    List<String>? requested,
  }) =>
      SystemWallpaperSource(
        platform: platform,
        environment: environment,
        readGsettings: (key) async {
          requested?.add(key);
          return gsettings[key];
        },
        fileExists: (path) async => existing.contains(path),
      );

  group('SystemWallpaperSource.parseGsettingsValue', () {
    test('去 GVariant 引号与类型注解，percent-escape 解码为路径', () {
      expect(
        SystemWallpaperSource.parseGsettingsValue(
          "'file:///home/u/Pictures/wall.jpg'\n",
        ),
        '/home/u/Pictures/wall.jpg',
      );
      expect(
        SystemWallpaperSource.parseGsettingsValue(
          "@s 'file:///home/u/wall%20paper.jpg'",
        ),
        '/home/u/wall paper.jpg',
      );
    });

    test('空串 / 非 file scheme / 类型注解列表一律 null', () {
      expect(SystemWallpaperSource.parseGsettingsValue(''), isNull);
      expect(SystemWallpaperSource.parseGsettingsValue('  \n'), isNull);
      expect(SystemWallpaperSource.parseGsettingsValue("''"), isNull);
      expect(
        SystemWallpaperSource.parseGsettingsValue(
          "'https://example.com/w.jpg'",
        ),
        isNull,
      );
      expect(SystemWallpaperSource.parseGsettingsValue('@as []'), isNull);
      expect(SystemWallpaperSource.parseGsettingsValue('relative/path.jpg'),
          isNull);
    });
  });

  group('Linux（GNOME gsettings）', () {
    test('浅色：引号 + percent-escape 解析后校验存在性', () async {
      final probe = source(
        gsettings: {'picture-uri': "'file:///home/u/wall%20paper.jpg'\n"},
        existing: {'/home/u/wall paper.jpg'},
      );
      expect(
        await probe.resolvePath(Brightness.light),
        '/home/u/wall paper.jpg',
      );
    });

    test('浅色只读 picture-uri 键', () async {
      final requested = <String>[];
      final probe = source(
        gsettings: {'picture-uri': "'file:///home/u/light.jpg'"},
        existing: {'/home/u/light.jpg'},
        requested: requested,
      );
      expect(await probe.resolvePath(Brightness.light), '/home/u/light.jpg');
      expect(requested, ['picture-uri']);
    });

    test('深色优先 picture-uri-dark，且不再读浅色键', () async {
      final requested = <String>[];
      final probe = source(
        gsettings: {
          'picture-uri-dark': "'file:///home/u/dark.jpg'",
          'picture-uri': "'file:///home/u/light.jpg'",
        },
        existing: {'/home/u/dark.jpg'},
        requested: requested,
      );
      expect(await probe.resolvePath(Brightness.dark), '/home/u/dark.jpg');
      expect(requested, ['picture-uri-dark']);
    });

    test('picture-uri-dark 键缺失（非零退出 → null）回落浅色', () async {
      final requested = <String>[];
      final probe = source(
        gsettings: {'picture-uri': "'file:///home/u/light.jpg'"},
        existing: {'/home/u/light.jpg'},
        requested: requested,
      );
      expect(await probe.resolvePath(Brightness.dark), '/home/u/light.jpg');
      expect(requested, ['picture-uri-dark', 'picture-uri']);
    });

    test('深色键值的文件不存在：回落浅色', () async {
      final probe = source(
        gsettings: {
          'picture-uri-dark': "'file:///home/u/gone.jpg'",
          'picture-uri': "'file:///home/u/light.jpg'",
        },
        existing: {'/home/u/light.jpg'},
      );
      expect(await probe.resolvePath(Brightness.dark), '/home/u/light.jpg');
    });

    test('值合法但文件缺失 / 值非法 / 非零退出 → null', () async {
      expect(
        await source(
          gsettings: {'picture-uri': "'file:///home/u/gone.jpg'"},
        ).resolvePath(Brightness.light),
        isNull,
        reason: '存在性校验失败',
      );
      expect(
        await source(gsettings: {'picture-uri': "''"})
            .resolvePath(Brightness.light),
        isNull,
        reason: '键未设置（空串）',
      );
      expect(
        await source(gsettings: {'picture-uri': "'https://example.com/a.jpg'"})
            .resolvePath(Brightness.light),
        isNull,
        reason: '非 file scheme',
      );
      expect(
        await source().resolvePath(Brightness.light),
        isNull,
        reason: 'gsettings 非零退出（reader 返回 null）',
      );
    });

    test('gsettings 读取抛错（进程缺失 / 权限）：null 不抛', () async {
      final probe = SystemWallpaperSource(
        platform: TargetPlatform.linux,
        environment: const <String, String>{},
        readGsettings: (key) async => throw StateError('gsettings missing'),
        fileExists: (path) async => true,
      );
      expect(await probe.resolvePath(Brightness.light), isNull);
      expect(await probe.resolvePath(Brightness.dark), isNull);
    });
  });

  group('Windows（TranscodedWallpaper 裁切副本）', () {
    const appData = r'C:\Users\me\AppData\Roaming';
    const wallpaper =
        r'C:\Users\me\AppData\Roaming\Microsoft\Windows\Themes\TranscodedWallpaper';

    test('APPDATA 拼接路径，浅 / 深同一文件', () async {
      final probe = source(
        platform: TargetPlatform.windows,
        environment: {'APPDATA': appData},
        existing: {wallpaper},
      );
      expect(await probe.resolvePath(Brightness.light), wallpaper);
      expect(await probe.resolvePath(Brightness.dark), wallpaper);
    });

    test('APPDATA 缺失 / 文件缺失 → null', () async {
      expect(
        await source(platform: TargetPlatform.windows, existing: {wallpaper})
            .resolvePath(Brightness.light),
        isNull,
      );
      expect(
        await source(
          platform: TargetPlatform.windows,
          environment: {'APPDATA': appData},
        ).resolvePath(Brightness.light),
        isNull,
      );
      expect(
        await source(
          platform: TargetPlatform.windows,
          environment: {'APPDATA': ''},
          existing: {wallpaper},
        ).resolvePath(Brightness.light),
        isNull,
      );
    });
  });

  test('非桌面平台：null，且不读 gsettings / 不查文件', () async {
    var reads = 0;
    var checks = 0;
    for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
      final probe = SystemWallpaperSource(
        platform: platform,
        environment: const {'APPDATA': r'C:\AppData'},
        readGsettings: (key) async {
          reads++;
          return "'file:///x.jpg'";
        },
        fileExists: (path) async {
          checks++;
          return true;
        },
      );
      expect(await probe.resolvePath(Brightness.light), isNull);
      expect(await probe.resolvePath(Brightness.dark), isNull);
    }
    expect(reads, 0);
    expect(checks, 0);
  });
}
