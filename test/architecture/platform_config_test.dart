import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 平台媒体配置契约（issue #64）。
///
/// 平台媒体要求分散在 manifest、两个 Apple property list、两套 macOS
/// entitlement、Windows runner + 安装器、Linux 桌面入口 + CMake、Dart
/// 媒体会话常量与桌面音频初始化里。这里只断言**跨文件关系与必需事实**：
/// 身份字符串一致、必需声明存在、禁用声明缺席。不猜格式、不解析 XML 库、
/// 不启动进程、不 import 平台代码。
///
/// 每条断言的 reason 都指向 `docs/platform_media_checklist.md` 的对应小节；
/// 需要人工观察的部分（合并后的 manifest、真实媒体浮层）留在 checklist。
void main() {
  test('平台媒体身份与必需/禁用声明一致', () {
    _expectAndroidContract();
    _expectAppleContract();
    _expectWindowsContract();
    _expectLinuxContract();
    _expectDesktopBackendIdentity();
  });
}

// ---------------------------------------------------------------------------
// Android
// ---------------------------------------------------------------------------

const String _androidChecklist = 'docs/platform_media_checklist.md「Android」';

void _expectAndroidContract() {
  const path = 'android/app/src/main/AndroidManifest.xml';
  final manifest = _read(path, _androidChecklist);
  expect(
    manifest,
    contains('<manifest'),
    reason: '$_androidChecklist：$path 不是 Android manifest。',
  );
  expect(
    manifest,
    contains('<application'),
    reason: '$_androidChecklist：$path 缺少 <application>，扫描锚点失效。',
  );

  final permissions = _androidPermissions(manifest);
  expect(
    permissions,
    isNotEmpty,
    reason:
        '$_androidChecklist：$path 没解析到任何 <uses-permission>；'
        '改名或改写声明后守卫会静默失效。',
  );
  const required = <String>{
    'android.permission.INTERNET',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
  };
  final missing = required.difference(permissions);
  expect(
    missing,
    isEmpty,
    reason:
        '$_androidChecklist：$path 缺少后台播放必需权限：$missing。'
        '媒体通知 / 锁屏控制 / 锁屏后继续播放依赖这些声明；'
        '修复见 checklist「Required declarations」。',
  );

  // 应用 manifest 里声明的每种前台服务类型都必须有匹配的 *类型权限*。
  // 媒体播放服务本身来自插件合并，应用 manifest 里只有 dataSync 下载服务。
  final fgsTypes = _androidForegroundServiceTypes(manifest);
  expect(
    fgsTypes,
    isNotEmpty,
    reason:
        '$_androidChecklist：$path 没有任何 android:foregroundServiceType；'
        '下载服务或声明写法变了，类型权限检查会变成空转。',
  );
  final missingTypePermissions = <String>[
    for (final type in fgsTypes)
      if (!permissions.contains(
        'android.permission.FOREGROUND_SERVICE_${_upperSnake(type)}',
      ))
        '$type -> FOREGROUND_SERVICE_${_upperSnake(type)}',
  ];
  expect(
    missingTypePermissions,
    isEmpty,
    reason:
        '$_androidChecklist：$path 声明了前台服务类型但缺少匹配权限：'
        '$missingTypePermissions。Android 14+ 会拒绝启动该服务。',
  );

  const forbidden = <String>{
    'android.permission.RECORD_AUDIO',
    'android.permission.CAPTURE_AUDIO_OUTPUT',
    'android.permission.CAPTURE_AUDIO_HOTWORD',
  };
  final unexpected = forbidden.intersection(permissions);
  expect(
    unexpected,
    isEmpty,
    reason:
        '$_androidChecklist：$path 声明了应用不使用的音频采集权限：$unexpected。'
        '播放器只输出音频；多余权限会出现在系统授权界面。',
  );

  // 刻意不断言 usesCleartextTraffic：部分音源返回 http 直链，这是
  // checklist 记录的已知取舍，未来安全收紧可以替换成 scoped 配置。
}

Set<String> _androidPermissions(String manifest) =>
    RegExp(r'<uses-permission\b[^>]*>')
        .allMatches(manifest)
        .map((match) {
          final name = RegExp(r'android:name="([^"]+)"')
              .firstMatch(match.group(0)!)
              ?.group(1);
          return name;
        })
        .whereType<String>()
        .toSet();

Set<String> _androidForegroundServiceTypes(String manifest) {
  final types = <String>{};
  for (final service in RegExp(r'<service\b[^>]*>').allMatches(manifest)) {
    final value = RegExp(r'android:foregroundServiceType="([^"]+)"')
        .firstMatch(service.group(0)!)
        ?.group(1);
    if (value == null) continue;
    types.addAll(value.split('|').map((type) => type.trim()));
  }
  types.remove('');
  return types;
}

