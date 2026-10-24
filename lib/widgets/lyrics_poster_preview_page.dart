import 'dart:async';
import 'dart:io';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models/track.dart';
import '../services/artwork_palette_service.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../services/lyrics_poster_service.dart';
import '../services/poster_color_store.dart';
import '../services/poster_font_store.dart';
import '../services/system_fonts_service.dart';
import '../l10n/app_localizations.dart';
import '../models/poster_lyric_line.dart';
import '../theme/m3e_context.dart';
import '../theme/poster_palette.dart';
import '../theme/scheme_builder.dart';
import '../utils/responsive.dart';
import '../utils/save_as_label.dart';
import 'app_color_picker.dart';
import 'app_network_image.dart';
import 'cover_picker_sheet.dart';
import 'font_picker_sheet.dart';

class LyricsPosterPreviewPage extends StatefulWidget {
  final String lyrics;
  final String trackTitle;
  final String artistName;
  final String? albumCoverUrl;
  final TrackId? trackId;
  final List<PosterLyricLine>? posterLyricLines;

  const LyricsPosterPreviewPage({
    super.key,
    required this.lyrics,
    required this.trackTitle,
    required this.artistName,
    this.albumCoverUrl,
    this.trackId,
    this.posterLyricLines,
  });

  @override
  State<LyricsPosterPreviewPage> createState() =>
      _LyricsPosterPreviewPageState();
}

class _LyricsPosterPreviewPageState extends State<LyricsPosterPreviewPage> {
  bool _isLoading = true;
  bool _isOperating = false; // 保存或分享操作中

  /// 已有海报时的重新生成（换色/换字体/主题变化）：保留旧图不清空，
  /// 只在预览区叠一层轻量进度，避免整页闪成加载态。
  bool _isRegenerating = false;
  Uint8List? _posterBytes;
  String? _tempFilePath;
  String? _errorMessage;

  /// 海报取色来源（跟随应用主题 / 跟随封面 / 自定义色），独立于全局主题。
  PosterColorSource _colorSource = PosterColorStore.defaultSource;
  int _customSeed = PosterColorStore.defaultSeed;

  /// 最近一次生成海报所用的配色签名：主题变化（莫奈 / 封面取色 / 亮度 /
  /// 种子色）时重新生成，保证海报真正跟随色彩系统。
  (Brightness, int, int, int)? _lastSchemeSignature;
  bool _schemeDirty = false;

  /// 海报字体覆盖：null = 跟随应用字体；'' = 强制系统默认；其它 = 字体族名。
  String? _posterFontOverride;

  /// 自定义封面存储（订阅 revision：换封面后重新生成海报）。
  CustomCoverStore? _covers;
  String? _lastCoverSignature;

  bool get _isBusy => _isLoading || _isOperating || _isRegenerating;

  /// 取色 / 「跟随封面」可用性只看真实（原始或自定义）封面；默认封面是
  /// 占位，不参与取色。
  String? get _paletteCoverUrl =>
      CustomCoverStore.instance.resolveTrackCoverForId(
        widget.trackId,
        originalUrl: widget.albumCoverUrl,
      );

  /// 海报头部展示封面：自定义 → 原始 → 默认占位。
  String? get _displayCoverUrl => CustomCoverStore.instance
      .resolveForDisplayById(widget.trackId, originalUrl: widget.albumCoverUrl);

  /// 当前曲目是否带真实封面（「跟随封面」来源可用性）。
  bool get _hasArtwork => (_paletteCoverUrl ?? '').isNotEmpty;

  /// 底部设置行里值控件的统一宽度：右值成一列，行与行之间不参差。
  static const double _settingValueWidth = 190;

