part of 'app_shell.dart';

class MyThemedApp extends StatefulWidget {
  const MyThemedApp({
    super.key,
    this.onUserInteraction,
    this.showOnboarding = false,
    this.onboardingStore,
  });

  /// 用户交互回调（组合根接同步调度器：续期「最近交互」的活跃窗口）。
  final VoidCallback? onUserInteraction;

  /// 首帧是否渲染首次引导（组合根在 runApp 前读设备本地标记决定）。
  final bool showOnboarding;

  /// 完成标记写入器（测试注入；生产为默认 prefs 实现）。
  final OnboardingStore? onboardingStore;

  @override
  State<MyThemedApp> createState() => _MyThemedAppState();
}

class _MyThemedAppState extends State<MyThemedApp> {
  /// 「首次连通」通知订阅：与在哪个页面无关，双方各自弹一次底栏提示。
  StreamSubscription<SyncPeerState>? _peerConnected;

  /// 附近设备配对请求订阅：接收方在任意页面都要弹确认窗。
  StreamSubscription<SyncPairingRequest>? _incomingPairing;

  /// 同一条请求只允许一个确认窗（服务本身已串行；这里防流重放 / 重入）。
  bool _incomingPairingOpen = false;

  /// 确认窗关闭动画期间到达的请求：排队等当前窗收口，不能直接拒绝。
  final IncomingPairingQueue _incomingPairingQueue = IncomingPairingQueue();

  /// 应用壳在 MaterialApp 之上，配对回执不依赖宿主 context（后者只用于
  /// 展示弹层）；提前持有 provider，宿主 context 消失后仍能拒绝排队请求。
  late final SyncProvider _sync;

  /// 自动检查（启动 / 每日）发现的更新：弹一次合并提示，展示完清空。
  late final UpdateCheckCoordinator? _updateChecks;

  /// 更新弹窗未关闭前不再响应新通知；关闭时再处理排队中的最新一条。
  bool _updatePromptOpen = false;

  @override
  void initState() {
    super.initState();
    _loadSavedLocale();
    // 自定义应用名称（顶栏回退文案）需要重建 MaterialApp.title。
    AppBrandingService.titleNotifier.addListener(_onBrandingChanged);
    AppBrandingService.load();
    // 震动反馈开关（设备本地偏好）：载入后全应用触感立即按它判定。
    HapticsService.load();
    final sync = context.read<SyncProvider>();
    _sync = sync;
    _peerConnected = sync.state.peerConnectedNotices.listen(_onPeerConnected);
    _incomingPairing = sync.state.incomingPairingRequests.listen(
      _onIncomingPairing,
    );
    _updateChecks = context.read<UpdateCheckCoordinator?>();
    _updateChecks?.notice.addListener(_onUpdateNotice);
    // 检查可能在本 State 挂载前已完成（启动检查很快），补一次。
    _onUpdateNotice();
  }

  /// 首次与某台设备真正交换数据：提示一次（名称缺失时用短设备 id 兜底）。
  ///
  /// 文案与提示出口都取 Navigator 之下的 context（本 State 在
  /// MaterialApp 之上，没有 Localizations 祖先，见 app_ui_messenger.dart）。
  void _onPeerConnected(SyncPeerState peer) {
    if (!mounted) return;
    // 本 State 在 MaterialApp 之上（没有 Localizations 祖先），提示文案取
    // Navigator 之下的宿主 context（与 AppUiMessenger 同一做法）。
    final hostContext = navigatorKey.currentContext;
    if (hostContext == null) return;
    showSyncPeerConnectedNotice(hostContext, peer);
  }

  /// 收到配对请求：弹接收方确认窗（含确认码与授权警告）。
  ///
  /// 当前窗尚未彻底关闭时先入队，等 `finally` 后再逐条展示；没有宿主
  /// context 时把排队请求统一拒绝，让发起方立刻拿到结论，而不是等满 TTL。
  Future<void> _onIncomingPairing(SyncPairingRequest request) async {
    if (!mounted) {
      await _rejectIncomingPairing(request);
      return;
    }
    _incomingPairingQueue.add(request);
    if (_incomingPairingOpen) return;
    await _drainIncomingPairings();
  }

  Future<void> _drainIncomingPairings() => _incomingPairingQueue.drain(
    present: _presentIncomingPairing,
    reject: _rejectIncomingPairing,
  );

  /// 展示一条确认窗；false = 宿主 context 已不可用，交给队列统一拒绝。
  Future<bool> _presentIncomingPairing(SyncPairingRequest request) async {
    final hostContext = navigatorKey.currentContext;
    if (hostContext == null) return false;
    _incomingPairingOpen = true;
    try {
      await showSyncIncomingPairingDialog(
        hostContext,
        provider: _sync,
        request: request,
      );
    } catch (_) {
      // 弹窗本身失败（主题 / 路由异常）也要给发起方结论，不能让请求悬着。
      await _rejectIncomingPairing(request);
    } finally {
      _incomingPairingOpen = false;
    }
    return true;
  }