String _upperSnake(String value) => value
    .replaceAllMapped(RegExp(r'([A-Z])'), (match) => '_${match.group(1)}')
    .toUpperCase();

// ---------------------------------------------------------------------------
// iOS / macOS
// ---------------------------------------------------------------------------

const String _iosChecklist = 'docs/platform_media_checklist.md「iOS」';
const String _macosChecklist = 'docs/platform_media_checklist.md「macOS」';

void _expectAppleContract() {
  const iosPlistPath = 'ios/Runner/Info.plist';
  final iosPlist = _read(iosPlistPath, _iosChecklist);
  expect(
    iosPlist,
    contains('<plist'),
    reason: '$_iosChecklist：$iosPlistPath 不是 property list。',
  );

  final backgroundModes = _plistStringArray(iosPlist, 'UIBackgroundModes');
  expect(
    backgroundModes,
    isNotNull,
    reason:
        '$_iosChecklist：$iosPlistPath 缺少 UIBackgroundModes；'
        '锁屏后音频会被系统挂起。',
  );
  expect(
    backgroundModes,
    contains('audio'),
    reason:
        '$_iosChecklist：$iosPlistPath 的 UIBackgroundModes 没有 audio '
        '(当前：$backgroundModes)。后台播放 / 锁屏控制依赖它；'
        '修复见 checklist「Required declarations」。',
  );
  expect(
    iosPlist,
    isNot(contains('NSMicrophoneUsageDescription')),
    reason:
        '$_iosChecklist：$iosPlistPath 出现了麦克风用途说明。'
        '应用不采集音频，申请麦克风权限会产生无关的系统提示。',
  );

  const macosPlistPath = 'macos/Runner/Info.plist';
  final macosPlist = _read(macosPlistPath, _macosChecklist);
  expect(
    macosPlist,
    contains('<plist'),
    reason: '$_macosChecklist：$macosPlistPath 不是 property list。',
  );
  expect(
    macosPlist,
    isNot(contains('NSMicrophoneUsageDescription')),
    reason:
        '$_macosChecklist：$macosPlistPath 出现了麦克风用途说明，'
        '但应用不做音频输入。',
  );

  for (final path in const [
    'macos/Runner/DebugProfile.entitlements',
    'macos/Runner/Release.entitlements',
  ]) {
    final entitlements = _read(path, _macosChecklist);
    expect(
      entitlements,
      contains('<plist'),
      reason: '$_macosChecklist：$path 不是 property list。',
    );

    // 反向断言：三个键必须真的被解析到，改名 / 换写法不能变成「缺席即通过」。
    for (final key in const [
      'com.apple.security.app-sandbox',
      'com.apple.security.network.client',
      'com.apple.security.network.server',
    ]) {
      expect(
        _plistBool(entitlements, key),
        isTrue,
        reason:
            '$_macosChecklist：$path 的 $key 不存在或不是 true。'
            '沙箱、出站音源请求与局域网同步都依赖它；'
            '修复见 checklist「Required declarations」。',
      );
    }
    expect(
      _plistBool(entitlements, 'com.apple.security.device.audio-input'),
      isNot(isTrue),
      reason:
          '$_macosChecklist：$path 启用了音频输入 entitlement，'
          '但应用只输出音频；去掉它可以避免无意义的设备权限。',
    );
  }
}

List<String>? _plistStringArray(String text, String key) {
  final block = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<array>([\\s\\S]*?)</array>',
  ).firstMatch(text);
  if (block == null) return null;
  return RegExp(r'<string>([^<]*)</string>')
      .allMatches(block.group(1)!)
      .map((match) => match.group(1)!)
      .toList();
}

bool? _plistBool(String text, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<(true|false)\\s*/>',
  ).firstMatch(text);
  if (match == null) return null;
  return match.group(1) == 'true';
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

const String _windowsChecklist = 'docs/platform_media_checklist.md「Windows」';

