// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lyrics_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
///
/// 曲目变化的加载入口只有 [ensureForTrack]：组合根订阅播放快照后调用，
/// 页面只渲染 [state]（不再从 build 触发取词）。输出侧 / 预取 / 手动选择
/// 分别走 [preload] / [saveManual]；[retry] 供页面或用户显式重试。

@ProviderFor(LyricsProvider)
final lyricsProvider = LyricsProviderProvider._();

/// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
///
/// 曲目变化的加载入口只有 [ensureForTrack]：组合根订阅播放快照后调用，
/// 页面只渲染 [state]（不再从 build 触发取词）。输出侧 / 预取 / 手动选择
/// 分别走 [preload] / [saveManual]；[retry] 供页面或用户显式重试。
final class LyricsProviderProvider
    extends $NotifierProvider<LyricsProvider, LyricsState> {
  /// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
  ///
  /// 曲目变化的加载入口只有 [ensureForTrack]：组合根订阅播放快照后调用，
  /// 页面只渲染 [state]（不再从 build 触发取词）。输出侧 / 预取 / 手动选择
  /// 分别走 [preload] / [saveManual]；[retry] 供页面或用户显式重试。
  LyricsProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lyricsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lyricsProviderHash();

  @$internal
  @override
  LyricsProvider create() => LyricsProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LyricsState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LyricsState>(value),
    );
  }
}

String _$lyricsProviderHash() => r'ee3dafc8ccd0cc0fe4467d687386dadf169a32ed';

/// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
///
/// 曲目变化的加载入口只有 [ensureForTrack]：组合根订阅播放快照后调用，
/// 页面只渲染 [state]（不再从 build 触发取词）。输出侧 / 预取 / 手动选择
/// 分别走 [preload] / [saveManual]；[retry] 供页面或用户显式重试。

abstract class _$LyricsProvider extends $Notifier<LyricsState> {
  LyricsState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<LyricsState, LyricsState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LyricsState, LyricsState>,
              LyricsState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