  Future<void> _rejectIncomingPairing(SyncPairingRequest request) async {
    try {
      await _sync.commands.pairing.respond(request.requestId, accept: false);
    } catch (_) {
      // 可选子系统：拒绝回执失败只影响对方等待，不打断应用壳。
    }
  }

  void _onBrandingChanged() {
    if (mounted) setState(() {});
  }

  /// 自动检查发现应用 / 音源更新：在 root navigator 上弹合并提示。
  void _onUpdateNotice() {
    final notice = _updateChecks?.notice.value;
    if (notice == null || _updatePromptOpen) return;
    _updatePromptOpen = true;
    // 通知可能来自启动尾巴（首帧之后），等一帧确保 Navigator 可用。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _presentUpdateNotice(notice);
    });
  }

  Future<void> _presentUpdateNotice(UpdateCheckNotice notice) async {
    try {
      final hostContext = navigatorKey.currentContext;
      if (!mounted || hostContext == null) return;
      final action = await showUpdateAvailableDialog(hostContext, notice);
      if (!mounted) return;
      // 只清掉「这一条」；弹窗期间若又发现新版本，保留给下一轮。
      if (identical(_updateChecks?.notice.value, notice)) {
        _updateChecks?.notice.value = null;
      }
      final page = switch (action) {
        UpdatePromptAction.app => const UpdateSettingsPage(),
        UpdatePromptAction.sources => const SourcesPage(),
        UpdatePromptAction.later => null,
      };
      if (page != null && navigatorKey.currentContext != null) {
        await showSettingsSheet(
          navigatorKey.currentContext!,
          initialPage: page,
        );
      }
    } finally {
      _updatePromptOpen = false;
      // 弹窗 / 设置页期间到达的新通知在这里补弹；宿主还没就绪时保持静默，
      // 由下一次通知 / 回前台再触发，避免 post-frame 自循环。
      if (mounted &&
          _updateChecks?.notice.value != null &&
          navigatorKey.currentContext != null) {
        _onUpdateNotice();
      }
    }
  }

  @override
  void dispose() {
    AppBrandingService.titleNotifier.removeListener(_onBrandingChanged);
    _updateChecks?.notice.removeListener(_onUpdateNotice);
    unawaited(_peerConnected?.cancel());
    unawaited(_incomingPairing?.cancel());
    super.dispose();
  }

  Future<void> _loadSavedLocale() async {
    final savedLocale = await LanguageService.getSavedLocale();
    if (savedLocale != null) {
      LanguageService.localeNotifier.value = savedLocale;
    }
  }

  /// 品牌默认名（Molia）。
  ///
  /// 只读计算 + 帧末注入：build 阶段直接更新 notifier 会触发
  /// markNeedsBuild 告警；已自定义名称时 applyLocalizedDefault 内部自动忽略。
  void _syncLocalizedBranding(Locale? locale) {
    final effective =
        locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final resolved =
        LanguageService.supportedLocales.any(
          (supported) => supported.languageCode == effective.languageCode,
        )
        ? effective
        : LanguageService.supportedLocales.first;
    final name = lookupAppLocalizations(resolved).appName;
    if (name == AppBrandingService.defaultTitle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppBrandingService.applyLocalizedDefault(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 外层 TrayDormantGate：关闭到托盘时整棵界面（含 MaterialApp）换成
    // 休眠占位，恢复时重建（见 tray_dormant_gate.dart）。
    //
    // 最小化时树仍挂载（保留页面状态与内存，恢复要跟手），但整棵界面里的
    // 装饰动画不应继续按显示刷新率出帧：TickerMode 只静音 ticker，不清缓存、
    // 不改播放语义。托盘隐藏仍由 TrayDormantGate 卸载，二者互不替代。
    return TrayDormantGate(
      color: context.read<ThemeProvider>().colorScheme.surface,
      childBuilder: (context) =>
          AppPresenceTickerMode(child: _buildApp(context)),
    );
  }

  Widget _buildApp(BuildContext context) {
    // ThemeProvider（主题模式 + 基础配色 + 封面覆盖 + 纯黑）是唯一主题来源：
    // Selector 提升到壳外，colorScheme 变化时重建整个 M3EMaterialApp，
    // 同时刷新 material_ui ThemeData 与 M3EThemeData。
    // 应用语言走 LanguageService.localeNotifier，设置页切换后立即生效。
    //
    // 莫奈配色由 DynamicColorBuilder 提供（平台不支持时回调 null）：
    // 基础配色=壁纸时生效；注入必须放到 post-frame，避免 build 中同步
    // 触发 notifyListeners。
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context.read<ThemeProvider>().updateMonetSchemes(
            lightDynamic,
            darkDynamic,
          );
        });
        return ValueListenableBuilder<Locale?>(
          valueListenable: LanguageService.localeNotifier,
          builder: (context, locale, _) {
            // 品牌默认名统一 Molia（仍走 l10n：各语言同值，保留将来本地化的入口）。
            _syncLocalizedBranding(locale);
            return Selector<
              ThemeProvider,
              ({ColorScheme scheme, String? fontFamily})
            >(
              selector: (context, provider) => (
                scheme: provider.colorScheme,
                fontFamily: provider.appFontFamily,
              ),
              // 方案色变化（切歌取色/莫奈/种子色/亮度）经 AnimatedSchemeBuilder
              // 平滑过渡，避免整站颜色闪变；只插值 ColorScheme，material_ui 与
              // M3E 两套主题都由同一插值结果重建，保证过渡期一致。
              // 字体族变化不参与插值，由同一 Selector 直接触发两套主题重建。
              builder: (context, themeState, _) => AnimatedSchemeBuilder(
                scheme: themeState.scheme,
                builder: (context, animatedScheme) {
                  final systemUiOverlayStyle = buildSystemUiOverlayStyle(
                    animatedScheme,
                  );
                  final themedData = buildAppThemeData(
                    animatedScheme,
                    systemUiOverlayStyle: systemUiOverlayStyle,
                    fontFamily: themeState.fontFamily,
                    // 未自定义「应用字体」时使用启动时解析的系统 UI 字体
                    // （Windows 读 MessageFont；其它平台为 null）。
                    platformDefaultFontFamily:
                        SystemFontsService.platformDefaultFamily,
                    platformDefaultFontFallbacks:
                        SystemFontsService.platformDefaultFontFallbacks,
                  );

                  return M3EMaterialApp(
                    title: AppBrandingService.titleNotifier.value,
                    scaffoldMessengerKey: scaffoldMessengerKey,
                    navigatorKey: navigatorKey,
                    locale: locale,
                    // material_ui 的 delegates 已合并 Material/Widgets/Cupertino 三套文案
                    localizationsDelegates: const [
                      AppLocalizations.delegate,
                      ...GlobalMaterialLocalizations.delegates,
                    ],
                    supportedLocales: LanguageService.supportedLocales,
                    // material_ui 透传：既有组件通过 Theme.of 读到的外观保持现状。
                    theme: themedData,
                    darkTheme: themedData,
                    // M3E 侧数据：颜色/字体从 themedData 映射（按 ThemeData
                    // 实例缓存）；字体同时同步到 emphasized 角色，见
                    // `buildM3EThemeData`。
                    data: buildM3EThemeData(themedData),
                    // 方案色过渡已由 AnimatedSchemeBuilder 逐帧插值完成，
                    // 关掉 MaterialApp 内置主题动画，避免二次缓动造成两套主题不同步。
                    themeAnimationStyle: AnimationStyle.noAnimation,
                    // 系统亮度由 ThemeProvider.updateThemeFromSystem 驱动，
                    // 封面/莫奈取色由 ThemeProvider 内部优先级决定；不启用 M3E
                    // 自适应与 OS 动态色，避免双主题源互相覆盖。
                    autoTheming: false,
                    dynamicColoring: false,
                    // targetSdk 37（Android 15+ 强制 edge-to-edge）下保持系统栏透明、
                    // 内容绘制到系统栏下方，与 settings_page.dart 的 edgeToEdge 行为一致。
                    drawUnderSystemBars: true,
                    // appBuilder 只做系统栏 AnnotatedRegion：
                    // M3E 内部已用 M3ETheme 包裹 child，MaterialApp 的 Theme 又
                    // 位于 builder 之上（见 material_ui app.dart _materialBuilder），
                    // 此处不重复包 Theme。
                    appBuilder: (context, child) {
                      final themedChild = child ?? const SizedBox.shrink();
                      final baseMediaQuery = MediaQuery.of(context);
                      final baseScale = baseMediaQuery.textScaler.scale(1.0);
                      final mediaData = baseMediaQuery.copyWith(
                        textScaler: TextScaler.linear(baseScale),
                      );

                      return AnnotatedRegion<SystemUiOverlayStyle>(
                        value: systemUiOverlayStyle,
                        child: MediaQuery(
                          data: mediaData,
                          // 视口粗档：`layoutType` / `horizontalPadding` /
                          // `isLargeScreen` 只在这里按档位订阅，桌面拖拽窗口时
                          // 不再逐像素重建页面（见 `widgets/responsive.dart`）。
                          child: ViewportClassScope.host(
                            // 用户交互（含弹层 / 菜单，都在 Navigator 之内）→
                            // 同步调度器续期「最近交互」窗口；只观察不拦截。
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) =>
                                  widget.onUserInteraction?.call(),
                              child: themedChild,
                            ),
                          ),
                        ),
                      );
                    },
                    // home 是 Navigator 的初始路由，不走 M3EPageRoute：
                    // 显式包一层路由级 M3E 主题，页面才不依赖 App 级
                    // DefaultTextStyle（预测返回退场 + 主题重建的断言见
                    // lib/widgets/m3e_page_route.dart）。
                    home: M3ERouteTheme(
                      builder: (_) => MyApp(
                        key: appRootKey,
                        showOnboarding: widget.showOnboarding,
                        onboardingStore: widget.onboardingStore,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
