import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models/track.dart';
import '../services/artwork_palette_service.dart';
import '../services/covers/cover_resolution.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../services/lyrics_poster_service.dart';
import '../services/poster/poster_style_settings.dart';
import '../services/system_fonts_service.dart';
import '../l10n/app_localizations.dart';
import '../domain/models/poster_lyric_line.dart';
import '../theme/m3e_context.dart';
import '../theme/poster_palette.dart';
import '../theme/scheme_builder.dart';
import '../utils/responsive.dart';
import '../utils/save_as_label.dart';
import 'app_color_picker.dart';
import 'cover_picker_sheet.dart';
import 'font_picker_sheet.dart';
import 'poster_style_sheet.dart';
import 'track_artwork.dart';

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

  /// 海报位图：预览直接画 `ui.Image`，不再为了显示而编码 PNG。
  ui.Image? _posterImage;

  /// 生成中再改样式只记一个待重生成标记，当前这轮结束后用最新参数补一次，
  /// 避免多轮渲染并行抢 CPU。
  bool _isGenerating = false;
  bool _pendingRegenerate = false;
  Timer? _regenerateTimer;

  /// 最近一次编码出的 PNG；保存 / 分享连续操作时复用，换图后失效。
  ui.Image? _encodedImage;
  Uint8List? _cachedPngBytes;

  String? _errorMessage;

  /// 海报取色来源（跟随应用主题 / 跟随封面 / 自定义色），独立于全局主题。
  PosterColorSource _colorSource = PosterStyleSettings.defaultSource;
  int _customSeed = PosterStyleSettings.defaultSeed;

  /// 最近一次生成海报所用的配色签名：主题变化（莫奈 / 封面取色 / 亮度 /
  /// 种子色）时重新生成，保证海报真正跟随色彩系统。
  (Brightness, int, int, int)? _lastSchemeSignature;

  /// 海报字体覆盖：null = 跟随应用字体；'' = 强制系统默认；其它 = 字体族名。
  String? _posterFontOverride;

  /// 封面解析器（订阅变更信号：换封面后重新生成海报）。
  CoverResolver? _covers;
  void Function()? _removeCoverListener;
  String? _lastCoverSignature;

  bool get _isBusy => _isLoading || _isOperating || _isRegenerating;

  CoverResolver get _resolution => _covers ?? coverResolverOf(context);

  /// 取色 / 「跟随封面」可用性只看真实（原始或自定义）封面；默认封面是
  /// 占位，不参与取色。
  String? get _paletteCoverUrl => _resolution
      .realForId(widget.trackId, originalUrl: widget.albumCoverUrl)
      .url;

  /// 海报头部展示封面：自定义 → 原始 → 默认占位。
  String? get _displayCoverUrl => _resolution
      .displayForId(widget.trackId, originalUrl: widget.albumCoverUrl)
      .url;

  /// 当前曲目是否带真实封面（「跟随封面」来源可用性）。
  bool get _hasArtwork => (_paletteCoverUrl ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _initPosterSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covers = coverResolverOf(context);
    if (!identical(covers, _covers)) {
      _removeCoverListener?.call();
      _covers = covers;
      _removeCoverListener = covers.addChangeListener(_onCoverChanged);
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
      _pendingRegenerate = true;
      return;
    }
    // 主题切换 / 动画期间签名会连续变化：防抖成一次重生成。
    _scheduleRegeneration();
  }

  /// 自定义 / 默认封面变化：封面签名变了才重新生成（主题色来源也跟着
  /// [_paletteCoverUrl] 走同一份共享取色）。
  void _onCoverChanged() {
    if (!mounted) return;
    final signature = '$_displayCoverUrl|$_paletteCoverUrl';
    if (signature == _lastCoverSignature) return;
    if (_isBusy) {
      _pendingRegenerate = true;
      return;
    }
    _generatePoster();
  }

  /// 延迟一小段时间再重生成：主题动画会连续触发依赖变化，逐帧生成
  /// 既卡顿又只留下最后一版结果。
  void _scheduleRegeneration() {
    _regenerateTimer?.cancel();
    _regenerateTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _generatePoster();
    });
  }

  @override
  void dispose() {
    _removeCoverListener?.call();
    _regenerateTimer?.cancel();
    _posterImage?.dispose();
    super.dispose();
  }

  /// 先恢复海报字体覆盖与取色来源，再在首帧后生成海报（此时才能读取 Theme）。
  Future<void> _initPosterSettings() async {
    await PosterStyleSettings.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _posterFontOverride = PosterStyleSettings.fontFamily;
      _colorSource = PosterStyleSettings.colorSource;
      _customSeed = PosterStyleSettings.seed;
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
    _regenerateTimer?.cancel();
    if (_isGenerating) {
      // 生成中再改样式：只记标记，避免两轮渲染并行抢 CPU / 互相覆盖。
      _pendingRegenerate = true;
      return;
    }
    _isGenerating = true;
    final displayCoverUrl = _displayCoverUrl;
    // 生成期间再换封面：本轮结束后的补生成要拿到新签名。
    _lastCoverSignature = '$displayCoverUrl|$_paletteCoverUrl';
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

    // 已有海报：保留旧图，只标记重生成；首刷才进加载态。
    final bool hasPoster = _posterImage != null;
    setState(() {
      if (hasPoster) {
        _isRegenerating = true;
      } else {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    ui.Image? rendered;
    try {
      final scheme = await _resolveScheme(appScheme);
      final palette = PosterPalette.fromScheme(scheme);
      final posterService = LyricsPosterService();

      rendered = await posterService.renderPosterImage(
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

      if (!mounted) {
        rendered.dispose();
        return;
      }

      final previousImage = _posterImage;
      setState(() {
        _posterImage = rendered;
        rendered = null; // 所有权已交给 State，catch 不再释放。
        _isLoading = false;
        _isRegenerating = false;
      });
      _encodedImage = null;
      _cachedPngBytes = null;
      if (previousImage != null) {
        // 旧图在本帧仍可能被绘制；等新帧完成后再释放底层位图。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousImage.dispose();
        });
      }
    } catch (e) {
      rendered?.dispose();
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
          Provider.of<NotificationService>(
            context,
            listen: false,
          ).showErrorSnackBar(
            AppLocalizations.of(context)!.posterGenerationFailed(e.toString()),
          );
        }
      }
    } finally {
      _isGenerating = false;
      // 生成期间主题 / 封面又变了：用最新状态补一次，保证最终结果一致。
      if (_pendingRegenerate && mounted) {
        _pendingRegenerate = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _generatePoster();
        });
      }
    }
  }

  /// 保存 / 分享时才编码 PNG；换图后缓存自动失效。
  Future<Uint8List> _posterPngBytes() async {
    final image = _posterImage;
    if (image == null) {
      throw StateError('海报还没生成');
    }
    if (identical(_encodedImage, image) && _cachedPngBytes != null) {
      return _cachedPngBytes!;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('海报编码失败');
    }
    final bytes = data.buffer.asUint8List();
    _encodedImage = image;
    _cachedPngBytes = bytes;
    return bytes;
  }

  Future<void> _savePoster() async {
    if (_posterImage == null || _isOperating || _isRegenerating) return;

    HapticsService.mediumImpact();
    setState(() {
      _isOperating = true;
    });

    try {
      final l10n = AppLocalizations.of(context)!;
      final saveAs = context.read<SaveAs?>();
      if (saveAs == null) throw StateError('SaveAs 未装配');
      final bytes = await _posterPngBytes();
      final result = await saveAs.saveBytes(
        fileName:
            'lyrics_poster_${widget.trackTitle}_${DateTime.now().millisecondsSinceEpoch}.png',
        bytes: bytes,
        mimeType: 'image/png',
        relativeDir: saveAsPostersDirName,
        dialogTitle: l10n.save,
      );
      if (!mounted) return;
      final notifications = Provider.of<NotificationService>(
        context,
        listen: false,
      );
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
        Provider.of<NotificationService>(
          context,
          listen: false,
        ).showErrorSnackBar(
          '${AppLocalizations.of(context)!.operationFailed}: ${e.toString()}',
        );
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
    if (_posterImage == null || _isOperating || _isRegenerating) return;

    HapticsService.mediumImpact();
    setState(() {
      _isOperating = true;
    });

    try {
      final bytes = await _posterPngBytes();
      final tempDir = await getTemporaryDirectory();
      // 固定文件名：连续分享覆盖同一个临时文件，不在临时目录里堆 PNG。
      final file = File('${tempDir.path}/lyrics_poster_share.png');
      await file.writeAsBytes(bytes, flush: true);
      final posterService = LyricsPosterService();
      await posterService.sharePosterFile(
        file.path,
        '${widget.trackTitle} - ${widget.artistName}\n\n${widget.lyrics}',
      );
    } catch (e) {
      if (mounted) {
        Provider.of<NotificationService>(
          context,
          listen: false,
        ).showErrorSnackBar(
          '${AppLocalizations.of(context)!.operationFailed}: ${e.toString()}',
        );
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
    await PosterStyleSettings.setColorSource(source);
    if (mounted) _generatePoster();
  }

  /// 海报自定义色：任意取色（HSV + Hex），存入海报专属种子。
  Future<void> _pickPosterColor() async {
    if (_isLoading || _isOperating) return;
    HapticsService.selectionClick();
    final picked = await showAppColorPicker(context, initialColor: _customSeed);
    if (picked == null || !mounted || picked == _customSeed) return;
    setState(() {
      _customSeed = picked;
      _colorSource = PosterColorSource.custom;
    });
    await PosterStyleSettings.setCustomColor(picked);
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
    await PosterStyleSettings.setFontFamily(value);
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
      fileNameBase: widget.artistName.isEmpty
          ? widget.trackTitle
          : '${widget.trackTitle} - ${widget.artistName}',
    );
  }

  /// 海报设置行里的封面状态文案（与歌曲信息页同一套词）。
  String _coverStateLabel(AppLocalizations l10n) {
    final trackId = widget.trackId;
    if (trackId != null && _resolution.realForId(trackId).isCustom) {
      return l10n.coverCustomized;
    }
    if ((widget.albumCoverUrl ?? '').isNotEmpty) return l10n.coverFollowSong;
    return l10n.coverDefaultTitle;
  }

  /// 样式弹层里的封面缩略图（订阅换封面信号，与歌曲信息页同一套组件）。
  Widget? _coverThumbnail() {
    final trackId = widget.trackId;
    return CoverChangeBuilder(
      builder: (context, _) => TrackArtwork(
        // 缩略图主图只认真实封面；默认封面仅作加载失败回退。海报生成仍走
        // [_displayCoverUrl]（含默认封面占位）。
        listenForChanges: false,
        trackId: trackId,
        originalUrl: widget.albumCoverUrl,
        width: 28,
        height: 28,
        borderRadius: M3EShapes.radiusSmall,
        memCacheWidth: (28 * MediaQuery.of(context).devicePixelRatio).round(),
        fallbackIconSize: 16,
      ),
    );
  }

  /// 样式弹层：字体 / 取色来源 / 封面 / 自定义色，改动即时重生成海报。
  Future<void> _openStyleSheet() async {
    if (_isLoading || _isOperating) return;
    final l10n = AppLocalizations.of(context)!;
    await ResponsiveNavigation.showSimpleModal<void>(
      context: context,
      title: l10n.posterStyle,
      child: StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> run(Future<void> Function() action) async {
            await action();
            if (sheetContext.mounted) setSheetState(() {});
          }

          return PosterStyleSheet(
            fontLabel: l10n.posterFontLabel,
            fontValue: _posterFontLabel(l10n),
            onPickFont: () => unawaited(run(_changePosterFont)),
            colorSource: _colorSource,
            hasArtwork: _hasArtwork,
            onColorSourceChanged: (source) =>
                unawaited(run(() => _changeColorSource(source))),
            customColorLabel: l10n.posterColorCustomLabel,
            customColorHex: _hexOf(_customSeed),
            customColor: _customSeed,
            onPickCustomColor: () => unawaited(run(_pickPosterColor)),
            coverLabel: l10n.coverLabel,
            coverValue: _coverStateLabel(l10n),
            coverThumbnail: _coverThumbnail(),
            onPickCover: widget.trackId == null
                ? null
                : () => unawaited(run(_changeCover)),
          );
        },
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
                  child: Center(child: _buildPosterContent(theme)),
                ),
              ),
            ),
            // 控制栏：有海报即常驻（重生成期间禁用不消失），避免整条闪现。
            if (_posterImage != null)
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
                child: Row(
                  children: [
                    Expanded(
                      child: M3EButton.filled(
                        key: const Key('posterShareButton'),
                        onPressed: _isOperating || _isRegenerating
                            ? null
                            : _sharePoster,
                        icon: const Icon(Icons.share_rounded),
                        label: Text(l10n!.sharePoster),
                      ),
                    ),
                    const SizedBox(width: 8),
                    M3EMenu.entries(
                      position: M3EMenuAnchorPosition.bottomEnd,
                      anchorBuilder: (context, open) => M3EIconButton(
                        key: const Key('posterOverflow'),
                        variant: M3EIconButtonVariant.standard,
                        icon: const Icon(Icons.more_vert_rounded),
                        semanticLabel: l10n.moreActions,
                        onPressed: _isOperating || _isRegenerating
                            ? null
                            : open,
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'style':
                            unawaited(_openStyleSheet());
                          case 'save':
                            unawaited(_savePoster());
                        }
                      },
                      entries: [
                        M3EMenuEntry(
                          label: l10n.posterStyle,
                          value: 'style',
                          leading: const Icon(Icons.tune_rounded),
                        ),
                        M3EMenuEntry(
                          label: l10n.shareSaveImage,
                          value: 'save',
                          leading: const Icon(Icons.download_rounded),
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

  Widget _buildPosterContent(ThemeData theme) {
    // 有图就展示（重生成期间不卸载旧图，只在上面叠轻量进度）。
    final image = _posterImage;
    if (image != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: M3EShapes.radiusMedium,
            // 海报按 2x 设计尺寸绘制：scale 2 让 1440 宽的位图在布局里
            // 按 720 逻辑宽参与尺寸计算，再按屏幕宽度等比缩放。
            child: RawImage(
              image: image,
              scale: 2,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
          // 重生成 / 分享前编码 PNG 都在当前位图上叠轻量进度。
          if (_isRegenerating || _isOperating)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: M3EShapes.radiusMedium,
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