void _expectWindowsContract() {
  const headerPath = 'windows/runner/shell_identity.h';
  const mainPath = 'windows/runner/main.cpp';
  const installerPath = 'windows/installer/molia.iss';

  final header = _read(headerPath, _windowsChecklist);
  final appId = RegExp(r'kAppUserModelId\s*\[\s*\]\s*=\s*L"([^"]+)"')
      .firstMatch(header)
      ?.group(1);
  expect(
    appId,
    isNotNull,
    reason:
        '$_windowsChecklist：$headerPath 里找不到 '
        'kAppUserModelId[] = L"..."；身份常量改名后守卫会静默失效。',
  );

  final main = _read(mainPath, _windowsChecklist);
  final registration = RegExp(
    r'SetCurrentProcessExplicitAppUserModelID\s*\(\s*([^)]+?)\s*\)',
  ).firstMatch(main)?.group(1);
  expect(
    registration,
    isNotNull,
    reason:
        '$_windowsChecklist：$mainPath 没有在启动路径调用 '
        'SetCurrentProcessExplicitAppUserModelID；SMTC / 通知会归属到 '
        '"Unknown Application"。',
  );
  final literal = RegExp(r'^L"([^"]+)"$').firstMatch(registration!);
  if (literal != null) {
    expect(
      literal.group(1),
      appId,
      reason:
          '$_windowsChecklist：$mainPath 内联的身份与 $headerPath 的 '
          'kAppUserModelId 不一致（$appId vs ${literal.group(1)}）。',
    );
  } else {
    expect(
      registration,
      contains('kAppUserModelId'),
      reason:
          '$_windowsChecklist：$mainPath 设置了 AUMID，但参数不是 '
          'kAppUserModelId 也不是字面量，无法确认与 $headerPath 一致。',
    );
  }

  final installer = _read(installerPath, _windowsChecklist);
  final shortcutIds = RegExp(r'AppUserModelID:\s*"([^"]+)"')
      .allMatches(installer)
      .map((match) => match.group(1)!)
      .toList();
  expect(
    shortcutIds,
    isNotEmpty,
    reason:
        '$_windowsChecklist：$installerPath 的快捷方式没有 AppUserModelID；'
        '安装后的启动项不会与运行中的进程归为同一应用。',
  );
  final mismatched = shortcutIds.where((id) => id != appId).toList();
  expect(
    mismatched,
    isEmpty,
    reason:
        '$_windowsChecklist：$installerPath 的快捷方式 AppUserModelID '
        '与 $headerPath 不一致：$mismatched（期望 $appId）。'
        'SMTC 归属与通知分组会错乱。',
  );
}

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------

const String _linuxChecklist = 'docs/platform_media_checklist.md「Linux」';

void _expectLinuxContract() {
  const applicationsDir = 'linux/packaging/share/applications';
  final desktopFiles = Directory(applicationsDir)
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.desktop'))
      .toList();
  expect(
    desktopFiles.length,
    1,
    reason:
        '$_linuxChecklist：$applicationsDir 应只有一个 .desktop 入口，'
        '实际 ${desktopFiles.map((file) => file.path).toList()}；'
        '文件名本身就是 Wayland / MPRIS 的身份来源。',
  );
  final desktopPath = desktopFiles.single.path;
  final desktopIdentity = desktopPath
      .split(Platform.pathSeparator)
      .last
      .replaceFirst(RegExp(r'\.desktop$'), '');
  final entries = _desktopEntries(_read(desktopPath, _linuxChecklist));

  const cmakePath = 'linux/CMakeLists.txt';
  final cmake = _read(cmakePath, _linuxChecklist);
  final cmakeAppId = RegExp(r'set\s*\(\s*APPLICATION_ID\s+"([^"]+)"\s*\)')
      .firstMatch(cmake)
      ?.group(1);
  final binaryName = RegExp(r'set\s*\(\s*BINARY_NAME\s+"([^"]+)"\s*\)')
      .firstMatch(cmake)
      ?.group(1);
  expect(
    cmakeAppId,
    isNotNull,
    reason: '$_linuxChecklist：$cmakePath 缺少 APPLICATION_ID。',
  );
  expect(
    binaryName,
    isNotNull,
    reason: '$_linuxChecklist：$cmakePath 缺少 BINARY_NAME。',
  );

  const backendPath = 'lib/playback/flutter_media_session_backend.dart';
  final backend = _read(backendPath, _linuxChecklist);
  final dartAppId = RegExp(
    r"const\s+String\s+linuxMediaSessionAppId\s*=\s*'([^']+)'",
  ).firstMatch(backend)?.group(1);
  final dartDisplayName = RegExp(
    r"const\s+String\s+linuxMediaSessionDisplayName\s*=\s*'([^']+)'",
  ).firstMatch(backend)?.group(1);
  expect(
    dartAppId,
    isNotNull,
    reason: '$_linuxChecklist：$backendPath 缺少 linuxMediaSessionAppId。',
  );
  expect(
    dartDisplayName,
    isNotNull,
    reason: '$_linuxChecklist：$backendPath 缺少 linuxMediaSessionDisplayName。',
  );

  final startupWmClass = entries['StartupWMClass'];
  expect(
    startupWmClass,
    isNotNull,
    reason:
        '$_linuxChecklist：$desktopPath 缺少 StartupWMClass；'
        'Wayland / GNOME 会把窗口归到通用图标。',
  );
  expect(
    {
      'desktop 文件名': desktopIdentity,
      'CMake APPLICATION_ID': cmakeAppId,
      'Dart linuxMediaSessionAppId': dartAppId,
      'desktop StartupWMClass': startupWmClass,
    }.values.toSet(),
    hasLength(1),
    reason:
        '$_linuxChecklist：Linux 应用身份必须在桌面入口文件名、CMake '
        'APPLICATION_ID、Dart MPRIS DesktopEntry 与 StartupWMClass 四处一致，'
        '当前为 {desktop: $desktopIdentity, cmake: $cmakeAppId, '
        'dart: $dartAppId, wmClass: $startupWmClass}。',
  );

  expect(
    entries['Name'],
    dartDisplayName,
    reason:
        '$_linuxChecklist：$desktopPath 的 Name (${entries['Name']}) 与 '
        'Dart MPRIS Identity ($dartDisplayName) 不一致；媒体浮层与启动器会显示'
        '两个名字。',
  );
  expect(
    entries['Exec'],
    binaryName,
    reason:
        '$_linuxChecklist：$desktopPath 的 Exec (${entries['Exec']}) 与 '
        '$cmakePath 的 BINARY_NAME ($binaryName) 不一致；安装后的入口会启动'
        '不存在的可执行文件。',
  );

  // 桌面入口的键 / 图标契约已由 test/packaging/linux_desktop_test.dart 拥有，
  // 这里只做跨文件身份与启动目标的一致性。
}

