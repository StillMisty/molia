// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
///
/// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
///
/// 1. **基础配色** [baseColorSource]：壁纸或自定义种子色，二选一；壁纸档
///    桌面优先真实壁纸图 seed，其次系统强调色（移动端即莫奈），都不可用时
///    回退自定义种子色；
/// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
///    seed 覆盖基础配色（包括覆盖壁纸）；无封面回退基础配色；
/// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
///    与取色来源正交可叠加。
///
/// 解析顺序（唯一）：
/// `封面 seed > 壁纸图 seed（桌面，基础=壁纸）> 强调色方案（基础=壁纸且可用）
/// > 自定义 seed`，再叠加纯黑。
///
/// 持久化键（登记进设置注册表，跟人走）：
/// - `theme_mode`：`system` / `light` / `dark`；
/// - `color_base`：`wallpaper` / `custom`（默认壁纸，平台不可用时回退种子色）；
/// - `follow_artwork_enabled`：播放有封面时是否用封面取色覆盖基础配色
///   （默认开启）；
/// - `pure_black_enabled`：深色模式是否使用纯黑表面（默认关闭）；
/// - `seed_color`：自定义种子色（ARGB int）；
/// - `app_font_family`：全局应用字体族名（null = 系统默认），设备本地。

@ProviderFor(ThemeProvider)
final themeProvider = ThemeProviderProvider._();

/// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
///
/// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
///
/// 1. **基础配色** [baseColorSource]：壁纸或自定义种子色，二选一；壁纸档
///    桌面优先真实壁纸图 seed，其次系统强调色（移动端即莫奈），都不可用时
///    回退自定义种子色；
/// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
///    seed 覆盖基础配色（包括覆盖壁纸）；无封面回退基础配色；
/// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
///    与取色来源正交可叠加。
///
/// 解析顺序（唯一）：
/// `封面 seed > 壁纸图 seed（桌面，基础=壁纸）> 强调色方案（基础=壁纸且可用）
/// > 自定义 seed`，再叠加纯黑。
///
/// 持久化键（登记进设置注册表，跟人走）：
/// - `theme_mode`：`system` / `light` / `dark`；
/// - `color_base`：`wallpaper` / `custom`（默认壁纸，平台不可用时回退种子色）；
/// - `follow_artwork_enabled`：播放有封面时是否用封面取色覆盖基础配色
///   （默认开启）；
/// - `pure_black_enabled`：深色模式是否使用纯黑表面（默认关闭）；
/// - `seed_color`：自定义种子色（ARGB int）；
/// - `app_font_family`：全局应用字体族名（null = 系统默认），设备本地。
final class ThemeProviderProvider
    extends $NotifierProvider<ThemeProvider, ThemeState> {
  /// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
  ///
  /// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
  ///
  /// 1. **基础配色** [baseColorSource]：壁纸或自定义种子色，二选一；壁纸档
  ///    桌面优先真实壁纸图 seed，其次系统强调色（移动端即莫奈），都不可用时
  ///    回退自定义种子色；
  /// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
  ///    seed 覆盖基础配色（包括覆盖壁纸）；无封面回退基础配色；
  /// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
  ///    与取色来源正交可叠加。
  ///
  /// 解析顺序（唯一）：
  /// `封面 seed > 壁纸图 seed（桌面，基础=壁纸）> 强调色方案（基础=壁纸且可用）
  /// > 自定义 seed`，再叠加纯黑。
  ///
  /// 持久化键（登记进设置注册表，跟人走）：
  /// - `theme_mode`：`system` / `light` / `dark`；
  /// - `color_base`：`wallpaper` / `custom`（默认壁纸，平台不可用时回退种子色）；
  /// - `follow_artwork_enabled`：播放有封面时是否用封面取色覆盖基础配色
  ///   （默认开启）；
  /// - `pure_black_enabled`：深色模式是否使用纯黑表面（默认关闭）；
  /// - `seed_color`：自定义种子色（ARGB int）；
  /// - `app_font_family`：全局应用字体族名（null = 系统默认），设备本地。
  ThemeProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'themeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$themeProviderHash();

  @$internal
  @override
  ThemeProvider create() => ThemeProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ThemeState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ThemeState>(value),
    );
  }
}

String _$themeProviderHash() => r'1421e653a81f43733c666fbc36a615c2874c4dd9';

/// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
///
/// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
///
/// 1. **基础配色** [baseColorSource]：壁纸或自定义种子色，二选一；壁纸档
///    桌面优先真实壁纸图 seed，其次系统强调色（移动端即莫奈），都不可用时
///    回退自定义种子色；
/// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
///    seed 覆盖基础配色（包括覆盖壁纸）；无封面回退基础配色；
/// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
///    与取色来源正交可叠加。
///
/// 解析顺序（唯一）：
/// `封面 seed > 壁纸图 seed（桌面，基础=壁纸）> 强调色方案（基础=壁纸且可用）
/// > 自定义 seed`，再叠加纯黑。
///
/// 持久化键（登记进设置注册表，跟人走）：
/// - `theme_mode`：`system` / `light` / `dark`；
/// - `color_base`：`wallpaper` / `custom`（默认壁纸，平台不可用时回退种子色）；
/// - `follow_artwork_enabled`：播放有封面时是否用封面取色覆盖基础配色
///   （默认开启）；
/// - `pure_black_enabled`：深色模式是否使用纯黑表面（默认关闭）；
/// - `seed_color`：自定义种子色（ARGB int）；
/// - `app_font_family`：全局应用字体族名（null = 系统默认），设备本地。

abstract class _$ThemeProvider extends $Notifier<ThemeState> {
  ThemeState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ThemeState, ThemeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ThemeState, ThemeState>,
              ThemeState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