  @override
  void initState() {
    super.initState();
    _initPosterSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covers =
        context.read<CustomCoverStore?>() ?? CustomCoverStore.instance;
    if (!identical(covers, _covers)) {
      _covers?.revision.removeListener(_onCoverChanged);
      _covers = covers..revision.addListener(_onCoverChanged);
    }
    final scheme = Theme.of(context).colorScheme;
    final signature = (
      scheme.brightness,
      scheme.primary.toARGB32(),
      scheme.surface.toARGB32(),
      scheme.tertiary.toARGB32(),
    );
    if (_lastSchemeSignature == signature) return;
    final changed = _lastSchemeSignature != null;
    _lastSchemeSignature = signature;
    if (!changed) return; // 首次：由 initState 的 post-frame 生成
    if (_isBusy) {
      _schemeDirty = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _generatePoster();
    });
  }

  /// 自定义 / 默认封面变化：封面签名变了才重新生成（主题色来源也跟着
  /// [_paletteCoverUrl] 走同一份共享取色）。
  void _onCoverChanged() {
    if (!mounted) return;
    final signature = '$_displayCoverUrl|$_paletteCoverUrl';
    if (signature == _lastCoverSignature) return;
    if (_isBusy) {
      _schemeDirty = true;
      return;
    }
    _generatePoster();
  }

  @override
  void dispose() {
    _covers?.revision.removeListener(_onCoverChanged);
    super.dispose();
  }

  /// 先恢复海报字体覆盖与取色来源，再在首帧后生成海报（此时才能读取 Theme）。
  Future<void> _initPosterSettings() async {
    final savedFont = await PosterFontStore.load();
    final savedColor = await PosterColorStore.load();
    if (!mounted) return;
    setState(() {
      _posterFontOverride = savedFont;
      _colorSource = savedColor.source;
      _customSeed = savedColor.seed;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _generatePoster();
      }
    });
  }

  /// 解析海报配色来源：封面方案经共享取色服务查询（与主题/歌词同源），
  /// 无封面或取色失败回退应用主题（不回退到另一套取色）。
  Future<ColorScheme> _resolveScheme(ColorScheme appScheme) async {
    switch (_colorSource) {
      case PosterColorSource.appTheme:
        return appScheme;
      case PosterColorSource.custom:
        return buildColorScheme(Color(_customSeed), appScheme.brightness);
      case PosterColorSource.artwork:
        final url = _paletteCoverUrl;
        final paletteService = context.read<ArtworkPaletteService?>();
        if (url == null || url.isEmpty || paletteService == null) {
          return appScheme;
        }
        final palette = await paletteService.load(url);
        return palette?.schemeFor(appScheme.brightness) ?? appScheme;
    }
  }

  Future<void> _generatePoster() async {
    if (!mounted) return;
    final displayCoverUrl = _displayCoverUrl;
    // 生成期间再换封面：本轮结束后的补生成要拿到新签名。
    _lastCoverSignature = '$displayCoverUrl|$_paletteCoverUrl';
    HapticsService.lightImpact();
    final appScheme = Theme.of(context).colorScheme;
    final appName = AppLocalizations.of(context)?.appName ?? 'Molia';
    // 海报字体优先级：海报独立覆盖 > 应用字体（主题注入）> 系统默认；
    // 覆盖值为空串表示显式强制系统默认。
    final ({String? family, List<String>? fallback}) uiFont =
        switch (_posterFontOverride) {
      null => (
          family: context.typeScale.bodyMedium.fontFamily,
          fallback: context.typeScale.bodyMedium.fontFamilyFallback,
        ),
      '' => (
          family: SystemFontsService.platformDefaultFamily,
          fallback: SystemFontsService.platformDefaultFontFallbacks,
        ),
      final family => (family: family, fallback: null),
    };

    // 已有海报：保留旧图（不清 bytes），只标记重生成；首刷才进加载态。
    final bool hasPoster = _posterBytes != null;
    setState(() {
      if (hasPoster) {
        _isRegenerating = true;
      } else {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    try {
      final scheme = await _resolveScheme(appScheme);
      final palette = PosterPalette.fromScheme(scheme);
      final posterService = LyricsPosterService();

      final bytes = await posterService.generatePosterData(
        lyrics: widget.lyrics,
        posterLyricLines: widget.posterLyricLines,
        trackTitle: widget.trackTitle,
        artistName: widget.artistName,
        albumCoverUrl: displayCoverUrl,
        // 配色由取色来源解析出的单一方案映射
        backgroundColor: palette.background,
        titleColor: palette.title,
        artistColor: palette.artist,
        lyricsColor: palette.lyrics,
        extendedColor: palette.extended,
        watermarkColor: palette.watermark,
        separatorColor: palette.separator,
        fontFamily: uiFont.family,
        fontFamilyFallback: uiFont.fallback,
        watermarkText: appName,
      );

      final tempDir = await getTemporaryDirectory();
      final fileName =
          'lyrics_poster_preview_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes);

      // 旧预览临时文件（分享用）：换新后清理，失败静默。
      final oldPath = _tempFilePath;
      if (oldPath != null) {
        unawaited(File(oldPath).delete().catchError((_) => File(oldPath)));
      }

      if (mounted) {
        setState(() {
          _posterBytes = bytes;
          _tempFilePath = file.path;
          _isLoading = false;
          _isRegenerating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRegenerating = false;
          // 已有旧图：保留预览 + 提示，避免整页变错误态。
          if (!hasPoster) {
            _errorMessage = e.toString();
          }
        });
        if (hasPoster) {
          Provider.of<NotificationService>(context, listen: false)
              .showErrorSnackBar(
            AppLocalizations.of(context)!.posterGenerationFailed(e.toString()),
          );
        }
      }
    } finally {
      // 生成期间主题又变了：补一次生成，保证最终海报与当前配色一致。
      if (_schemeDirty && mounted) {
        _schemeDirty = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _generatePoster();
        });
      }
    }
  }

  Future<void> _savePoster() async {
    if (_posterBytes == null || _isOperating) return;

    HapticsService.mediumImpact();
    setState(() {
      _isOperating = true;
    });

    try {
      final l10n = AppLocalizations.of(context)!;
      final saveAs = context.read<SaveAs?>();
      if (saveAs == null) throw StateError('SaveAs 未装配');
      final result = await saveAs.saveBytes(
        fileName:
            'lyrics_poster_${widget.trackTitle}_${DateTime.now().millisecondsSinceEpoch}.png',
        bytes: _posterBytes!,
        mimeType: 'image/png',
        relativeDir: saveAsPostersDirName,
        dialogTitle: l10n.save,
        allowedExtensions: ['png'],
      );
      if (!mounted) return;
      final notifications =
          Provider.of<NotificationService>(context, listen: false);
      switch (result) {
        case SaveAsSaved(:final displayPath, :final kind):
          notifications.showSuccessSnackBar(
            savedLocationMessage(l10n, kind, displayPath),
          );
        case SaveAsCancelled():
          return;
        case SaveAsFailed():
          notifications.showErrorSnackBar(l10n.saveFailed);
      }
    } catch (e) {
      if (mounted) {
        Provider.of<NotificationService>(context, listen: false).showErrorSnackBar(
            '${AppLocalizations.of(context)!.operationFailed}: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isOperating = false;
        });
      }
    }
  }

  Future<void> _sharePoster() async {
    if (_tempFilePath == null || _isOperating) return;

    HapticsService.mediumImpact();
    setState(() {
      _isOperating = true;
    });

    try {
      final posterService = LyricsPosterService();
      await posterService.sharePosterFile(
        _tempFilePath!,
        '${widget.trackTitle} - ${widget.artistName}\n\n${widget.lyrics}',
      );
    } catch (e) {
      if (mounted) {
        Provider.of<NotificationService>(context, listen: false).showErrorSnackBar(
            '${AppLocalizations.of(context)!.operationFailed}: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isOperating = false;
        });
      }
    }
  }

  /// 切换取色来源并重新生成；无封面时不允许选「跟随封面」。
  Future<void> _changeColorSource(PosterColorSource source) async {
    if (_colorSource == source || _isLoading || _isOperating) return;
    if (source == PosterColorSource.artwork && !_hasArtwork) return;

    HapticsService.selectionClick();
    setState(() {
      _colorSource = source;
    });
    await PosterColorStore.saveSource(source);
    if (mounted) _generatePoster();
  }

  /// 海报自定义色：任意取色（HSV + Hex），存入海报专属种子。
  Future<void> _pickPosterColor() async {
    if (_isLoading || _isOperating) return;
    HapticsService.selectionClick();
    final picked = await showAppColorPicker(
      context,
      initialColor: _customSeed,
    );
    if (picked == null || !mounted || picked == _customSeed) return;
    setState(() {
      _customSeed = picked;
      _colorSource = PosterColorSource.custom;
    });
    await PosterColorStore.saveSeed(picked);
    await PosterColorStore.saveSource(PosterColorSource.custom);
    if (mounted) _generatePoster();
  }

  /// 选择海报字体：跟随应用字体 / 系统默认 / 设备已装字体。
  Future<void> _changePosterFont() async {
    if (_isLoading || _isOperating) return;
    HapticsService.selectionClick();
    final l10n = AppLocalizations.of(context)!;
    final choice = await showFontPickerSheet(
      context,
      title: l10n.posterFontLabel,
      includeInherit: true,
      inheritLabel: l10n.posterFontFollowApp,
      selected: switch (_posterFontOverride) {
        null => const FontChoice.inherit(),
        '' => const FontChoice.system(),
        final family => FontChoice.family(family),
      },
    );
    if (choice == null || !mounted) return;
    final value = choice.inherit ? null : (choice.family ?? '');
    if (value == _posterFontOverride) return;
    setState(() => _posterFontOverride = value);
    await PosterFontStore.save(value);
    if (mounted) {
      _generatePoster();
    }
  }

  /// 底部操作栏的当前字体文案。
  String _posterFontLabel(AppLocalizations l10n) {
    return switch (_posterFontOverride) {
      null => l10n.posterFontFollowApp,
      '' => l10n.fontSystemDefault,
      final family => family,
    };
  }

  /// 自定义色显示：统一六进制（与设置页主题色同一格式）。
  String _hexOf(int argb) {
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// 打开共享封面选择弹层（与歌曲信息页 / 设置页默认封面同一实现）。
  Future<void> _changeCover() async {
    final trackId = widget.trackId;
    if (trackId == null || _isLoading || _isOperating) return;
    HapticsService.selectionClick();
    await showCoverPickerSheet(
      context,
      trackId: trackId,
      originalCoverUrl: widget.albumCoverUrl,
    );
  }

  /// 海报设置行里的封面状态文案（与歌曲信息页同一套词）。
  String _coverStateLabel(AppLocalizations l10n) {
    final trackId = widget.trackId;
    if (trackId != null &&
        CustomCoverStore.instance.trackCoverUrl(trackId) != null) {
      return l10n.coverCustomized;
    }
    if ((widget.albumCoverUrl ?? '').isNotEmpty) return l10n.coverFollowSong;
    return l10n.coverDefaultTitle;
  }

  /// 封面设置行：缩略图 + 状态 + 展开图标，点开同一封面弹层。
  Widget _buildCoverPicker(AppLocalizations l10n, ColorScheme scheme) {
    final trackId = widget.trackId;
    return ValueListenableBuilder<int>(
      valueListenable: CustomCoverStore.instance.revision,
      builder: (context, _, __) => M3EButton(
        key: const Key('posterCoverPickerButton'),
        style: M3EButtonStyle.text,
        onPressed: trackId == null ? null : _changeCover,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppNetworkImage(
              // 缩略图主图只认真实封面；默认封面仅作加载失败回退。海报
              // 生成仍走 [_displayCoverUrl]（含默认封面占位）。
              url: CustomCoverStore.instance.resolveTrackCoverForId(
                trackId,
                originalUrl: widget.albumCoverUrl,
              ),
              fallbackUrl: CustomCoverStore.instance.defaultCoverUrl,
              width: 28,
              height: 28,
              borderRadius: BorderRadius.circular(6),
              memCacheWidth:
                  (28 * MediaQuery.of(context).devicePixelRatio).round(),
              fallbackIconSize: 16,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _coverStateLabel(l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 设置行：左标签 + 右值控件（值控件同宽 [_settingValueWidth]、右对齐成一列）。
  Widget _settingRow({required String label, required Widget value}) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        SizedBox(
          width: _settingValueWidth,
          child: Align(alignment: Alignment.centerRight, child: value),
        ),
      ],
    );
  }

  /// 取色来源选择控件（跟随应用主题 / 跟随封面 / 自定义色）。
  Widget _buildColorSourcePicker(AppLocalizations l10n) {
    return M3EDropdownMenu<PosterColorSource>(
      items: [
        M3EDropdownItem<PosterColorSource>(
          label: l10n.posterColorSourceAppTheme,
          value: PosterColorSource.appTheme,
          selected: _colorSource == PosterColorSource.appTheme,
        ),
        M3EDropdownItem<PosterColorSource>(
          label: l10n.posterColorSourceArtwork,
          value: PosterColorSource.artwork,
          selected: _colorSource == PosterColorSource.artwork,
          // 无封面：置灰并提示（tooltip 不可用于 item，副文案由页面
          // 状态保证：选中态不会被置灰项污染）。
          disabled: !_hasArtwork,
        ),
        M3EDropdownItem<PosterColorSource>(
          label: l10n.posterColorSourceCustom,
          value: PosterColorSource.custom,
          selected: _colorSource == PosterColorSource.custom,
        ),
      ],
      singleSelect: true,
      showChipAnimation: false,
      onSelectionChanged: (items) {
        if (items.isNotEmpty) _changeColorSource(items.first.value);
      },
    );
  }

  /// 自定义色控件：色块 + Hex，点击打开任意取色器。
  Widget _buildCustomColorButton(ColorScheme scheme) {
    return M3EButton(
      style: M3EButtonStyle.text,
      onPressed: _isBusy ? null : _pickPosterColor,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color(_customSeed),
              border: Border.all(color: scheme.outlineVariant),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _hexOf(_customSeed),
            style: context.typeScale.bodyMedium,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final previewLayout = context.layoutType(ResponsivePageType.preview);

    return PopScope(
      canPop: !_isBusy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isBusy) {
          HapticsService.mediumImpact();
        }
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: M3EAppBar.top(
          title: Text(AppLocalizations.of(context)!.sharePoster),
          automaticallyImplyLeading: true,
          backgroundColor: theme.colorScheme.surface,
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(previewLayout.horizontalPadding),
                child: ResponsivePageContainer(
                  pageType: ResponsivePageType.preview,
                  child: Center(
                    child: _buildPosterContent(theme, l10n),
                  ),
                ),
              ),
            ),
            // 控制栏：有海报即常驻（重生成期间禁用不消失），避免整条闪现。
            if (_posterBytes != null)
              Container(
                padding: EdgeInsets.only(
                  left: previewLayout.horizontalPadding,
                  right: previewLayout.horizontalPadding,
                  top: 16,
                  bottom: 16 + MediaQuery.of(context).padding.bottom,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 版式：设置项统一成「左标签 + 右值控件」的行，值控件同宽
                    // 190 并右对齐成一列（字体不再是一个占满整宽、看起来像
                    // CTA 的 text 按钮）；动作收成底部两个带文案的按钮——
                    // 原来两个撑满半屏、只有图标的按钮看不出「保存 / 分享」。
                    _settingRow(
                      label: l10n!.posterFontLabel,
                      value: M3EButton(
                        style: M3EButtonStyle.text,
                        onPressed: _isLoading || _isOperating
                            ? null
                            : _changePosterFont,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _posterFontLabel(l10n),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.expand_more_rounded, size: 18),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _settingRow(
                      label: l10n.posterColorSource,
                      value: _buildColorSourcePicker(l10n),
                    ),
                    const SizedBox(height: 4),
                    _settingRow(
                      label: l10n.coverLabel,
                      value: _buildCoverPicker(l10n, theme.colorScheme),
                    ),
                    if (_colorSource == PosterColorSource.custom) ...[
                      const SizedBox(height: 4),
                      _settingRow(
                        label: l10n.posterColorCustomLabel,
                        value: _buildCustomColorButton(theme.colorScheme),
                      ),
                    ],
                    const SizedBox(height: 12),
                    M3EDivider(color: theme.colorScheme.outlineVariant),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: M3EButton.tonal(
                            key: const Key('posterSaveButton'),
                            onPressed: _isOperating ? null : _savePoster,
                            icon: const Icon(Icons.download_rounded),
                            label: Text(l10n.saveChanges),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: M3EButton.filled(
                            key: const Key('posterShareButton'),
                            onPressed: _isOperating ? null : _sharePoster,
                            icon: const Icon(Icons.share_rounded),
                            label: Text(l10n.sharePoster),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPosterContent(ThemeData theme, AppLocalizations? l10n) {
    // 有图就展示（重生成期间不卸载旧图，只在上面叠轻量进度）。
    final bytes = _posterBytes;
    if (bytes != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Column(
                children: [
                  Icon(
                    Icons.broken_image_rounded,
                    size: 64,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context)!.lyricsFailedToLoad,
                    style: context.typeScale.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          if (_isRegenerating)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: M3EProgressIndicator.circular(
                    size: 32,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    if (_isLoading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const M3ELoadingIndicator(),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.loadingGenerating,
            style: context.typeScale.bodyMedium,
          ),
        ],
      );
    }

    if (_errorMessage != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 64,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!
                .posterGenerationFailed(_errorMessage!),
            style: context.typeScale.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          M3EButton.icon(
            onPressed: _generatePoster,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(AppLocalizations.of(context)!.retryButton),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