Map<String, String> _desktopEntries(String text) {
  final entries = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith('[')) {
      continue;
    }
    final separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    entries[trimmed.substring(0, separator)] = trimmed.substring(separator + 1);
  }
  return entries;
}

// ---------------------------------------------------------------------------
// 桌面媒体后端身份（依赖 P1 的 media_kit 身份修正）
// ---------------------------------------------------------------------------

const String _desktopBackendChecklist =
    'docs/platform_media_checklist.md「Windows」/ ADR-0036';

void _expectDesktopBackendIdentity() {
  const path = 'lib/playback/desktop_audio_init_io.dart';
  final source = _read(path, _desktopBackendChecklist);
  expect(
    source,
    contains('JustAudioMediaKit.ensureInitialized()'),
    reason:
        '$_desktopBackendChecklist：$path 找不到 media_kit 初始化锚点，'
        '扫描可能已失效。',
  );

  final title = RegExp(r"JustAudioMediaKit\.title\s*=\s*'([^']*)'")
      .firstMatch(source)
      ?.group(1);
  expect(
    title,
    isNotNull,
    reason:
        '$_desktopBackendChecklist：$path 没有显式设置 '
        'JustAudioMediaKit.title；Windows 音量合成器会显示库默认名 '
        '"JustAudioMediaKit" 而不是 Molia。',
  );
  expect(
    title,
    isNot('JustAudioMediaKit'),
    reason:
        '$_desktopBackendChecklist：$path 仍在使用 media_kit 的默认窗口 / '
        '进程标题，混音器无法识别应用。',
  );

  // 共享产品显示名以 Linux 桌面入口的 Name 为准：它是用户可见的应用名，
  // 也是 MPRIS Identity 的来源。三处必须说同一个名字。
  const desktopPath =
      'linux/packaging/share/applications/top.stillmisty.molia.desktop';
  final productName = _desktopEntries(
    _read(desktopPath, _desktopBackendChecklist),
  )['Name'];
  expect(
    productName,
    isNotNull,
    reason: '$_desktopBackendChecklist：$desktopPath 缺少 Name，无法校验产品名。',
  );
  expect(
    title,
    productName,
    reason:
        '$_desktopBackendChecklist：$path 的 media_kit 标题 ($title) 与'
        '产品显示名 ($productName) 不一致；Windows 音量合成器 / 进程名会'
        '与其它平台品牌不一致。',
  );
}

// ---------------------------------------------------------------------------
// 公共
// ---------------------------------------------------------------------------

String _read(String path, String checklistSection) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '$checklistSection：配置面 $path 不存在；文件改名 / 移走后守卫'
        '不能静默通过，请同步更新测试与 checklist。',
  );
  return file.readAsStringSync();
}
