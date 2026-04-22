import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';
import 'package:oimg/src/file_open/file_open_controller.dart';
import 'package:oimg/src/file_open/file_open_providers.dart';
import 'package:oimg/src/file_open/opened_image_file.dart';
import 'package:oimg/src/optimization/optimization_plan.dart';
import 'package:oimg/src/optimization/optimization_providers.dart';
import 'package:oimg/src/rust/frb_generated.dart';
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:oimg/src/settings/app_settings.dart';
import 'package:oimg/src/settings/app_settings_controller.dart';
import 'package:oimg/src/settings/developer_diagnostics.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

const _uiScale = 0.8;
const _uiRadius = 0.4;
const _titleBarHeight = 19.0;
const _defaultSidebarWidth = 280.0;
const _minSidebarWidth = 180.0;
const _maxSidebarWidth = 420.0;
const _defaultSettingsSidebarWidth = 320.0;
const _minSettingsSidebarWidth = 240.0;
const _maxSettingsSidebarWidth = 420.0;
const _defaultBottomSidebarHeight = 165.0;
const _minBottomSidebarHeight = 140.0;
const _maxBottomSidebarHeight = 320.0;
const _settingsBottomSectionsFoldThreshold = 650.0;
const List<({double value, Color color})> _qualityMetricColorStops = [
  (value: 0, color: Color(0xFFFF0000)),
  (value: 20, color: Color(0xFFAA0000)),
  (value: 40, color: Color(0xFFDE602E)),
  (value: 60, color: Color(0xFFDBDE25)),
  (value: 80, color: Color(0xFF34C759)),
  (value: 100, color: Color(0xFF0094D9)),
];
const List<({double value, Color color})> _savingsMetricColorStops = [
  ..._qualityMetricColorStops,
  (value: 200, color: Color(0xFFA21BB7)),
  (value: 400, color: Color(0xFFE31C76)),
];

enum _SavingsDisplayMode { percent, ratio }

class _SavingsDisplayModeNotifier extends Notifier<_SavingsDisplayMode> {
  @override
  _SavingsDisplayMode build() => _SavingsDisplayMode.percent;

  void toggle() {
    state = state == _SavingsDisplayMode.percent
        ? _SavingsDisplayMode.ratio
        : _SavingsDisplayMode.percent;
  }
}

final _savingsDisplayModeProvider =
    NotifierProvider<_SavingsDisplayModeNotifier, _SavingsDisplayMode>(
      _SavingsDisplayModeNotifier.new,
    );

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureWindow();
  await RustLib.init();

  const slimgApi = FrbSlimgApi();
  final controller = FileOpenController(
    channel: MethodChannelFileOpenChannel(),
    slimg: slimgApi,
    initialPaths: args,
  );
  await controller.initialize();

  runApp(
    ProviderScope(
      overrides: [
        slimgApiProvider.overrideWithValue(slimgApi),
        fileOpenControllerProvider.overrideWith((ref) => controller),
      ],
      child: const MyApp(),
    ),
  );
}

Future<void> _configureWindow() async {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    return;
  }

  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(1280, 720),
    center: true,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseTypography = const Typography.geist().scale(_uiScale);
    final settings = ref.watch(appSettingsProvider).asData?.value;

    return ShadcnApp(
      title: 'OIMG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorSchemes.lightSlate,
        radius: _uiRadius,
        scaling: _uiScale,
        typography: baseTypography,
        surfaceOpacity: 0.92,
        surfaceBlur: 8,
      ),
      darkTheme: ThemeData.dark(
        colorScheme: ColorSchemes.darkSlate,
        radius: _uiRadius,
        scaling: _uiScale,
        typography: baseTypography,
        surfaceOpacity: 0.88,
        surfaceBlur: 12,
      ),
      themeMode: settings?.themePreference.themeMode ?? ThemeMode.system,
      home: const OimgHomePage(),
    );
  }
}

class OimgHomePage extends ConsumerStatefulWidget {
  const OimgHomePage({super.key});

  @override
  ConsumerState<OimgHomePage> createState() => _OimgHomePageState();
}

class _OimgHomePageState extends ConsumerState<OimgHomePage> {
  late final FileOpenController _controller;
  late final ProviderSubscription<AsyncValue<AppSettings>>
  _appSettingsSubscription;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(fileOpenControllerProvider);
    _controller.addListener(_onControllerChanged);
    _appSettingsSubscription = ref.listenManual<AsyncValue<AppSettings>>(
      appSettingsProvider,
      (previous, next) {
        next.whenData(_syncDeveloperSettings);
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _appSettingsSubscription.close();
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final notice = _controller.takePendingNotice();
    if (notice == null || !mounted) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      showToast(
        context: context,
        location: ToastLocation.topRight,
        builder: (context, overlay) {
          final theme = Theme.of(context);
          return Card(
            borderRadius: theme.borderRadiusLg,
            child: Row(
              children: [
                Icon(
                  LucideIcons.triangleAlert,
                  color: theme.colorScheme.primary,
                  size: 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    notice,
                    style: TextStyle(color: theme.colorScheme.mutedForeground),
                  ).small(),
                ),
                const SizedBox(width: 12),
                GhostButton(
                  onPressed: overlay.close,
                  density: ButtonDensity.icon,
                  child: const Icon(LucideIcons.x),
                ),
              ],
            ),
          );
        },
      );
    });
  }

  void _syncDeveloperSettings(AppSettings settings) {
    final enabled = settings.developerModeEnabled && settings.timingLogsEnabled;
    DeveloperDiagnostics.setTimingLogsEnabled(enabled);
    ref.read(slimgApiProvider).setTimingLogsEnabled(enabled: enabled);
  }

  Future<void> _openDeveloperDialog() {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return const _DeveloperSettingsDialog();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(fileOpenControllerProvider);
    final title =
        controller.currentDisplayTitle ?? 'Open images from your desktop';

    return Scaffold(
      headers: [
        AppBar(
          height: _titleBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DragToMoveArea(
                  child: Center(
                    child: Text(
                      'OIMG',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.4,
                        color: Theme.of(context).colorScheme.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DeveloperButton(
                      onPressed: () {
                        unawaited(_openDeveloperDialog());
                      },
                    ),
                    if (controller.hasSession) ...[
                      const SizedBox(width: 6),
                      _TitleBarHomeButton(onPressed: controller.clearSession),
                    ],
                    const SizedBox(width: 6),
                    const _TitleBarSettingsButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      child: _FileDropSurface(
        child: controller.hasSession
            ? _ImageSessionView(title: title)
            : const _EmptyState(),
      ),
    );
  }
}

class _FileDropSurface extends ConsumerStatefulWidget {
  const _FileDropSurface({required this.child});

  final Widget child;

  @override
  ConsumerState<_FileDropSurface> createState() => _FileDropSurfaceState();
}

class _FileDropSurfaceState extends ConsumerState<_FileDropSurface> {
  bool _isDragOver = false;
  late bool _dropSurfaceReady;

  @override
  void initState() {
    super.initState();
    _dropSurfaceReady = !Platform.isMacOS;
    if (!_dropSurfaceReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_enableDropSurface());
      });
    }
  }

  Future<void> _enableDropSurface() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) {
      return;
    }
    setState(() {
      _dropSurfaceReady = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_dropSurfaceReady) {
      return widget.child;
    }

    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        final hasFileUri = event.session.items.any(
          (item) => item.canProvide(Formats.fileUri),
        );
        if (!hasFileUri) {
          return DropOperation.none;
        }

        return event.session.allowedOperations.contains(DropOperation.copy)
            ? DropOperation.copy
            : DropOperation.none;
      },
      onDropEnter: (_) {
        setState(() {
          _isDragOver = true;
        });
      },
      onDropLeave: (_) {
        setState(() {
          _isDragOver = false;
        });
      },
      onDropEnded: (_) {
        if (!_isDragOver) {
          return;
        }
        setState(() {
          _isDragOver = false;
        });
      },
      onPerformDrop: (event) async {
        final paths = await _readDroppedPaths(event);
        if (!mounted) {
          return;
        }

        setState(() {
          _isDragOver = false;
        });

        if (paths.isEmpty) {
          return;
        }

        await ref.read(fileOpenControllerProvider).openPaths(paths);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_isDragOver)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                    width: 2,
                  ),
                  borderRadius: theme.borderRadiusXxl,
                ),
                child: Center(
                  child: Card(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    borderRadius: theme.borderRadiusXl,
                    child: const Text('Drop files or folders here').small(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<List<String>> _readDroppedPaths(PerformDropEvent event) async {
    final paths = <String>[];

    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.fileUri)) {
        continue;
      }

      final uri = await _readDroppedFileUri(reader);
      if (uri == null || uri.scheme != 'file') {
        continue;
      }
      paths.add(uri.toFilePath());
    }

    return paths;
  }

  Future<Uri?> _readDroppedFileUri(Object reader) {
    final completer = Completer<Uri?>();
    final progress = (reader as dynamic).getValue<Uri>(
      Formats.fileUri,
      (value) {
        if (!completer.isCompleted) {
          completer.complete(value);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );
    if (progress == null && !completer.isCompleted) {
      completer.complete(null);
    }
    return completer.future;
  }
}

class _ImageSessionView extends ConsumerStatefulWidget {
  const _ImageSessionView({required this.title});

  final String title;

  @override
  ConsumerState<_ImageSessionView> createState() => _ImageSessionViewState();
}

class _ImageSessionViewState extends ConsumerState<_ImageSessionView> {
  double _sidebarWidth = _defaultSidebarWidth;
  double _settingsSidebarWidth = _defaultSettingsSidebarWidth;
  double _bottomSidebarHeight = _defaultBottomSidebarHeight;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(fileOpenControllerProvider);
    final currentFile = controller.currentFile;
    if (currentFile == null) {
      return const _EmptyState();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wideLayout = constraints.maxWidth >= 1120;
          final sidebar = _ExplorerSidebar(controller: controller);
          final stage = controller.isFolderSelected
              ? _FolderStage(controller: controller)
              : _ImageStage(title: widget.title, currentFile: currentFile);
          const settingsSidebar = _SettingsSidebar();
          final bottomSidebar = _BottomSidebar(controller: controller);

          if (wideLayout) {
            final maxWidth = _clampSidebarWidth(constraints.maxWidth * 0.38);
            final sidebarWidth = _sidebarWidth.clamp(
              _minSidebarWidth,
              maxWidth,
            );
            final settingsMaxWidth = _clampSettingsSidebarWidth(
              constraints.maxWidth * 0.34,
            );
            final settingsSidebarWidth = _settingsSidebarWidth.clamp(
              _minSettingsSidebarWidth,
              settingsMaxWidth,
            );
            final bottomSidebarMaxHeight = _clampBottomSidebarHeight(
              constraints.maxHeight * 0.4,
            );
            final bottomSidebarHeight = _bottomSidebarHeight.clamp(
              _minBottomSidebarHeight,
              bottomSidebarMaxHeight,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: sidebarWidth, child: sidebar),
                      _ResizeHandle(
                        axis: Axis.horizontal,
                        onDragUpdate: (delta) {
                          setState(() {
                            _sidebarWidth = _clampSidebarWidth(
                              _sidebarWidth + delta,
                              maxWidth: maxWidth,
                            );
                          });
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: stage),
                      const SizedBox(width: 12),
                      _ResizeHandle(
                        axis: Axis.horizontal,
                        onDragUpdate: (delta) {
                          setState(() {
                            _settingsSidebarWidth = _clampSettingsSidebarWidth(
                              _settingsSidebarWidth - delta,
                              maxWidth: settingsMaxWidth,
                            );
                          });
                        },
                      ),
                      SizedBox(
                        width: settingsSidebarWidth,
                        child: settingsSidebar,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _ResizeHandle(
                  axis: Axis.vertical,
                  onDragUpdate: (delta) {
                    setState(() {
                      _bottomSidebarHeight = _clampBottomSidebarHeight(
                        _bottomSidebarHeight - delta,
                        maxHeight: bottomSidebarMaxHeight,
                      );
                    });
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(height: bottomSidebarHeight, child: bottomSidebar),
              ],
            );
          }

          final bottomSidebarMaxHeight = _clampBottomSidebarHeight(
            constraints.maxHeight * 0.35,
          );
          final bottomSidebarHeight = _bottomSidebarHeight.clamp(
            _minBottomSidebarHeight,
            bottomSidebarMaxHeight,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 220, child: sidebar),
                    const SizedBox(height: 16),
                    Expanded(child: stage),
                    const SizedBox(height: 16),
                    const SizedBox(height: 420, child: settingsSidebar),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _ResizeHandle(
                axis: Axis.vertical,
                onDragUpdate: (delta) {
                  setState(() {
                    _bottomSidebarHeight = _clampBottomSidebarHeight(
                      _bottomSidebarHeight - delta,
                      maxHeight: bottomSidebarMaxHeight,
                    );
                  });
                },
              ),
              const SizedBox(height: 8),
              SizedBox(height: bottomSidebarHeight, child: bottomSidebar),
            ],
          );
        },
      ),
    );
  }

  double _clampSidebarWidth(double width, {double? maxWidth}) {
    return width.clamp(_minSidebarWidth, maxWidth ?? _maxSidebarWidth);
  }

  double _clampSettingsSidebarWidth(double width, {double? maxWidth}) {
    return width.clamp(
      _minSettingsSidebarWidth,
      maxWidth ?? _maxSettingsSidebarWidth,
    );
  }

  double _clampBottomSidebarHeight(double height, {double? maxHeight}) {
    return height.clamp(
      _minBottomSidebarHeight,
      maxHeight ?? _maxBottomSidebarHeight,
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.axis, required this.onDragUpdate});

  final Axis axis;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: isHorizontal
            ? (details) => onDragUpdate(details.delta.dx)
            : null,
        onVerticalDragUpdate: isHorizontal
            ? null
            : (details) => onDragUpdate(details.delta.dy),
        child: isHorizontal
            ? const SizedBox(width: 8)
            : const SizedBox(height: 8),
      ),
    );
  }
}

class _ImageStage extends ConsumerWidget {
  const _ImageStage({required this.title, required this.currentFile});

  final String title;
  final OpenedImageFile currentFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appSettings = ref.watch(appSettingsProvider).asData?.value;
    final plan = ref.watch(currentOptimizationPlanProvider);
    final preview = ref.watch(currentPreviewProvider);
    final optimizedDisplay = ref.watch(currentOptimizedDisplayProvider);
    final displayMode = ref.watch(currentPreviewDisplayModeProvider);
    final differenceFrame = ref.watch(currentPreviewDifferenceFrameProvider);
    final heatmapFrame = ref.watch(currentPreviewHeatmapFrameProvider);
    final heatmapVisibilityMode = ref.watch(heatmapVisibilityModeProvider);
    final hasOptimizedPreview = optimizedDisplay != null;
    final planData = plan.maybeWhen(data: (value) => value, orElse: () => null);
    final differenceUnavailableTooltip =
        planData?.useSourceImageForPreview == true
        ? 'Not available for lossless formats'
        : null;
    final supportsDifference =
        hasOptimizedPreview &&
        differenceUnavailableTooltip == null &&
        optimizedDisplay.width == currentFile.metadata.width &&
        optimizedDisplay.height == currentFile.metadata.height;
    final showPreviewPathHeader =
        appSettings?.developerModeEnabled == true &&
        appSettings?.previewPathHeaderEnabled == true;

    void selectOriginal() {
      ref
          .read(previewDisplaySelectionProvider.notifier)
          .select(
            filePath: currentFile.path,
            mode: PreviewDisplayMode.original,
          );
    }

    void selectOptimized() {
      if (!hasOptimizedPreview) {
        return;
      }
      ref
          .read(previewDisplaySelectionProvider.notifier)
          .select(
            filePath: currentFile.path,
            mode: PreviewDisplayMode.optimized,
          );
    }

    void selectDifference() {
      if (!supportsDifference) {
        return;
      }
      final artifactId = optimizedDisplay.artifactId;
      ref
          .read(previewDifferenceRequestProvider.notifier)
          .requestForArtifact(artifactId);
      ref
          .read(previewDisplaySelectionProvider.notifier)
          .select(
            filePath: currentFile.path,
            mode: PreviewDisplayMode.difference,
          );
    }

    void selectHeatmap() {
      if (!supportsDifference) {
        return;
      }
      final artifactId = optimizedDisplay.artifactId;
      ref
          .read(previewDifferenceRequestProvider.notifier)
          .requestForArtifact(artifactId);
      ref
          .read(previewDisplaySelectionProvider.notifier)
          .select(filePath: currentFile.path, mode: PreviewDisplayMode.heatmap);
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyR): selectOriginal,
        const SingleActivator(LogicalKeyboardKey.keyE): selectOptimized,
        const SingleActivator(LogicalKeyboardKey.keyD): selectDifference,
        const SingleActivator(LogicalKeyboardKey.keyH): selectHeatmap,
      },
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Card(
          padding: EdgeInsets.zero,
          borderRadius: theme.borderRadiusXl,
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showPreviewPathHeader) ...[
                      Text(
                        FileOpenController.directoryOf(currentFile.path),
                        style: TextStyle(
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ).xSmall(),
                      const SizedBox(height: 4),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (currentFile.metadata.hasTransparency) ...[
                              Text(
                                'transparent',
                                style: TextStyle(
                                  color: theme.colorScheme.mutedForeground,
                                ),
                              ).xSmall(),
                              const SizedBox(width: 10),
                            ],
                            Tooltip(
                              waitDuration: const Duration(milliseconds: 250),
                              showDuration: const Duration(milliseconds: 120),
                              tooltip: (context) => TooltipContainer(
                                child: Text(
                                  _formatMegapixels(
                                    currentFile.metadata.width,
                                    currentFile.metadata.height,
                                  ),
                                ),
                              ),
                              child: Text(
                                '${currentFile.metadata.width} x ${currentFile.metadata.height}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: theme.colorScheme.mutedForeground,
                                ),
                              ).xSmall(),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (preview.hasError) ...[
                      const SizedBox(height: 10),
                      Text('Preview unavailable').xSmall().muted(),
                    ],
                  ],
                ),
              ),
              Divider(color: theme.colorScheme.border.withValues(alpha: 0.4)),
              Expanded(
                child: Container(
                  color: theme.colorScheme.background,
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                  child: plan.when(
                    data: (_) {
                      final fileName = FileOpenController.fileNameOf(
                        currentFile.path,
                      );
                      switch (displayMode) {
                        case PreviewDisplayMode.original:
                          return _PreviewCanvas(
                            fileName: fileName,
                            path: currentFile.path,
                          );
                        case PreviewDisplayMode.optimized:
                          if (optimizedDisplay != null) {
                            if (optimizedDisplay.usesOutputPath) {
                              return _PreviewCanvas(
                                fileName: fileName,
                                path: optimizedDisplay.outputPath,
                                unavailableMessage:
                                    'Unable to render optimized preview.',
                              );
                            }
                            return _PreviewCanvas(
                              fileName: fileName,
                              encodedBytes: optimizedDisplay.encodedBytes,
                              unavailableMessage:
                                  'Unable to render optimized preview.',
                            );
                          }
                          return preview.when(
                            data: (_) => _PreviewCanvas(
                              fileName: fileName,
                              path: currentFile.path,
                            ),
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (_, _) => _PreviewCanvas(
                              fileName: fileName,
                              path: currentFile.path,
                            ),
                          );
                        case PreviewDisplayMode.difference:
                          return DifferencePreview(
                            retentionScopeKey: currentFile.path,
                            frame: differenceFrame,
                            fileName: fileName,
                            showCoordinates:
                                appSettings
                                    ?.differenceTooltipShowsCoordinates ??
                                true,
                            useRgbSwatches:
                                appSettings?.differenceTooltipUsesSwatches ??
                                false,
                            onShowCoordinatesChanged: (value) {
                              unawaited(
                                ref
                                    .read(appSettingsProvider.notifier)
                                    .setDifferenceTooltipShowsCoordinates(
                                      value,
                                    ),
                              );
                            },
                            onUseRgbSwatchesChanged: (value) {
                              unawaited(
                                ref
                                    .read(appSettingsProvider.notifier)
                                    .setDifferenceTooltipUsesSwatches(value),
                              );
                            },
                            unavailableMessage:
                                'Difference preview unavailable.',
                          );
                        case PreviewDisplayMode.heatmap:
                          return HeatmapPreview(
                            retentionScopeKey: currentFile.path,
                            frame: heatmapFrame,
                            fileName: fileName,
                            showCoordinates:
                                appSettings
                                    ?.differenceTooltipShowsCoordinates ??
                                true,
                            useRgbSwatches:
                                appSettings?.differenceTooltipUsesSwatches ??
                                false,
                            backgroundPath:
                                heatmapVisibilityMode ==
                                        HeatmapVisibilityMode.overlay &&
                                    optimizedDisplay?.usesOutputPath == true
                                ? optimizedDisplay?.outputPath
                                : null,
                            backgroundEncodedBytes:
                                heatmapVisibilityMode ==
                                        HeatmapVisibilityMode.overlay &&
                                    optimizedDisplay?.usesOutputPath != true
                                ? optimizedDisplay?.encodedBytes
                                : null,
                            onShowCoordinatesChanged: (value) {
                              unawaited(
                                ref
                                    .read(appSettingsProvider.notifier)
                                    .setDifferenceTooltipShowsCoordinates(
                                      value,
                                    ),
                              );
                            },
                            onUseRgbSwatchesChanged: (value) {
                              unawaited(
                                ref
                                    .read(appSettingsProvider.notifier)
                                    .setDifferenceTooltipUsesSwatches(value),
                              );
                            },
                            unavailableMessage: 'Heatmap preview unavailable.',
                          );
                      }
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, _) => _PreviewCanvas(
                      fileName: FileOpenController.fileNameOf(currentFile.path),
                      path: currentFile.path,
                    ),
                  ),
                ),
              ),
              // const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: _PreviewDisplayModeRow(
                  filePath: currentFile.path,
                  displayMode: displayMode,
                  hasOptimizedPreview: hasOptimizedPreview,
                  supportsDifference: supportsDifference,
                  differenceUnavailableTooltip: differenceUnavailableTooltip,
                  optimizedArtifactId: optimizedDisplay?.artifactId,
                  onSelectOriginal: selectOriginal,
                  onSelectOptimized: selectOptimized,
                  onSelectDifference: selectDifference,
                  onSelectHeatmap: selectHeatmap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderStage extends StatelessWidget {
  const _FolderStage({required this.controller});

  final FileOpenController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folderPath = controller.selectedFolderPath;
    final folderFiles = controller.selectedFolderFiles;
    final totalBytes = controller.selectedFolderSizeBytes;
    if (folderPath == null) {
      return const SizedBox.shrink();
    }

    return Card(
      padding: EdgeInsets.zero,
      borderRadius: theme.borderRadiusXl,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folderPath,
                  style: TextStyle(color: theme.colorScheme.mutedForeground),
                ).xSmall(),
                const SizedBox(height: 4),
                Text(
                  controller.selectedFolderName ?? folderPath,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _PreviewMetaItem(
                      label: 'Images',
                      value: '${folderFiles.length}',
                    ),
                    if (totalBytes case final bytes?)
                      _PreviewMetaItem(
                        label: 'Size',
                        value: _formatBytes(bytes),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // const Divider(),
          Expanded(
            child: Container(
              color: theme.colorScheme.background,
              padding: const EdgeInsets.all(14),
              child: _FolderCollage(
                files: folderFiles,
                onOpenFile: controller.showPath,
                onRevealFile: controller.showInFileManager,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewCanvas extends StatelessWidget {
  const _PreviewCanvas({
    required this.fileName,
    this.path,
    this.encodedBytes,
    this.unavailableMessage,
  });

  final String fileName;
  final String? path;
  final Uint8List? encodedBytes;
  final String? unavailableMessage;

  @override
  Widget build(BuildContext context) {
    final populated = [
      path != null,
      encodedBytes != null,
    ].where((value) => value).length;
    assert(populated == 1);

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 6,
      child: Container(
        alignment: Alignment.center,
        child: path != null
            ? Image.file(
                File(path!),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  return _ImageLoadError(fileName: fileName);
                },
              )
            : Image.memory(
                encodedBytes!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  return _PreviewUnavailable(
                    message: unavailableMessage ?? 'Unable to render preview.',
                  );
                },
              ),
      ),
    );
  }
}

class DifferencePreview extends StatelessWidget {
  const DifferencePreview({
    super.key,
    required this.retentionScopeKey,
    required this.frame,
    required this.fileName,
    required this.showCoordinates,
    required this.useRgbSwatches,
    this.onShowCoordinatesChanged,
    this.onUseRgbSwatchesChanged,
    this.unavailableMessage = 'Unable to render preview.',
  });

  final String retentionScopeKey;
  final AsyncValue<PreviewDifferenceFrame?> frame;
  final String fileName;
  final bool showCoordinates;
  final bool useRgbSwatches;
  final ValueChanged<bool>? onShowCoordinatesChanged;
  final ValueChanged<bool>? onUseRgbSwatchesChanged;
  final String unavailableMessage;

  @override
  Widget build(BuildContext context) {
    return _DiffVisualizationPreview(
      retentionScopeKey: retentionScopeKey,
      frame: frame,
      fileName: fileName,
      showCoordinates: showCoordinates,
      useRgbSwatches: useRgbSwatches,
      onShowCoordinatesChanged: onShowCoordinatesChanged,
      onUseRgbSwatchesChanged: onUseRgbSwatchesChanged,
      unavailableMessage: unavailableMessage,
      keyPrefix: 'difference-preview',
    );
  }
}

class HeatmapPreview extends StatelessWidget {
  const HeatmapPreview({
    super.key,
    required this.retentionScopeKey,
    required this.frame,
    required this.fileName,
    required this.showCoordinates,
    required this.useRgbSwatches,
    this.backgroundPath,
    this.backgroundEncodedBytes,
    this.onShowCoordinatesChanged,
    this.onUseRgbSwatchesChanged,
    this.unavailableMessage = 'Unable to render preview.',
  });

  final String retentionScopeKey;
  final AsyncValue<PreviewDifferenceFrame?> frame;
  final String fileName;
  final bool showCoordinates;
  final bool useRgbSwatches;
  final String? backgroundPath;
  final Uint8List? backgroundEncodedBytes;
  final ValueChanged<bool>? onShowCoordinatesChanged;
  final ValueChanged<bool>? onUseRgbSwatchesChanged;
  final String unavailableMessage;

  @override
  Widget build(BuildContext context) {
    return _DiffVisualizationPreview(
      retentionScopeKey: retentionScopeKey,
      frame: frame,
      fileName: fileName,
      showCoordinates: showCoordinates,
      useRgbSwatches: useRgbSwatches,
      backgroundPath: backgroundPath,
      backgroundEncodedBytes: backgroundEncodedBytes,
      onShowCoordinatesChanged: onShowCoordinatesChanged,
      onUseRgbSwatchesChanged: onUseRgbSwatchesChanged,
      unavailableMessage: unavailableMessage,
      keyPrefix: 'heatmap-preview',
    );
  }
}

class _DifferenceTooltipSample {
  const _DifferenceTooltipSample({
    required this.anchor,
    required this.pixelX,
    required this.pixelY,
    required this.red,
    required this.green,
    required this.blue,
  });

  final Offset anchor;
  final int pixelX;
  final int pixelY;
  final int red;
  final int green;
  final int blue;

  String get redLabel => red.toString().padLeft(3);
  String get greenLabel => green.toString().padLeft(3);
  String get blueLabel => blue.toString().padLeft(3);

  String get _rgbLabel => 'R $redLabel G $greenLabel B $blueLabel';

  String label({required bool showCoordinates}) {
    if (!showCoordinates) {
      return _rgbLabel;
    }
    return 'x $pixelX, y $pixelY\n$_rgbLabel';
  }
}

class _DiffVisualizationPreview extends StatefulWidget {
  const _DiffVisualizationPreview({
    required this.retentionScopeKey,
    required this.frame,
    required this.fileName,
    required this.showCoordinates,
    required this.useRgbSwatches,
    required this.keyPrefix,
    this.backgroundPath,
    this.backgroundEncodedBytes,
    this.onShowCoordinatesChanged,
    this.onUseRgbSwatchesChanged,
    this.unavailableMessage = 'Unable to render preview.',
  }) : assert(
         (backgroundPath == null) || (backgroundEncodedBytes == null),
         'Specify either a background path or background bytes.',
       );

  final String retentionScopeKey;
  final AsyncValue<PreviewDifferenceFrame?> frame;
  final String fileName;
  final bool showCoordinates;
  final bool useRgbSwatches;
  final String keyPrefix;
  final String? backgroundPath;
  final Uint8List? backgroundEncodedBytes;
  final ValueChanged<bool>? onShowCoordinatesChanged;
  final ValueChanged<bool>? onUseRgbSwatchesChanged;
  final String unavailableMessage;

  @override
  State<_DiffVisualizationPreview> createState() =>
      _DiffVisualizationPreviewState();
}

class _DiffVisualizationPreviewState extends State<_DiffVisualizationPreview> {
  static const _tooltipDelay = Duration(seconds: 1);
  static const _tooltipOffset = Offset(12, 12);
  static const _rgbSwatchSlotWidth = 34.0;

  ui.Image? _retainedSourceImage;
  ui.Image? _retainedImage;
  RawImageResult? _retainedRawImage;
  Offset? _hoverViewportOffset;
  _DifferenceTooltipSample? _tooltipSample;
  Timer? _tooltipTimer;
  late final TransformationController _transformationController;

  bool get _supportsHover =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
    _syncRetainedFrame();
  }

  @override
  void didUpdateWidget(covariant _DiffVisualizationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retentionScopeKey != widget.retentionScopeKey) {
      _clearRetainedFrame();
      _transformationController.value = Matrix4.identity();
    }
    if (oldWidget.frame != widget.frame) {
      _resetTooltip(clearHover: false);
    }
    _syncRetainedFrame();
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    _transformationController.dispose();
    _clearRetainedFrame();
    super.dispose();
  }

  void _syncRetainedFrame() {
    final frame = widget.frame;
    if (frame case AsyncData(:final value)) {
      if (value == null) {
        _clearRetainedFrame();
        return;
      }
      if (!identical(value.image, _retainedSourceImage)) {
        _retainedImage?.dispose();
        _retainedSourceImage = value.image;
        _retainedImage = value.image.clone();
      }
      _retainedRawImage = value.rawImage;
    }
  }

  void _clearRetainedFrame() {
    _retainedSourceImage = null;
    _retainedImage?.dispose();
    _retainedImage = null;
    _retainedRawImage = null;
  }

  void _resetTooltip({bool clearHover = true}) {
    _tooltipTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      if (clearHover) {
        _hoverViewportOffset = null;
      }
      _tooltipSample = null;
    });
  }

  void _setHoverPosition(Offset position) {
    if (_hoverViewportOffset == position) {
      return;
    }
    _tooltipTimer?.cancel();
    setState(() {
      _hoverViewportOffset = position;
    });
  }

  void _scheduleTooltip({
    required Offset viewportOffset,
    required Size viewportSize,
    required RawImageResult rawImage,
  }) {
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer(_tooltipDelay, () {
      if (!mounted || _hoverViewportOffset != viewportOffset) {
        return;
      }
      final sample = _sampleAtViewportOffset(
        viewportOffset: viewportOffset,
        viewportSize: viewportSize,
        rawImage: rawImage,
      );
      if (!mounted || sample == null) {
        return;
      }
      setState(() {
        _tooltipSample = sample;
      });
    });
  }

  void _handleHover({
    required Offset viewportOffset,
    required Size viewportSize,
    required RawImageResult rawImage,
  }) {
    if (!_supportsHover) {
      return;
    }
    final sample = _sampleAtViewportOffset(
      viewportOffset: viewportOffset,
      viewportSize: viewportSize,
      rawImage: rawImage,
    );
    if (sample == null) {
      _resetTooltip();
      return;
    }
    if (_hoverViewportOffset == viewportOffset) {
      return;
    }
    if (_tooltipSample != null) {
      _tooltipTimer?.cancel();
      setState(() {
        _hoverViewportOffset = viewportOffset;
        _tooltipSample = sample;
      });
      return;
    }
    _setHoverPosition(viewportOffset);
    _scheduleTooltip(
      viewportOffset: viewportOffset,
      viewportSize: viewportSize,
      rawImage: rawImage,
    );
  }

  _DifferenceTooltipSample? _sampleAtViewportOffset({
    required Offset viewportOffset,
    required Size viewportSize,
    required RawImageResult rawImage,
  }) {
    final sceneOffset = _transformationController.toScene(viewportOffset);
    final imageRect = _containedImageRect(
      viewportSize,
      Size(rawImage.width.toDouble(), rawImage.height.toDouble()),
    );
    if (!imageRect.contains(sceneOffset)) {
      return null;
    }

    final normalizedX = (sceneOffset.dx - imageRect.left) / imageRect.width;
    final normalizedY = (sceneOffset.dy - imageRect.top) / imageRect.height;
    final pixelX = math.min(
      math.max((normalizedX * rawImage.width).floor(), 0),
      rawImage.width - 1,
    );
    final pixelY = math.min(
      math.max((normalizedY * rawImage.height).floor(), 0),
      rawImage.height - 1,
    );
    final byteIndex = (pixelY * rawImage.width + pixelX) * 4;
    if (byteIndex + 2 >= rawImage.rgbaBytes.length) {
      return null;
    }

    return _DifferenceTooltipSample(
      anchor: viewportOffset,
      pixelX: pixelX,
      pixelY: pixelY,
      red: rawImage.rgbaBytes[byteIndex],
      green: rawImage.rgbaBytes[byteIndex + 1],
      blue: rawImage.rgbaBytes[byteIndex + 2],
    );
  }

  Rect _containedImageRect(Size viewportSize, Size imageSize) {
    if (viewportSize.isEmpty || imageSize.isEmpty) {
      return Rect.zero;
    }
    final scale = math.min(
      viewportSize.width / imageSize.width,
      viewportSize.height / imageSize.height,
    );
    final fittedSize = Size(imageSize.width * scale, imageSize.height * scale);
    final left = (viewportSize.width - fittedSize.width) / 2;
    final top = (viewportSize.height - fittedSize.height) / 2;
    return Rect.fromLTWH(left, top, fittedSize.width, fittedSize.height);
  }

  Size _tooltipSize(BuildContext context, String measurementText) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final densityGap = theme.density.baseGap * scaling;
    final densityContentPadding = theme.density.baseContentPadding * scaling;
    final textPainter = TextPainter(
      text: TextSpan(text: measurementText, style: theme.typography.xSmall),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final horizontalPadding = (densityContentPadding + densityGap) * 1.5;
    final verticalPadding = densityGap * 1.5;
    return Size(
      textPainter.width + horizontalPadding,
      textPainter.height + verticalPadding,
    );
  }

  Widget _buildTooltipContent(
    BuildContext context,
    _DifferenceTooltipSample tooltip,
  ) {
    final numberStyle = TextStyle(
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    final rgbContent = widget.useRgbSwatches
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildRgbSwatchValue(
                key: ValueKey('${widget.keyPrefix}-tooltip-r-swatch'),
                color: const Color(0xFFFF3B30),
                value: tooltip.redLabel,
                textStyle: numberStyle,
              ),
              const SizedBox(width: 8),
              _buildRgbSwatchValue(
                key: ValueKey('${widget.keyPrefix}-tooltip-g-swatch'),
                color: const Color(0xFF34C759),
                value: tooltip.greenLabel,
                textStyle: numberStyle,
              ),
              const SizedBox(width: 8),
              _buildRgbSwatchValue(
                key: ValueKey('${widget.keyPrefix}-tooltip-b-swatch'),
                color: const Color(0xFF0A84FF),
                value: tooltip.blueLabel,
                textStyle: numberStyle,
              ),
            ],
          )
        : Text(tooltip._rgbLabel, style: numberStyle);

    if (!widget.showCoordinates) {
      return KeyedSubtree(
        key: ValueKey('${widget.keyPrefix}-tooltip'),
        child: rgbContent,
      );
    }

    return KeyedSubtree(
      key: ValueKey('${widget.keyPrefix}-tooltip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('x ${tooltip.pixelX}, y ${tooltip.pixelY}'),
          const SizedBox(height: 2),
          rgbContent,
        ],
      ),
    );
  }

  Widget _buildRgbSwatchValue({
    required Key key,
    required Color color,
    required String value,
    required TextStyle textStyle,
  }) {
    return SizedBox(
      key: key,
      width: _rgbSwatchSlotWidth,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Text(value, style: textStyle),
        ],
      ),
    );
  }

  Widget _buildImageViewport({
    required ui.Image image,
    required RawImageResult rawImage,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        final imageRect = _containedImageRect(
          viewportSize,
          Size(rawImage.width.toDouble(), rawImage.height.toDouble()),
        );
        final tooltip = _tooltipSample;
        final tooltipText = tooltip?.label(
          showCoordinates: widget.showCoordinates,
        );
        final tooltipMeasurementText = tooltip == null
            ? null
            : widget.useRgbSwatches
            ? widget.showCoordinates
                  ? 'x ${tooltip.pixelX}, y ${tooltip.pixelY}\n000 000 000'
                  : '000 000 000'
            : tooltipText;
        final tooltipSize = tooltipMeasurementText == null
            ? null
            : _tooltipSize(context, tooltipMeasurementText);
        final tooltipLeft = tooltip == null || tooltipSize == null
            ? null
            : ((tooltip.anchor.dx + _tooltipOffset.dx).clamp(
                0.0,
                math.max(viewportSize.width - tooltipSize.width, 0.0),
              )).toDouble();
        final tooltipTop = tooltip == null || tooltipSize == null
            ? null
            : ((tooltip.anchor.dy + _tooltipOffset.dy).clamp(
                0.0,
                math.max(viewportSize.height - tooltipSize.height, 0.0),
              )).toDouble();

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ContextMenu(
                items: [
                  MenuCheckbox(
                    key: const ValueKey(
                      'difference-tooltip-coordinates-toggle',
                    ),
                    value: widget.showCoordinates,
                    autoClose: false,
                    onChanged: widget.onShowCoordinatesChanged == null
                        ? null
                        : (context, value) {
                            widget.onShowCoordinatesChanged!(value);
                          },
                    child: const Text('Show coordinates'),
                  ),
                  MenuCheckbox(
                    key: const ValueKey('difference-tooltip-swatches-toggle'),
                    value: widget.useRgbSwatches,
                    autoClose: false,
                    onChanged: widget.onUseRgbSwatchesChanged == null
                        ? null
                        : (context, value) {
                            widget.onUseRgbSwatchesChanged!(value);
                          },
                    child: const Text('Use color swatches for RGB labels'),
                  ),
                ],
                child: Listener(
                  onPointerDown: (_) => _resetTooltip(),
                  onPointerSignal: (_) => _resetTooltip(),
                  child: MouseRegion(
                    key: ValueKey('${widget.keyPrefix}-region'),
                    onHover: (event) => _handleHover(
                      viewportOffset: event.localPosition,
                      viewportSize: viewportSize,
                      rawImage: rawImage,
                    ),
                    onExit: (_) => _resetTooltip(),
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      minScale: 0.5,
                      maxScale: 6,
                      onInteractionStart: (_) => _resetTooltip(),
                      onInteractionUpdate: (_) => _resetTooltip(),
                      child: SizedBox(
                        width: viewportSize.width,
                        height: viewportSize.height,
                        child: Center(
                          child: SizedBox(
                            width: imageRect.width,
                            height: imageRect.height,
                            child:
                                widget.backgroundPath != null ||
                                    widget.backgroundEncodedBytes != null
                                ? Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (widget.backgroundPath != null)
                                        Image.file(
                                          File(widget.backgroundPath!),
                                          fit: BoxFit.fill,
                                          gaplessPlayback: true,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                                return _ImageLoadError(
                                                  fileName: widget.fileName,
                                                );
                                              },
                                        )
                                      else
                                        Image.memory(
                                          widget.backgroundEncodedBytes!,
                                          fit: BoxFit.fill,
                                          gaplessPlayback: true,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                                return _PreviewUnavailable(
                                                  message:
                                                      widget.unavailableMessage,
                                                );
                                              },
                                        ),
                                      RawImage(image: image, fit: BoxFit.fill),
                                    ],
                                  )
                                : RawImage(image: image, fit: BoxFit.fill),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (tooltipText != null &&
                tooltipLeft != null &&
                tooltipTop != null)
              Positioned(
                left: tooltipLeft,
                top: tooltipTop,
                child: IgnorePointer(
                  child: TooltipContainer(
                    child: _buildTooltipContent(context, tooltip!),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    return frame.when(
      data: (resolvedFrame) {
        if (resolvedFrame == null) {
          return _PreviewUnavailable(message: widget.unavailableMessage);
        }
        return KeyedSubtree(
          key: ValueKey('${widget.keyPrefix}-ready'),
          child: _buildImageViewport(
            image: _retainedImage ?? resolvedFrame.image,
            rawImage: resolvedFrame.rawImage,
          ),
        );
      },
      loading: () {
        if (_retainedImage != null && _retainedRawImage != null) {
          return KeyedSubtree(
            key: ValueKey('${widget.keyPrefix}-ready'),
            child: _buildImageViewport(
              image: _retainedImage!,
              rawImage: _retainedRawImage!,
            ),
          );
        }
        return Center(
          key: ValueKey('${widget.keyPrefix}-loading'),
          child: CircularProgressIndicator(),
        );
      },
      error: (_, _) => _PreviewUnavailable(message: widget.unavailableMessage),
    );
  }
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.imageOff,
            size: 32,
            color: theme.colorScheme.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _FolderCollage extends StatelessWidget {
  const _FolderCollage({
    required this.files,
    required this.onOpenFile,
    required this.onRevealFile,
  });

  final List<OpenedImageFile> files;
  final ValueChanged<String> onOpenFile;
  final Future<void> Function(String) onRevealFile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final crossAxisCount = math.max(
          1,
          math.min(4, (constraints.maxWidth / 180).floor()),
        );
        final totalSpacing = spacing * (crossAxisCount - 1);
        final tileWidth =
            (constraints.maxWidth - totalSpacing) / crossAxisCount;

        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: 0.95,
          ),
          itemCount: files.length,
          itemBuilder: (context, index) {
            final file = files[index];
            return _FolderCollageTile(
              file: file,
              tileWidth: tileWidth,
              onPressed: () => onOpenFile(file.path),
              onRevealFile: () => onRevealFile(file.path),
            );
          },
        );
      },
    );
  }
}

class _FolderCollageTile extends StatelessWidget {
  const _FolderCollageTile({
    required this.file,
    required this.tileWidth,
    required this.onPressed,
    required this.onRevealFile,
  });

  final OpenedImageFile file;
  final double tileWidth;
  final VoidCallback onPressed;
  final Future<void> Function() onRevealFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = math.max(1, (tileWidth * devicePixelRatio).round());
    final showInFileManagerLabel = _showInFileManagerLabel();
    final tile = GestureDetector(
      key: ValueKey('folder-collage-tile-${file.path}'),
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Card(
        padding: EdgeInsets.zero,
        borderRadius: theme.borderRadiusLg,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: theme.colorScheme.secondary,
                alignment: Alignment.center,
                child: Image.file(
                  File(file.path),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  cacheWidth: cacheWidth,
                  errorBuilder: (context, error, stackTrace) {
                    return Icon(
                      LucideIcons.imageOff,
                      size: 24,
                      color: theme.colorScheme.mutedForeground,
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      FileOpenController.fileNameOf(file.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).small().medium(),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _fileSizeLabel(file) ?? 'Unknown',
                    textAlign: TextAlign.right,
                  ).xSmall().muted(),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: showInFileManagerLabel == null
          ? tile
          : ContextMenu(
              items: [
                MenuButton(
                  onPressed: (context) {
                    unawaited(onRevealFile());
                  },
                  child: Text(showInFileManagerLabel),
                ),
              ],
              child: tile,
            ),
    );
  }
}

class _ImageLoadError extends StatelessWidget {
  const _ImageLoadError({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.imageOff,
            size: 32,
            color: theme.colorScheme.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            'Unable to load $fileName.',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _PreviewMetaItem extends StatelessWidget {
  const _PreviewMetaItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text('$label $value').xSmall().muted();
  }
}

class _PreviewDisplayModeRow extends ConsumerWidget {
  const _PreviewDisplayModeRow({
    required this.filePath,
    required this.displayMode,
    required this.hasOptimizedPreview,
    required this.supportsDifference,
    required this.differenceUnavailableTooltip,
    required this.optimizedArtifactId,
    required this.onSelectOriginal,
    required this.onSelectOptimized,
    required this.onSelectDifference,
    required this.onSelectHeatmap,
  });

  final String filePath;
  final PreviewDisplayMode displayMode;
  final bool hasOptimizedPreview;
  final bool supportsDifference;
  final String? differenceUnavailableTooltip;
  final String? optimizedArtifactId;
  final VoidCallback onSelectOriginal;
  final VoidCallback onSelectOptimized;
  final VoidCallback onSelectDifference;
  final VoidCallback onSelectHeatmap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(currentPreviewProvider);
    final differenceFrame = ref.watch(currentPreviewDifferenceFrameProvider);
    final heatmapFrame = ref.watch(currentPreviewHeatmapFrameProvider);
    final analyzeState = ref.watch(analyzeRunControllerProvider);
    final analyzeAvailability = ref.watch(analyzeAvailabilityProvider);
    final analyzeController = ref.read(analyzeRunControllerProvider.notifier);
    final settings = ref.watch(appSettingsProvider).asData?.value;
    final heatmapPalette = ref.watch(heatmapPaletteProvider);
    final heatmapVisibilityMode = ref.watch(heatmapVisibilityModeProvider);
    final optimizedLoading = preview.isLoading && !hasOptimizedPreview;
    final differenceLoading =
        displayMode == PreviewDisplayMode.difference &&
        differenceFrame.isLoading;
    final heatmapLoading =
        displayMode == PreviewDisplayMode.heatmap && heatmapFrame.isLoading;
    final analyzeTooltip =
        !analyzeAvailability.isEnabled &&
            settings != null &&
            settings.compressionMethod == CompressionMethod.lossless &&
            !settings.showsQualityControl
        ? 'Not available for lossless formats'
        : analyzeAvailability.reason ??
              'Visualize the quality/efficiency tradeoff';

    return Row(
      key: const ValueKey('preview-display-mode-row'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _PreviewDisplayModeButton(
                shortcutKey: LogicalKeyboardKey.keyR,
                label: 'Original',
                selected: displayMode == PreviewDisplayMode.original,
                enabled: true,
                onPressed: onSelectOriginal,
              ),
              _PreviewDisplayModeButton(
                shortcutKey: LogicalKeyboardKey.keyE,
                label: 'Optimized',
                selected: displayMode == PreviewDisplayMode.optimized,
                enabled: hasOptimizedPreview,
                tooltip: optimizedLoading ? 'Optimizing image...' : null,
                loading: optimizedLoading,
                onPressed: onSelectOptimized,
              ),
              _PreviewDisplayModeButton(
                shortcutKey: LogicalKeyboardKey.keyD,
                label: 'Difference',
                selected: displayMode == PreviewDisplayMode.difference,
                enabled: supportsDifference,
                tooltip: differenceUnavailableTooltip,
                loading: differenceLoading,
                onPressed: onSelectDifference,
              ),
              _PreviewDisplayModeButton(
                shortcutKey: LogicalKeyboardKey.keyH,
                label: 'Heatmap',
                selected: displayMode == PreviewDisplayMode.heatmap,
                enabled: supportsDifference,
                tooltip: differenceUnavailableTooltip,
                loading: heatmapLoading,
                onPressed: onSelectHeatmap,
              ),
              if (displayMode == PreviewDisplayMode.heatmap) ...[
                const SizedBox(width: 4),
                _HeatmapPaletteSelector(
                  selectedPalette: heatmapPalette,
                  onSelected: (nextPalette) {
                    ref
                        .read(heatmapPaletteProvider.notifier)
                        .select(nextPalette);
                  },
                ),
                _HeatmapVisibilityCheckbox(
                  mode: heatmapVisibilityMode,
                  onChanged: (nextMode) {
                    ref
                        .read(heatmapVisibilityModeProvider.notifier)
                        .select(nextMode);
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          waitDuration: const Duration(milliseconds: 250),
          showDuration: const Duration(milliseconds: 120),
          tooltip: (context) => TooltipContainer(child: Text(analyzeTooltip)),
          child: analyzeState.isCancelRequested
              ? OutlineButton(
                  alignment: Alignment.center,
                  onPressed: null,
                  child: const Text('Canceling...'),
                )
              : analyzeState.isRunning
              ? Button.destructive(
                  alignment: Alignment.center,
                  onPressed: analyzeController.cancelAnalyze,
                  child: const Text('Cancel'),
                )
              : OutlineButton(
                  alignment: Alignment.center,
                  onPressed: analyzeAvailability.isEnabled
                      ? analyzeController.startAnalyze
                      : null,
                  child: const Text('Analyze'),
                ),
        ),
      ],
    );
  }
}

class _HeatmapPaletteSelector extends StatelessWidget {
  const _HeatmapPaletteSelector({
    required this.selectedPalette,
    required this.onSelected,
  });

  final HeatmapPalette selectedPalette;
  final ValueChanged<HeatmapPalette> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const ValueKey('heatmap-palette-selector'),
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _HeatmapPaletteButton(
          label: 'Turbo',
          selected: selectedPalette == HeatmapPalette.turbo,
          onPressed: () => onSelected(HeatmapPalette.turbo),
        ),
        _HeatmapPaletteButton(
          label: 'Inferno',
          selected: selectedPalette == HeatmapPalette.inferno,
          onPressed: () => onSelected(HeatmapPalette.inferno),
        ),
        _HeatmapPaletteButton(
          label: 'Viridis',
          selected: selectedPalette == HeatmapPalette.viridis,
          onPressed: () => onSelected(HeatmapPalette.viridis),
        ),
      ],
    );
  }
}

class _HeatmapPaletteButton extends StatelessWidget {
  const _HeatmapPaletteButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey('heatmap-palette-$label'),
      height: 30,
      child: selected
          ? PrimaryButton(
              onPressed: onPressed,
              child: Text(label).xSmall().medium(),
            )
          : OutlineButton(
              onPressed: onPressed,
              child: Text(label).xSmall().medium(),
            ),
    );
  }
}

class _HeatmapVisibilityCheckbox extends StatelessWidget {
  const _HeatmapVisibilityCheckbox({
    required this.mode,
    required this.onChanged,
  });

  final HeatmapVisibilityMode mode;
  final ValueChanged<HeatmapVisibilityMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('heatmap-visibility-checkbox'),
      child: Checkbox(
        state: switch (mode) {
          HeatmapVisibilityMode.overlay => CheckboxState.unchecked,
          HeatmapVisibilityMode.nonzero => CheckboxState.indeterminate,
          HeatmapVisibilityMode.opaque => CheckboxState.checked,
        },
        tristate: true,
        onChanged: (value) {
          onChanged(switch (value) {
            CheckboxState.unchecked => HeatmapVisibilityMode.overlay,
            CheckboxState.indeterminate => HeatmapVisibilityMode.nonzero,
            CheckboxState.checked => HeatmapVisibilityMode.opaque,
          });
        },
        trailing: Text(_heatmapVisibilityLabel(mode)).xSmall().medium(),
      ),
    );
  }
}

String _heatmapVisibilityLabel(HeatmapVisibilityMode mode) {
  return switch (mode) {
    HeatmapVisibilityMode.overlay => 'Overlay',
    HeatmapVisibilityMode.nonzero => 'Nonzero',
    HeatmapVisibilityMode.opaque => 'Opaque',
  };
}

class _PreviewDisplayModeButton extends StatelessWidget {
  const _PreviewDisplayModeButton({
    required this.shortcutKey,
    required this.label,
    required this.selected,
    required this.enabled,
    this.tooltip,
    this.loading = false,
    required this.onPressed,
  });

  final LogicalKeyboardKey shortcutKey;
  final String label;
  final bool selected;
  final bool enabled;
  final String? tooltip;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final buttonChild = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading) ...[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        _PreviewModeShortcutKey(shortcutKey: shortcutKey),
        const SizedBox(width: 8),
        Text(label).xSmall().medium(),
      ],
    );
    final button = SizedBox(
      key: ValueKey('preview-mode-$label'),
      height: 30,
      child: selected
          ? PrimaryButton(
              onPressed: enabled ? onPressed : null,
              child: buttonChild,
            )
          : OutlineButton(
              onPressed: enabled ? onPressed : null,
              child: buttonChild,
            ),
    );

    if (tooltip == null) {
      return button;
    }

    return Tooltip(
      waitDuration: const Duration(milliseconds: 250),
      showDuration: const Duration(milliseconds: 120),
      tooltip: (context) => TooltipContainer(child: Text(tooltip!)),
      child: button,
    );
  }
}

class _PreviewModeShortcutKey extends StatelessWidget {
  const _PreviewModeShortcutKey({required this.shortcutKey});

  final LogicalKeyboardKey shortcutKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.7),
        borderRadius: theme.borderRadiusSm,
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Text(
        shortcutKey.keyLabel.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.mutedForeground,
          height: 1,
        ),
      ),
    );
  }
}

class _ExplorerSidebar extends StatelessWidget {
  const _ExplorerSidebar({required this.controller});

  final FileOpenController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = _buildExplorerNodes(controller);

    return Card(
      padding: EdgeInsets.zero,
      borderRadius: theme.borderRadiusXl,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(
              'Files',
              style: TextStyle(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ).xSmall(),
          ),
          // const Divider(),
          Expanded(
            child: TreeView<_ExplorerEntry>(
              nodes: nodes,
              branchLine: BranchLine.none,
              expandIcon: false,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              builder: (context, node) {
                final entry = node.data;
                final item = TreeItemView(
                  key: ValueKey('explorer-item-${entry.path}'),
                  leading: entry.isDirectory
                      ? Icon(
                          LucideIcons.folder,
                          size: 16,
                          color: theme.colorScheme.mutedForeground,
                        )
                      : null,
                  trailing: entry.sizeLabel == null
                      ? null
                      : Text(entry.sizeLabel!).small().muted(),
                  expandable: false,
                  onPressed: entry.isDirectory
                      ? () => controller.showFolder(entry.path)
                      : () => controller.showPath(entry.path),
                  child: Text(entry.label).small().mediumIf(entry.isDirectory),
                );
                final showInFileManagerLabel = _showInFileManagerLabel();
                if (showInFileManagerLabel == null) {
                  return item;
                }

                return ContextMenu(
                  items: [
                    MenuButton(
                      onPressed: (context) {
                        unawaited(controller.showInFileManager(entry.path));
                      },
                      child: Text(showInFileManagerLabel),
                    ),
                  ],
                  child: item,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<TreeNode<_ExplorerEntry>> _buildExplorerNodes(
    FileOpenController controller,
  ) {
    final selection = controller.explorerSelection;
    final showFolderSize = controller.sessionFiles.length > 1;
    final groups = <String, List<OpenedImageFile>>{};
    for (final file in controller.sessionFiles) {
      final directory = FileOpenController.directoryOf(file.path);
      groups.putIfAbsent(directory, () => <OpenedImageFile>[]).add(file);
    }

    return groups.entries
        .map((entry) {
          final folderSizeLabel = showFolderSize
              ? _folderSizeLabel(entry.value)
              : null;
          return TreeItem<_ExplorerEntry>(
            data: _ExplorerEntry.directory(
              label: FileOpenController.directoryLabelOf(entry.key),
              path: entry.key,
              sizeLabel: folderSizeLabel,
            ),
            expanded: true,
            selected:
                selection?.type == ExplorerSelectionType.folder &&
                selection?.path == entry.key,
            children: entry.value
                .map(
                  (file) => TreeItem<_ExplorerEntry>(
                    data: _ExplorerEntry.file(
                      label: FileOpenController.fileNameOf(file.path),
                      path: file.path,
                      sizeLabel: _fileSizeLabel(file),
                    ),
                    selected:
                        selection?.type == ExplorerSelectionType.file &&
                        selection?.path == file.path,
                  ),
                )
                .toList(growable: false),
          );
        })
        .toList(growable: false);
  }
}

class _ExplorerEntry {
  const _ExplorerEntry._({
    required this.label,
    required this.path,
    required this.sizeLabel,
    required this.isDirectory,
  });

  const _ExplorerEntry.directory({
    required String label,
    required String path,
    required String? sizeLabel,
  }) : this._(
         label: label,
         path: path,
         sizeLabel: sizeLabel,
         isDirectory: true,
       );

  const _ExplorerEntry.file({
    required String label,
    required String path,
    required String? sizeLabel,
  }) : this._(
         label: label,
         path: path,
         sizeLabel: sizeLabel,
         isDirectory: false,
       );

  final String label;
  final String path;
  final String? sizeLabel;
  final bool isDirectory;
}

class _SettingsSidebar extends ConsumerWidget {
  const _SettingsSidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);
    final fileController = ref.watch(fileOpenControllerProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final runState = ref.watch(optimizationRunControllerProvider);
    final analyzeState = ref.watch(analyzeRunControllerProvider);
    final controlsLocked = runState.isRunning || analyzeState.isRunning;
    final showAnalyzePanel =
        analyzeState.isRunning ||
        analyzeState.samples.isNotEmpty ||
        analyzeState.globalError != null;

    Widget buildSettingsContent(
      AppSettings settings, {
      required bool includeBottomSectionsInScroll,
    }) {
      final transparencyWarning = _transparencyWarningText(
        settings: settings,
        file: fileController.isFolderSelected
            ? null
            : fileController.currentFile,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SettingsModeSwitcher(
            settings: settings,
            controlsLocked: controlsLocked,
            notifier: notifier,
          ),
          const SizedBox(height: 12),
          if (settings.showsQualityControl) ...[
            _SettingsLabel('Quality'),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('0').xSmall().muted(),
                const Spacer(),
                Text(_qualityValueLabel(settings)).xSmall().medium().muted(),
              ],
            ),
            const SizedBox(height: 8),
            _HoverValueSlider(
              key: const ValueKey('quality-slider'),
              value: settings.quality.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              hoverEnabled: !controlsLocked,
              onChanged: controlsLocked
                  ? null
                  : (value) {
                      notifier.setQuality(value.round());
                    },
            ),
            const SizedBox(height: 12),
          ],
          if (transparencyWarning case final warning?) ...[
            _SettingsWarningBlock(
              icon: LucideIcons.triangleAlert,
              message: warning,
            ),
            const SizedBox(height: 12),
          ],
          if (runState.globalError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(error).xSmall().muted(),
            ),
          if (includeBottomSectionsInScroll) ...[
            const SizedBox(height: 12),
            _StorageCollapsible(
              settings: settings,
              controlsLocked: controlsLocked,
            ),
            const SizedBox(height: 12),
            const _MetadataCollapsible(),
          ],
        ],
      );
    }

    return Card(
      padding: EdgeInsets.zero,
      borderRadius: theme.borderRadiusXl,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      color: theme.colorScheme.mutedForeground,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ).xSmall(),
                ),
                settings.when(
                  data: (settings) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Advanced',
                          style: TextStyle(
                            color: theme.colorScheme.mutedForeground,
                          ),
                        ).xSmall(),
                        const SizedBox(width: 8),
                        Switch(
                          value: settings.advancedMode,
                          onChanged: controlsLocked
                              ? null
                              : notifier.setAdvancedMode,
                        ),
                      ],
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final foldBottomSectionsIntoScroll =
                    showAnalyzePanel &&
                    constraints.maxHeight <
                        _settingsBottomSectionsFoldThreshold;

                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('settings-scroll-view'),
                          child: settings.when(
                            data: (settings) => buildSettingsContent(
                              settings,
                              includeBottomSectionsInScroll:
                                  foldBottomSectionsIntoScroll,
                            ),
                            loading: () => Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: const Text('Loading settings').small(),
                              ),
                            ),
                            error: (_, _) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: const Text(
                                  'Unable to load settings',
                                ).small().muted(),
                              );
                            },
                          ),
                        ),
                      ),
                      if (!foldBottomSectionsIntoScroll) ...[
                        settings.when(
                          data: (settings) => Column(
                            children: [
                              const SizedBox(height: 12),
                              _StorageCollapsible(
                                settings: settings,
                                controlsLocked: controlsLocked,
                              ),
                            ],
                          ),
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 12),
                        const _MetadataCollapsible(),
                      ],
                      if (showAnalyzePanel) ...[
                        const SizedBox(height: 12),
                        Container(height: 1, color: theme.colorScheme.border),
                        const SizedBox(height: 12),
                        Expanded(child: _AnalyzePanel(state: analyzeState)),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsModeSwitcher extends StatelessWidget {
  const _SettingsModeSwitcher({
    required this.settings,
    required this.controlsLocked,
    required this.notifier,
  });

  final AppSettings settings;
  final bool controlsLocked;
  final AppSettingsController notifier;

  @override
  Widget build(BuildContext context) {
    final activeKey = settings.advancedMode
        ? const ValueKey('advanced-settings-mode')
        : const ValueKey('basic-settings-mode');

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final isIncoming = child.key == activeKey;
          final enteringAdvanced = settings.advancedMode;
          final enterOffset = enteringAdvanced
              ? const Offset(0.04, 0)
              : const Offset(-0.04, 0);
          final exitOffset = enteringAdvanced
              ? const Offset(-0.04, 0)
              : const Offset(0.04, 0);
          final offsetAnimation = isIncoming
              ? Tween<Offset>(
                  begin: enterOffset,
                  end: Offset.zero,
                ).animate(animation)
              : Tween<Offset>(
                  begin: exitOffset,
                  end: Offset.zero,
                ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offsetAnimation, child: child),
          );
        },
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              // ignore: use_null_aware_elements
              if (currentChild != null) currentChild,
            ],
          );
        },
        child: settings.advancedMode
            ? _AdvancedSettingsModeSection(
                key: activeKey,
                settings: settings,
                controlsLocked: controlsLocked,
                notifier: notifier,
              )
            : _BasicSettingsModeSection(
                key: activeKey,
                settings: settings,
                controlsLocked: controlsLocked,
                notifier: notifier,
              ),
      ),
    );
  }
}

class _HoverValueSlider extends StatefulWidget {
  const _HoverValueSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.hoverEnabled,
    this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool hoverEnabled;
  final ValueChanged<double>? onChanged;

  @override
  State<_HoverValueSlider> createState() => _HoverValueSliderState();
}

class _HoverValueSliderState extends State<_HoverValueSlider> {
  static const _labelGap = 6.0;
  static const _showDelay = Duration(milliseconds: 500);
  static const _showDuration = Duration(milliseconds: 200);

  double? _hoverDx;
  bool _dragging = false;
  bool _labelVisible = false;
  Timer? _showLabelTimer;

  bool get _supportsHover =>
      widget.hoverEnabled &&
      widget.onChanged != null &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  ValueChanged<SliderValue>? get _sliderOnChanged {
    final onChanged = widget.onChanged;
    if (onChanged == null) {
      return null;
    }
    return (value) => onChanged(value.value);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsHover) {
      return Slider(
        value: SliderValue.single(widget.value),
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        onChanged: _sliderOnChanged,
      );
    }

    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final trackInset = theme.density.baseGap * scaling * 0.5;
    final sliderHeight = 16 * scaling;
    final reservedLabelHeight = _hoverLabelSize(
      context,
      widget.value.round().toString(),
    ).height;

    return SizedBox(
      height: sliderHeight + _labelGap + reservedLabelHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final range = math.max(widget.max - widget.min, 0.0001);
          final trackWidth = math.max(
            constraints.maxWidth - trackInset * 2,
            1.0,
          );
          final activeValue = _dragging
              ? widget.value
              : _hoverDx == null
              ? null
              : _valueFromDx(
                  _hoverDx!,
                  trackInset: trackInset,
                  range: range,
                  trackWidth: trackWidth,
                );
          final labelCenterX = _dragging
              ? _dxForValue(
                  widget.value,
                  trackInset: trackInset,
                  range: range,
                  trackWidth: trackWidth,
                )
              : _hoverDx;
          final showLabel = activeValue != null && (_dragging || _labelVisible);
          final labelText = activeValue?.round().toString();
          final labelSize = labelText == null
              ? null
              : _hoverLabelSize(context, labelText);
          final labelWidth = labelSize?.width;
          final labelLeft = labelCenterX == null
              ? null
              : ((labelCenterX - labelWidth! / 2).clamp(
                  0.0,
                  math.max(constraints.maxWidth - labelWidth, 0.0),
                )).toDouble();

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                bottom: reservedLabelHeight + _labelGap,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerHover: (event) =>
                      _setHoverDx(event.localPosition.dx),
                  onPointerMove: (event) {
                    if (!_dragging) {
                      return;
                    }
                    _setHoverDx(event.localPosition.dx);
                  },
                  onPointerDown: (event) => _setHoverDx(event.localPosition.dx),
                  onPointerUp: (_) {
                    if (!_dragging) {
                      return;
                    }
                    _setDragging(false);
                  },
                  onPointerCancel: (_) {
                    if (!_dragging) {
                      return;
                    }
                    _resetHoverState();
                  },
                  child: MouseRegion(
                    onExit: (_) {
                      if (_dragging) {
                        return;
                      }
                      _clearHoverDx();
                    },
                    child: Slider(
                      value: SliderValue.single(widget.value),
                      min: widget.min,
                      max: widget.max,
                      divisions: widget.divisions,
                      onChangeStart: (_) => _setDragging(true),
                      onChangeEnd: (_) => _setDragging(false),
                      onChanged: _sliderOnChanged,
                    ),
                  ),
                ),
              ),
              if (labelText != null && labelLeft != null && labelSize != null)
                Positioned(
                  left: labelLeft,
                  top: sliderHeight + _labelGap,
                  child: IgnorePointer(
                    child: AnimatedSlide(
                      duration: _showDuration,
                      curve: Curves.easeOutCubic,
                      offset: showLabel ? Offset.zero : const Offset(0, -0.12),
                      child: AnimatedOpacity(
                        key: const ValueKey('quality-slider-hover-opacity'),
                        duration: _showDuration,
                        curve: Curves.easeOutCubic,
                        opacity: showLabel ? 1 : 0,
                        child: TooltipContainer(
                          child: Text(
                            labelText,
                            key: const ValueKey('quality-slider-hover-value'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _showLabelTimer?.cancel();
    super.dispose();
  }

  double _dxForValue(
    double value, {
    required double trackInset,
    required double range,
    required double trackWidth,
  }) {
    final normalized = ((value - widget.min) / range).clamp(0.0, 1.0);
    return trackInset + normalized * trackWidth;
  }

  void _setHoverDx(double dx) {
    if (_hoverDx == dx) {
      return;
    }
    setState(() {
      _hoverDx = dx;
    });
    if (_dragging) {
      _setLabelVisible(true);
      return;
    }
    _scheduleLabelShow();
  }

  void _clearHoverDx() {
    _showLabelTimer?.cancel();
    if (_hoverDx == null) {
      _setLabelVisible(false);
      return;
    }
    setState(() {
      _hoverDx = null;
      _labelVisible = false;
    });
  }

  void _setDragging(bool dragging) {
    _showLabelTimer?.cancel();
    if (_dragging == dragging) {
      if (dragging) {
        _setLabelVisible(true);
      }
      return;
    }
    setState(() {
      _dragging = dragging;
      if (dragging) {
        _labelVisible = true;
      }
    });
  }

  void _resetHoverState() {
    _showLabelTimer?.cancel();
    if (!_dragging && _hoverDx == null) {
      return;
    }
    setState(() {
      _dragging = false;
      _hoverDx = null;
      _labelVisible = false;
    });
  }

  void _scheduleLabelShow() {
    if (_labelVisible) {
      return;
    }
    _showLabelTimer?.cancel();
    _showLabelTimer = Timer(_showDelay, () {
      if (!mounted || _dragging || _hoverDx == null) {
        return;
      }
      _setLabelVisible(true);
    });
  }

  void _setLabelVisible(bool visible) {
    if (_labelVisible == visible) {
      return;
    }
    setState(() {
      _labelVisible = visible;
    });
  }

  Size _hoverLabelSize(BuildContext context, String text) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final densityGap = theme.density.baseGap * scaling;
    final densityContentPadding = theme.density.baseContentPadding * scaling;
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: theme.typography.xSmall),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final horizontalPadding = (densityContentPadding + densityGap) * 1.5;
    final verticalPadding = densityGap * 1.5;
    return Size(
      textPainter.width + horizontalPadding,
      textPainter.height + verticalPadding,
    );
  }

  double _valueFromDx(
    double dx, {
    required double trackInset,
    required double range,
    required double trackWidth,
  }) {
    final normalized = ((dx - trackInset) / trackWidth).clamp(0.0, 1.0);
    if (widget.divisions == null || widget.divisions! <= 0) {
      return widget.min + normalized * range;
    }
    final snapped =
        (normalized * widget.divisions!).round() / widget.divisions!;
    return widget.min + snapped * range;
  }
}

class _MetadataCollapsible extends ConsumerStatefulWidget {
  const _MetadataCollapsible();

  @override
  ConsumerState<_MetadataCollapsible> createState() =>
      _MetadataCollapsibleState();
}

class _MetadataCollapsibleState extends ConsumerState<_MetadataCollapsible> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider).asData?.value;
    final notifier = ref.read(appSettingsProvider.notifier);
    final runState = ref.watch(optimizationRunControllerProvider);
    final analyzeState = ref.watch(analyzeRunControllerProvider);
    final controlsLocked = runState.isRunning || analyzeState.isRunning;

    Widget option({
      required Key key,
      required String label,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Checkbox(
          key: key,
          state: value ? CheckboxState.checked : CheckboxState.unchecked,
          onChanged: controlsLocked
              ? null
              : (next) {
                  onChanged(next == CheckboxState.checked);
                },
          trailing: Expanded(
            child: Text(
              label,
              style: TextStyle(color: theme.colorScheme.mutedForeground),
            ).small(),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              children: [
                Expanded(child: const Text('Metadata').small().medium()),
                GhostButton(
                  key: const ValueKey('metadata-collapsible-toggle'),
                  onPressed: () {
                    setState(() {
                      _isExpanded = !_isExpanded;
                    });
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Icon(
                      _isExpanded ? Icons.remove : Icons.add,
                      key: ValueKey<bool>(_isExpanded),
                    ).iconXSmall(),
                  ),
                ),
              ],
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: _isExpanded
                    ? const BoxConstraints()
                    : const BoxConstraints(maxHeight: 0),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: settings == null
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            option(
                              key: const ValueKey(
                                'metadata-preserve-original-date',
                              ),
                              label: 'Preserve original date',
                              value: settings.preserveOriginalDate,
                              onChanged: notifier.setPreserveOriginalDate,
                            ),
                            option(
                              key: const ValueKey(
                                'metadata-preserve-color-profile',
                              ),
                              label: 'Preserve color profile',
                              value: settings.preserveColorProfile,
                              onChanged: notifier.setPreserveColorProfile,
                            ),
                            option(
                              key: const ValueKey('metadata-preserve-exif'),
                              label: 'Preserve camera info (EXIF)',
                              value: settings.preserveExif,
                              onChanged: notifier.setPreserveExif,
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCollapsible extends ConsumerStatefulWidget {
  const _StorageCollapsible({
    required this.settings,
    required this.controlsLocked,
  });

  final AppSettings settings;
  final bool controlsLocked;

  @override
  ConsumerState<_StorageCollapsible> createState() =>
      _StorageCollapsibleState();
}

class _StorageCollapsibleState extends ConsumerState<_StorageCollapsible> {
  bool _isExpanded = false;
  bool _isPickingFolder = false;

  Future<void> _handleSameFolderSelection() async {
    if (widget.controlsLocked) {
      return;
    }
    await ref
        .read(appSettingsProvider.notifier)
        .setStorageDestinationMode(StorageDestinationMode.sameFolder);
  }

  Future<void> _handleDifferentLocationSelection({
    required bool forcePicker,
  }) async {
    if (widget.controlsLocked || _isPickingFolder) {
      return;
    }

    final currentPath = widget.settings.differentLocationPath;
    final needsPicker =
        forcePicker ||
        currentPath == null ||
        currentPath.isEmpty ||
        widget.settings.storageDestinationMode !=
            StorageDestinationMode.differentLocation;
    if (!needsPicker) {
      return;
    }

    setState(() {
      _isPickingFolder = true;
    });
    final pickedPath = await ref
        .read(fileOpenControllerProvider)
        .pickStorageFolder();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPickingFolder = false;
    });
    if (pickedPath == null || pickedPath.isEmpty) {
      return;
    }

    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.setDifferentLocationPath(pickedPath);
    await notifier.setStorageDestinationMode(
      StorageDestinationMode.differentLocation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(appSettingsProvider.notifier);
    final currentFile = ref.watch(fileOpenControllerProvider).currentFile;
    final primarySameFolderLabel =
        currentFile != null &&
            currentFile.metadata.format !=
                codecIdOf(widget.settings.effectiveCodec)
        ? 'Remove original'
        : 'Overwrite';

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              children: [
                Expanded(child: const Text('Storage').small().medium()),
                GhostButton(
                  onPressed: () {
                    setState(() {
                      _isExpanded = !_isExpanded;
                    });
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Icon(
                      _isExpanded ? Icons.remove : Icons.add,
                      key: ValueKey<bool>(_isExpanded),
                    ).iconXSmall(),
                  ),
                ),
              ],
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: _isExpanded
                    ? const BoxConstraints()
                    : const BoxConstraints(maxHeight: 0),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final cardWidth = (constraints.maxWidth - 8) / 2;
                          return ComponentTheme(
                            data: const RadioCardTheme(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            child: RadioGroup<StorageDestinationMode>(
                              value: widget.settings.storageDestinationMode,
                              onChanged: widget.controlsLocked ? null : (_) {},
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  SizedBox(
                                    width: cardWidth,
                                    child: _StorageDestinationCard(
                                      value: StorageDestinationMode.sameFolder,
                                      enabled: !widget.controlsLocked,
                                      onTap: _handleSameFolderSelection,
                                      child: const _ChoiceCard(
                                        title: 'Same folder',
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    child: _StorageDestinationCard(
                                      value: StorageDestinationMode
                                          .differentLocation,
                                      enabled:
                                          !widget.controlsLocked &&
                                          !_isPickingFolder,
                                      onTap: () =>
                                          _handleDifferentLocationSelection(
                                            forcePicker:
                                                widget
                                                    .settings
                                                    .storageDestinationMode ==
                                                StorageDestinationMode
                                                    .differentLocation,
                                          ),
                                      child: _ChoiceCard(
                                        title: _isPickingFolder
                                            ? 'Choosing...'
                                            : 'Different location',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      if (widget.settings.storageDestinationMode ==
                          StorageDestinationMode.sameFolder) ...[
                        const SizedBox(height: 10),
                        RadioGroup<SameFolderAction>(
                          value: widget.settings.sameFolderAction,
                          onChanged: widget.controlsLocked
                              ? null
                              : notifier.setSameFolderAction,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RadioItem<SameFolderAction>(
                                value: SameFolderAction.replaceSource,
                                enabled: !widget.controlsLocked,
                                trailing: Text(primarySameFolderLabel).small(),
                              ),
                              const SizedBox(height: 8),
                              RadioItem<SameFolderAction>(
                                value: SameFolderAction.keepSource,
                                enabled: !widget.controlsLocked,
                                trailing: const Text('Keep original').small(),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (widget.settings.storageDestinationMode ==
                          StorageDestinationMode.differentLocation) ...[
                        if (widget.settings.differentLocationPath
                            case final path?)
                          Padding(
                            padding: const EdgeInsets.only(top: 10, left: 4),
                            child: Text(
                              path,
                              style: TextStyle(
                                color: theme.colorScheme.mutedForeground,
                              ),
                            ).xSmall(),
                          ),
                        const SizedBox(height: 10),
                        Checkbox(
                          state: widget.settings.preserveFolderStructure
                              ? CheckboxState.checked
                              : CheckboxState.unchecked,
                          onChanged: widget.controlsLocked
                              ? null
                              : (value) {
                                  notifier.setPreserveFolderStructure(
                                    value == CheckboxState.checked,
                                  );
                                },
                          trailing: Expanded(
                            child: Text(
                              'Preserve folder structure',
                              style: TextStyle(
                                color: theme.colorScheme.mutedForeground,
                              ),
                            ).small(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvancedSettingsModeSection extends StatelessWidget {
  const _AdvancedSettingsModeSection({
    super.key,
    required this.settings,
    required this.controlsLocked,
    required this.notifier,
  });

  final AppSettings settings;
  final bool controlsLocked;
  final AppSettingsController notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SettingsLabel('Codec'),
        const SizedBox(height: 8),
        RadioGroup<PreferredCodec>(
          value: settings.preferredCodec,
          onChanged: controlsLocked ? null : notifier.setPreferredCodec,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: PreferredCodec.values
                    .map(
                      (codec) => SizedBox(
                        width: cardWidth,
                        child: RadioCard<PreferredCodec>(
                          value: codec,
                          child: _ChoiceCard(title: codecLabel(codec)),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BasicSettingsModeSection extends StatelessWidget {
  const _BasicSettingsModeSection({
    super.key,
    required this.settings,
    required this.controlsLocked,
    required this.notifier,
  });

  final AppSettings settings;
  final bool controlsLocked;
  final AppSettingsController notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SettingsLabel('Compression'),
        const SizedBox(height: 8),
        RadioGroup<CompressionMethod>(
          value: settings.compressionMethod,
          onChanged: controlsLocked ? null : notifier.setCompressionMethod,
          child: Row(
            children: [
              Expanded(
                child: RadioCard<CompressionMethod>(
                  value: CompressionMethod.lossless,
                  child: const _ChoiceCard(title: 'Lossless'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RadioCard<CompressionMethod>(
                  value: CompressionMethod.lossy,
                  child: const _ChoiceCard(title: 'Lossy'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SettingsLabel('Priority'),
        const SizedBox(height: 8),
        RadioGroup<CompressionPriority>(
          value: settings.compressionPriority,
          onChanged: controlsLocked ? null : notifier.setCompressionPriority,
          child: Row(
            children: [
              Expanded(
                child: RadioCard<CompressionPriority>(
                  value: CompressionPriority.compatibility,
                  child: const _ChoiceCard(title: 'Compatibility'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RadioCard<CompressionPriority>(
                  value: CompressionPriority.efficiency,
                  child: const _ChoiceCard(title: 'Efficiency'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AnalyzePanel extends ConsumerWidget {
  const _AnalyzePanel({required this.state});

  final AnalyzeRunState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(analyzeRunControllerProvider.notifier);
    final displayMode = ref.watch(currentPreviewDisplayModeProvider);
    final selectedAnalyzeSample = ref.watch(selectedAnalyzeSampleProvider);
    final fileController = ref.watch(fileOpenControllerProvider);
    final currentFilePath = fileController.currentPath;
    final currentFile = fileController.currentFile;
    final samples = [...state.samples]
      ..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    final qualityIndicator = state.isRunning
        ? state.currentQuality
        : selectedAnalyzeSample?.quality;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.2),
        borderRadius: theme.borderRadiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Analyze',
                  style: TextStyle(
                    color: theme.colorScheme.mutedForeground,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ).xSmall(),
              ),
              if (qualityIndicator case final quality?)
                Text('Q$quality').xSmall().muted(),
            ],
          ),
          const SizedBox(height: 8),
          if (state.isRunning || samples.isNotEmpty) ...[
            Expanded(
              child: samples.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _AnalyzeChart(
                      samples: samples,
                      originalSizeBytes: state.isRunning
                          ? null
                          : currentFile?.metadata.fileSize?.toDouble(),
                      selectedArtifactId: state.activeArtifactId,
                      onHoverSample: (sample) {
                        controller.hoverSample(sample);
                        if (currentFilePath != null) {
                          ref
                              .read(previewDisplaySelectionProvider.notifier)
                              .select(
                                filePath: currentFilePath,
                                mode: displayMode,
                              );
                        }
                        if (displayMode == PreviewDisplayMode.difference ||
                            displayMode == PreviewDisplayMode.heatmap) {
                          ref
                              .read(previewDifferenceRequestProvider.notifier)
                              .requestForArtifact(sample.artifactId);
                        }
                      },
                      onCommitSample: (sample) {
                        controller.selectSample(sample);
                        if (currentFilePath != null) {
                          ref
                              .read(previewDisplaySelectionProvider.notifier)
                              .select(
                                filePath: currentFilePath,
                                mode: displayMode,
                              );
                        }
                        if (displayMode == PreviewDisplayMode.difference ||
                            displayMode == PreviewDisplayMode.heatmap) {
                          ref
                              .read(previewDifferenceRequestProvider.notifier)
                              .requestForArtifact(sample.artifactId);
                        }
                        unawaited(
                          ref
                              .read(appSettingsProvider.notifier)
                              .setQuality(sample.quality),
                        );
                      },
                      onExitChart: () {
                        final activeSample = controller.clearHoveredSample();
                        if ((displayMode == PreviewDisplayMode.difference ||
                                displayMode == PreviewDisplayMode.heatmap) &&
                            activeSample != null) {
                          ref
                              .read(previewDifferenceRequestProvider.notifier)
                              .requestForArtifact(activeSample.artifactId);
                        }
                      },
                    ),
            ),
          ],
          if (state.globalError case final error?) ...[
            const SizedBox(height: 8),
            Text(error).xSmall().muted(),
          ],
        ],
      ),
    );
  }
}

class _AnalyzeChart extends StatefulWidget {
  const _AnalyzeChart({
    required this.samples,
    required this.originalSizeBytes,
    required this.selectedArtifactId,
    required this.onHoverSample,
    required this.onCommitSample,
    required this.onExitChart,
  });

  final List<AnalyzeSampleResult> samples;
  final double? originalSizeBytes;
  final String? selectedArtifactId;
  final ValueChanged<AnalyzeSampleResult> onHoverSample;
  final ValueChanged<AnalyzeSampleResult> onCommitSample;
  final VoidCallback onExitChart;

  @override
  State<_AnalyzeChart> createState() => _AnalyzeChartState();
}

class _AnalyzeChartState extends State<_AnalyzeChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _selectionPulseController;

  @override
  void initState() {
    super.initState();
    _selectionPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
  }

  @override
  void dispose() {
    _selectionPulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pixelMatchPoints = _metricPoints(
      widget.samples,
      (sample) => sample.pixelMatch,
    );
    final msSsimPoints = _metricPoints(
      widget.samples,
      (sample) => sample.msSsim == null ? null : sample.msSsim! * 100,
    );
    final ssimulacra2Points = _metricPoints(
      widget.samples,
      (sample) => sample.ssimulacra2,
    );
    final dataMaxX = widget.samples.fold<double>(
      0,
      (current, sample) => math.max(current, sample.sizeBytes.toDouble()),
    );
    final originalMarkerX = widget.originalSizeBytes;
    final visibleMaxX = math.max(dataMaxX, originalMarkerX ?? 0);
    final chartMaxX = visibleMaxX <= 0 ? 1.0 : visibleMaxX * 1.05;
    final xAxisInterval = visibleMaxX <= 0 ? 1.0 : visibleMaxX / 4;
    final originalSizeLineColor = const Color(0xFFD11A2A);
    final originalSizeOverlayColor = originalSizeLineColor.withValues(
      alpha: 0.08,
    );

    return MouseRegion(
      key: const ValueKey('analyze-chart-region'),
      onExit: (_) => widget.onExitChart(),
      child: AnimatedBuilder(
        animation: _selectionPulseController,
        builder: (context, child) {
          final selectedPulse = math
              .sin(_selectionPulseController.value * math.pi)
              .clamp(0.0, 1.0);
          return LineChart(
            LineChartData(
              minY: 0,
              maxY: 100,
              minX: 0,
              maxX: chartMaxX,
              gridData: FlGridData(
                drawVerticalLine: true,
                horizontalInterval: 20,
                verticalInterval: xAxisInterval,
                getDrawingHorizontalLine: (value) =>
                    FlLine(color: theme.colorScheme.border, strokeWidth: 1),
                getDrawingVerticalLine: (value) => FlLine(
                  color: theme.colorScheme.border.withValues(alpha: 0.6),
                  strokeWidth: 1,
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: 20,
                    getTitlesWidget: (value, meta) =>
                        Text(value.toInt().toString()).xSmall().muted(),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 18,
                    interval: xAxisInterval,
                    getTitlesWidget: (value, meta) {
                      if (dataMaxX > 0 && value > dataMaxX + 0.5) {
                        return const SizedBox.shrink();
                      }
                      return Text(_formatBytes(value.round())).xSmall().muted();
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border.all(color: theme.colorScheme.border),
              ),
              rangeAnnotations: RangeAnnotations(
                verticalRangeAnnotations: [
                  if (originalMarkerX != null && originalMarkerX < chartMaxX)
                    VerticalRangeAnnotation(
                      x1: originalMarkerX,
                      x2: chartMaxX,
                      color: originalSizeOverlayColor,
                    ),
                ],
              ),
              extraLinesData: ExtraLinesData(
                extraLinesOnTop: true,
                verticalLines: [
                  if (originalMarkerX != null)
                    VerticalLine(
                      x: originalMarkerX,
                      color: originalSizeLineColor,
                      strokeWidth: 1.5,
                      dashArray: [3, 4],
                    ),
                ],
              ),
              lineTouchData: LineTouchData(
                handleBuiltInTouches: false,
                touchCallback: (event, response) {
                  final touchedSpots = response?.lineBarSpots;
                  if (touchedSpots == null ||
                      touchedSpots.isEmpty ||
                      !_isAnalyzeSelectionEvent(event)) {
                    return;
                  }
                  final touched = touchedSpots.first;
                  final point = switch (touched.barIndex) {
                    0 => pixelMatchPoints[touched.spotIndex],
                    1 => msSsimPoints[touched.spotIndex],
                    _ => ssimulacra2Points[touched.spotIndex],
                  };
                  if (_isAnalyzeCommitEvent(event)) {
                    _selectionPulseController.forward(from: 0);
                    widget.onCommitSample(point.sample);
                  } else if (event is FlPointerHoverEvent) {
                    widget.onHoverSample(point.sample);
                  }
                },
              ),
              lineBarsData: [
                _buildAnalyzeLine(
                  points: pixelMatchPoints,
                  color: _analyzeMetricColorForLabel('Pixel Match'),
                  selectedArtifactId: widget.selectedArtifactId,
                  selectedPulse: selectedPulse,
                ),
                _buildAnalyzeLine(
                  points: msSsimPoints,
                  color: _analyzeMetricColorForLabel('MS-SSIM'),
                  selectedArtifactId: widget.selectedArtifactId,
                  selectedPulse: selectedPulse,
                ),
                _buildAnalyzeLine(
                  points: ssimulacra2Points,
                  color: _analyzeMetricColorForLabel('SSIMULACRA 2'),
                  selectedArtifactId: widget.selectedArtifactId,
                  selectedPulse: selectedPulse,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AnalyzeMetricPoint {
  const _AnalyzeMetricPoint({required this.sample, required this.spot});

  final AnalyzeSampleResult sample;
  final FlSpot spot;
}

List<_AnalyzeMetricPoint> _metricPoints(
  List<AnalyzeSampleResult> samples,
  double? Function(AnalyzeSampleResult sample) metric,
) {
  return samples
      .where((sample) => metric(sample) != null)
      .map(
        (sample) => _AnalyzeMetricPoint(
          sample: sample,
          spot: FlSpot(sample.sizeBytes.toDouble(), metric(sample)!),
        ),
      )
      .toList(growable: false);
}

LineChartBarData _buildAnalyzeLine({
  required List<_AnalyzeMetricPoint> points,
  required Color color,
  required String? selectedArtifactId,
  required double selectedPulse,
}) {
  return LineChartBarData(
    spots: points.map((point) => point.spot).toList(growable: false),
    isCurved: false,
    color: color,
    barWidth: 2,
    dotData: FlDotData(
      show: true,
      getDotPainter: (spot, percent, barData, index) {
        final selected =
            selectedArtifactId != null &&
            points[index].sample.artifactId == selectedArtifactId;
        return FlDotCirclePainter(
          radius: selected ? 4 + (2.25 * selectedPulse) : 2.5,
          color: color,
          strokeWidth: selected ? 2 : 0,
          strokeColor: Colors.white,
        );
      },
    ),
  );
}

class _DeveloperButton extends StatelessWidget {
  const _DeveloperButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 16,
      height: 16,
      child: Center(
        child: GhostButton(
          key: const ValueKey('title-bar-developer-button'),
          size: ButtonSize.xSmall,
          density: ButtonDensity.iconDense,
          onPressed: onPressed,
          child: Icon(
            LucideIcons.wrench,
            size: 10,
            color: theme.colorScheme.mutedForeground.withValues(alpha: 0.05),
          ),
        ),
      ),
    );
  }
}

class _TitleBarSettingsButton extends ConsumerWidget {
  const _TitleBarSettingsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasSettings = ref.watch(appSettingsProvider).hasValue;

    return SizedBox(
      width: 16,
      height: 16,
      child: Center(
        child: GhostButton(
          key: const ValueKey('title-bar-settings-button'),
          size: ButtonSize.xSmall,
          density: ButtonDensity.iconDense,
          onPressed: !hasSettings
              ? null
              : () {
                  showDropdown(
                    context: context,
                    builder: (context) {
                      return Consumer(
                        builder: (context, ref, child) {
                          final settings = ref
                              .watch(appSettingsProvider)
                              .asData
                              ?.value;
                          if (settings == null) {
                            return const SizedBox.shrink();
                          }
                          return DropdownMenu(
                            children: [
                              MenuButton(
                                key: const ValueKey('title-bar-theme-toggle'),
                                autoClose: false,
                                onPressed: (context) {
                                  unawaited(
                                    ref
                                        .read(appSettingsProvider.notifier)
                                        .cycleThemePreference(),
                                  );
                                },
                                child: Text(
                                  'Theme: ${settings.themePreference.label}',
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
          child: Icon(
            Icons.settings,
            size: 11,
            color: theme.colorScheme.mutedForeground.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

class _TitleBarHomeButton extends StatelessWidget {
  const _TitleBarHomeButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 16,
      height: 16,
      child: Center(
        child: GhostButton(
          key: const ValueKey('title-bar-home-button'),
          size: ButtonSize.xSmall,
          density: ButtonDensity.iconDense,
          onPressed: onPressed,
          child: Icon(
            Icons.home,
            size: 11,
            color: theme.colorScheme.mutedForeground.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

class _DeveloperSettingsDialog extends ConsumerWidget {
  const _DeveloperSettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    return AlertDialog(
      title: const Text('Developer'),
      content: SizedBox(
        width: 640,
        child: settings.when(
          data: (settings) {
            return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DeveloperSection(
                    title: 'Mode',
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Developer mode').small().medium(),
                              const SizedBox(height: 4),
                              Text(
                                'Unlock diagnostics and internal controls.',
                              ).xSmall().muted(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Switch(
                          value: settings.developerModeEnabled,
                          onChanged: notifier.setDeveloperModeEnabled,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _DeveloperSection(
                    title: 'Diagnostics',
                    child: Column(
                      children: [
                        Checkbox(
                          state: settings.timingLogsEnabled
                              ? CheckboxState.checked
                              : CheckboxState.unchecked,
                          onChanged: settings.developerModeEnabled
                              ? (value) {
                                  notifier.setTimingLogsEnabled(
                                    value == CheckboxState.checked,
                                  );
                                }
                              : null,
                          trailing: Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Timing logs').small().medium(),
                                const SizedBox(height: 4),
                                Text(
                                  'Measure preview and optimize timings in Dart and Rust.',
                                ).xSmall().muted(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Checkbox(
                          state: settings.previewPathHeaderEnabled
                              ? CheckboxState.checked
                              : CheckboxState.unchecked,
                          onChanged: settings.developerModeEnabled
                              ? (value) {
                                  notifier.setPreviewPathHeaderEnabled(
                                    value == CheckboxState.checked,
                                  );
                                }
                              : null,
                          trailing: Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Preview path header').small().medium(),
                                const SizedBox(height: 4),
                                Text(
                                  'Show the directory and file name above the preview.',
                                ).xSmall().muted(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
          loading: () => const SizedBox(
            height: 320,
            child: Center(child: Text('Loading developer settings')),
          ),
          error: (_, _) => const SizedBox(
            height: 320,
            child: Center(child: Text('Unable to load developer settings')),
          ),
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DeveloperSection extends StatelessWidget {
  const _DeveloperSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      padding: const EdgeInsets.all(18),
      borderRadius: theme.borderRadiusXl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title).xSmall().medium().muted(),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _BottomSidebar extends ConsumerStatefulWidget {
  const _BottomSidebar({required this.controller});

  final FileOpenController controller;

  @override
  ConsumerState<_BottomSidebar> createState() => _BottomSidebarState();
}

class _BottomSidebarState extends ConsumerState<_BottomSidebar> {
  Timer? _optimizeSuccessTimer;
  bool _showOptimizeSuccess = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<OptimizationRunState>(
      optimizationRunControllerProvider,
      _handleOptimizationRunStateChanged,
    );
  }

  @override
  void dispose() {
    _optimizeSuccessTimer?.cancel();
    super.dispose();
  }

  void _handleOptimizationRunStateChanged(
    OptimizationRunState? previous,
    OptimizationRunState next,
  ) {
    if (next.isRunning || next.jobState == BatchJobState.cancelRequested) {
      _clearOptimizeSuccess();
      return;
    }

    if (next.jobState == BatchJobState.completed &&
        previous?.jobState != BatchJobState.completed) {
      _showOptimizeSuccessState();
      return;
    }

    if (next.jobState == BatchJobState.failed ||
        next.jobState == BatchJobState.canceled) {
      _clearOptimizeSuccess();
    }
  }

  void _showOptimizeSuccessState() {
    _optimizeSuccessTimer?.cancel();
    if (!_showOptimizeSuccess) {
      setState(() {
        _showOptimizeSuccess = true;
      });
    }
    _optimizeSuccessTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOptimizeSuccess = false;
      });
    });
  }

  void _clearOptimizeSuccess() {
    _optimizeSuccessTimer?.cancel();
    _optimizeSuccessTimer = null;
    if (!_showOptimizeSuccess) {
      return;
    }
    setState(() {
      _showOptimizeSuccess = false;
    });
  }

  Widget _buildOptimizeActionButton({
    required ThemeData theme,
    required OptimizationRunState runState,
    required AnalyzeRunState analyzeState,
    required OptimizationRunController runController,
  }) {
    if (_showOptimizeSuccess && !runState.isRunning) {
      return _OptimizeActionButtonFrame(
        key: const ValueKey('optimize-action-success'),
        child: _OptimizeSuccessButton(theme: theme),
      );
    }

    if (runState.isCancelRequested) {
      return _OptimizeActionButtonFrame(
        key: const ValueKey('optimize-action-canceling'),
        child: Button.destructive(
          alignment: Alignment.center,
          onPressed: null,
          child: const Text(
            'Canceling...',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15),
          ),
        ),
      );
    }

    if (runState.isRunning) {
      return _OptimizeActionButtonFrame(
        key: const ValueKey('optimize-action-cancel'),
        child: Button.destructive(
          alignment: Alignment.center,
          onPressed: runController.cancelCurrentRun,
          child: const Text(
            'Cancel',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15),
          ),
        ),
      );
    }

    return _OptimizeActionButtonFrame(
      key: const ValueKey('optimize-action-idle'),
      child: PrimaryButton(
        alignment: Alignment.center,
        onPressed: analyzeState.isRunning || analyzeState.isCancelRequested
            ? null
            : runController.optimizeAll,
        child: const Text(
          'Optimize',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final currentFile = controller.currentFile;
    if (currentFile == null) {
      return const SizedBox.shrink();
    }

    final previewState = ref.watch(currentPreviewProvider);
    final preview = previewState.maybeWhen(
      data: (value) => value,
      orElse: () => null,
    );
    final plan = ref
        .watch(currentOptimizationPlanProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    final settings = ref
        .watch(appSettingsProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    final runState = ref.watch(optimizationRunControllerProvider);
    final analyzeState = ref.watch(analyzeRunControllerProvider);
    final runController = ref.read(optimizationRunControllerProvider.notifier);
    final selectedAnalyzeSample = ref.watch(selectedAnalyzeSampleProvider);
    final optimizedDisplay = ref.watch(currentOptimizedDisplayProvider);
    final pixelMatchMetric = selectedAnalyzeSample == null
        ? ref.watch(currentPreviewPixelMatchProvider)
        : const AsyncData<PreviewMetricResult?>(null);
    final msSsimMetric = selectedAnalyzeSample == null
        ? ref.watch(currentPreviewMsSsimProvider)
        : const AsyncData<PreviewMetricResult?>(null);
    final ssimulacra2Metric = selectedAnalyzeSample == null
        ? ref.watch(currentPreviewSsimulacra2Provider)
        : const AsyncData<PreviewMetricResult?>(null);
    final optimizedPreviewSizeWarning = _optimizedPreviewSizeWarningText(
      controller: controller,
      file: currentFile,
      optimizedDisplay: optimizedDisplay,
    );
    final progressValue = runState.totalCount > 0
        ? (runState.completedCount / runState.totalCount).clamp(0.0, 1.0)
        : 0.0;
    final summary = _BottomSummaryViewModel.build(
      controller: controller,
      currentFile: currentFile,
      runState: runState,
      preview: preview,
      analyzeSample: selectedAnalyzeSample,
      isPreviewPending: previewState.isLoading,
      plan: plan,
      settings: settings,
      pixelMatchMetric: pixelMatchMetric,
      msSsimMetric: msSsimMetric,
      ssimulacra2Metric: ssimulacra2Metric,
    );

    return Card(
      padding: EdgeInsets.zero,
      borderRadius: theme.borderRadiusXl,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: _BottomStatsSection(stats: summary.stats),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: _BottomDetail(
                            label: '',
                            value: '',
                            child: _BottomInfoSection(
                              originalTitle: summary.originalSectionTitle,
                              originalRows: summary.originalRows,
                              outputTitle: summary.outputSectionTitle,
                              outputRows: summary.outputRows,
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: _BottomDetail(
                            label: '',
                            value: '',
                            child: _BottomQualitySection(
                              isFolderSelected: controller.isFolderSelected,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    color: theme.colorScheme.border,
                  ),
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 188,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (optimizedPreviewSizeWarning
                            case final warning?) ...[
                          _SettingsWarningBlock(
                            icon: LucideIcons.triangleAlert,
                            message: warning,
                          ),
                          const SizedBox(height: 8),
                        ],
                        SizedBox(
                          height: 36,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeInOut,
                            switchOutCurve: Curves.easeInOut,
                            transitionBuilder: (child, animation) {
                              final curved = CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeInOut,
                              );
                              return FadeTransition(
                                opacity: curved,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.03),
                                    end: Offset.zero,
                                  ).animate(curved),
                                  child: child,
                                ),
                              );
                            },
                            child: _buildOptimizeActionButton(
                              theme: theme,
                              runState: runState,
                              analyzeState: analyzeState,
                              runController: runController,
                            ),
                          ),
                        ),
                        if (runState.isRunning || analyzeState.isRunning) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: analyzeState.isRunning
                                ? (analyzeState.totalCount > 0
                                      ? (analyzeState.completedCount /
                                                analyzeState.totalCount)
                                            .clamp(0.0, 1.0)
                                      : 0.0)
                                : progressValue,
                            minHeight: 6,
                            borderRadius: theme.borderRadiusLg,
                          ),
                          if (analyzeState.isRunning &&
                              analyzeState.totalCount > 0) ...[
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                '${analyzeState.completedCount}/${analyzeState.totalCount}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: theme.colorScheme.mutedForeground,
                                ),
                              ).xSmall(),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomDetail extends StatelessWidget {
  const _BottomDetail({required this.label, required this.value, this.child});

  final String label;
  final String value;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (child != null) {
      return child!;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label).xSmall().medium().muted(),
        const SizedBox(height: 6),
        Text(value).small().medium(),
      ],
    );
  }
}

class _OptimizeActionButtonFrame extends StatelessWidget {
  const _OptimizeActionButtonFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(child: child);
  }
}

class _OptimizeSuccessButton extends StatelessWidget {
  const _OptimizeSuccessButton({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    const successColor = Color(0xFF34C759);

    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: successColor,
        borderRadius: theme.borderRadiusMd,
      ),
      child: const Text(
        'Success!',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _BottomStatsSection extends StatelessWidget {
  const _BottomStatsSection({required this.stats});

  final List<_BottomStatData> stats;

  @override
  Widget build(BuildContext context) {
    final topRow = stats.take(2).toList(growable: false);
    final bottomRow = stats.skip(2).take(2).toList(growable: false);

    return Column(
      children: [
        Expanded(child: _BottomStatRow(stats: topRow)),
        const SizedBox(height: 10),
        Expanded(child: _BottomStatRow(stats: bottomRow)),
      ],
    );
  }
}

class _BottomStatRow extends StatelessWidget {
  const _BottomStatRow({required this.stats});

  final List<_BottomStatData> stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < stats.length; index++) ...[
          Expanded(child: _BottomStatTile(stat: stats[index])),
          if (index + 1 < stats.length) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class _BottomStatTile extends ConsumerWidget {
  const _BottomStatTile({required this.stat});

  final _BottomStatData stat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider).asData?.value;
    final savingsDisplayMode = ref.watch(_savingsDisplayModeProvider);
    final isToggleable = stat.toggleable && !stat.loading;
    final displayedValue =
        stat.toggleable && savingsDisplayMode == _SavingsDisplayMode.ratio
        ? (stat.alternateValue ?? stat.value)
        : stat.value;
    final defaultValueColor = switch (stat.colorMode) {
      _BottomStatColorMode.none => stat.color,
      _ => theme.colorScheme.foreground,
    };
    final valueColor = switch (stat.colorMode) {
      _BottomStatColorMode.none => defaultValueColor,
      _BottomStatColorMode.fileSize
          when settings?.fileSizeColorsEnabled == true &&
              stat.colorScore != null =>
        _qualityMetricColor(_bitsPerPixelColorScore(stat.colorScore!)),
      _BottomStatColorMode.similarity
          when settings?.similarityMetricColorsEnabled == true &&
              stat.colorScore != null =>
        _qualityMetricColor(stat.colorScore!),
      _BottomStatColorMode.savings
          when settings?.savingsColorsEnabled == true &&
              stat.colorScore != null =>
        _savingsMetricColor(stat.colorScore!),
      _ => defaultValueColor,
    };

    final tile = Container(
      key: ValueKey('bottom-stat-${stat.label}'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.2),
        borderRadius: theme.borderRadiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stat.label).xSmall().medium().muted(),
          const Spacer(),
          if (stat.loading)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: stat.color,
              ),
            )
          else
            Text(
              displayedValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
            ),
        ],
      ),
    );

    final decoratedTile = stat.tooltip == null || stat.loading
        ? tile
        : Tooltip(
            waitDuration: const Duration(milliseconds: 250),
            showDuration: const Duration(milliseconds: 120),
            tooltip: (context) => TooltipContainer(child: Text(stat.tooltip!)),
            child: tile,
          );

    final tappableTile = !isToggleable
        ? decoratedTile
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                ref.read(_savingsDisplayModeProvider.notifier).toggle();
              },
              child: decoratedTile,
            ),
          );
    final contextMenuItem = switch (stat.colorMode) {
      _BottomStatColorMode.similarity => MenuButton(
        key: const ValueKey('bottom-stat-similarity-colors-toggle'),
        onPressed: (context) {
          unawaited(
            ref
                .read(appSettingsProvider.notifier)
                .setSimilarityMetricColorsEnabled(
                  !(settings?.similarityMetricColorsEnabled ?? false),
                ),
          );
        },
        child: Text(
          settings?.similarityMetricColorsEnabled == true
              ? 'Disable similarity colors'
              : 'Enable similarity colors',
        ),
      ),
      _BottomStatColorMode.savings => MenuButton(
        key: const ValueKey('bottom-stat-savings-colors-toggle'),
        onPressed: (context) {
          unawaited(
            ref
                .read(appSettingsProvider.notifier)
                .setSavingsColorsEnabled(
                  !(settings?.savingsColorsEnabled ?? false),
                ),
          );
        },
        child: Text(
          settings?.savingsColorsEnabled == true
              ? 'Disable savings colors'
              : 'Enable savings colors',
        ),
      ),
      _BottomStatColorMode.fileSize => MenuButton(
        key: const ValueKey('bottom-stat-file-size-colors-toggle'),
        onPressed: (context) {
          unawaited(
            ref
                .read(appSettingsProvider.notifier)
                .setFileSizeColorsEnabled(
                  !(settings?.fileSizeColorsEnabled ?? false),
                ),
          );
        },
        child: Text(
          settings?.fileSizeColorsEnabled == true
              ? 'Disable file size colors'
              : 'Enable file size colors',
        ),
      ),
      _BottomStatColorMode.none => null,
    };

    if (contextMenuItem == null) {
      return tappableTile;
    }

    return ContextMenu(items: [contextMenuItem], child: tappableTile);
  }
}

class _BottomInfoSection extends StatelessWidget {
  const _BottomInfoSection({
    required this.originalTitle,
    required this.originalRows,
    required this.outputTitle,
    required this.outputRows,
  });

  final String originalTitle;
  final List<_BottomInfoRowData> originalRows;
  final String outputTitle;
  final List<_BottomInfoRowData> outputRows;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BottomInfoColumn(title: originalTitle, rows: originalRows),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: _BottomInfoColumn(title: outputTitle, rows: outputRows),
        ),
      ],
    );
  }
}

class _BottomInfoColumn extends StatelessWidget {
  const _BottomInfoColumn({required this.title, required this.rows});

  final String title;
  final List<_BottomInfoRowData> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.2),
        borderRadius: theme.borderRadiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title).xSmall().medium().muted(),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...[
            _BottomInfoRow(row: rows[index]),
            if (index + 1 < rows.length) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _BottomInfoRow extends ConsumerStatefulWidget {
  const _BottomInfoRow({required this.row});

  final _BottomInfoRowData row;

  @override
  ConsumerState<_BottomInfoRow> createState() => _BottomInfoRowState();
}

class _BottomInfoRowState extends ConsumerState<_BottomInfoRow> {
  Timer? _highlightTimer;
  var _isHighlighted = false;

  @override
  void didUpdateWidget(covariant _BottomInfoRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.row.highlightOnValueChange) {
      return;
    }
    if (oldWidget.row.value == widget.row.value) {
      return;
    }
    _highlightTimer?.cancel();
    setState(() {
      _isHighlighted = true;
    });
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _isHighlighted = false;
      });
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.row.supportsBitsPerPixelColors
        ? ref.watch(appSettingsProvider).asData?.value
        : null;
    final valueColor = widget.row.supportsBitsPerPixelColors
        ? settings?.bitsPerPixelColorsEnabled == true &&
                  widget.row.bitsPerPixelValue != null
              ? _qualityMetricColor(
                  _bitsPerPixelColorScore(widget.row.bitsPerPixelValue!),
                )
              : theme.colorScheme.foreground
        : null;
    final rowWidget = SizedBox(
      key: widget.row.rowKey == null ? null : ValueKey(widget.row.rowKey!),
      width: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.row.label} ').xSmall().medium().muted(),
          Expanded(
            child: TweenAnimationBuilder<TextStyle?>(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              tween: TextStyleTween(
                end: Theme.of(context).typography.xSmall.copyWith(
                  fontWeight: _isHighlighted
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: valueColor,
                ),
              ),
              builder: (context, style, child) {
                return Text(
                  widget.row.value,
                  key: widget.row.key == null
                      ? null
                      : ValueKey(widget.row.key!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: style,
                );
              },
            ),
          ),
        ],
      ),
    );

    if (!widget.row.supportsBitsPerPixelColors) {
      return rowWidget;
    }

    return ContextMenu(
      items: [
        MenuButton(
          key: const ValueKey('bottom-info-bpp-colors-toggle'),
          onPressed: (context) {
            unawaited(
              ref
                  .read(appSettingsProvider.notifier)
                  .setBitsPerPixelColorsEnabled(
                    !(settings?.bitsPerPixelColorsEnabled ?? false),
                  ),
            );
          },
          child: Text(
            settings?.bitsPerPixelColorsEnabled == true
                ? 'Disable bits per pixel colors'
                : 'Enable bits per pixel colors',
          ),
        ),
      ],
      child: rowWidget,
    );
  }
}

class _BottomQualitySection extends ConsumerWidget {
  const _BottomQualitySection({required this.isFolderSelected});

  final bool isFolderSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider).asData?.value;
    final previewState = ref.watch(currentPreviewProvider);
    final selectedAnalyzeSample = ref.watch(selectedAnalyzeSampleProvider);
    final previewPendingBeforeMetrics =
        selectedAnalyzeSample == null &&
        previewState.isLoading &&
        previewState.asData?.value == null;
    final colorCodingEnabled = settings?.qualityMetricColorsEnabled ?? false;
    final rows = isFolderSelected
        ? const <_BottomMetricRowState>[
            _BottomMetricRowState.text(label: 'Pixel Match', value: 'N/A'),
            _BottomMetricRowState.text(label: 'MS-SSIM', value: 'N/A'),
            _BottomMetricRowState.text(label: 'SSIMULACRA 2', value: 'N/A'),
          ]
        : selectedAnalyzeSample != null
        ? <_BottomMetricRowState>[
            _metricRowStateFromAnalyzeSample(
              label: 'Pixel Match',
              value: selectedAnalyzeSample.pixelMatch,
              formatter: _formatNullableMetricPercent,
              scoreMapper: (value) => value?.clamp(0, 100).toDouble(),
            ),
            _metricRowStateFromAnalyzeSample(
              label: 'MS-SSIM',
              value: selectedAnalyzeSample.msSsim,
              formatter: (value) =>
                  _formatNullableMetric(value, trimIfOne: true),
              scoreMapper: (value) =>
                  value == null ? null : (value * 100).clamp(0, 100).toDouble(),
            ),
            _metricRowStateFromAnalyzeSample(
              label: 'SSIMULACRA 2',
              value: selectedAnalyzeSample.ssimulacra2,
              formatter: (value) =>
                  _formatNullableMetric(value, digits: 1, trimIfHundred: true),
              scoreMapper: (value) => value?.clamp(0, 100).toDouble(),
            ),
          ]
        : <_BottomMetricRowState>[
            _metricRowState(
              label: 'Pixel Match',
              metric: ref.watch(currentPreviewPixelMatchProvider),
              formatter: _formatNullableMetricPercent,
              scoreMapper: (value) => value?.clamp(0, 100).toDouble(),
              previewPendingBeforeMetrics: previewPendingBeforeMetrics,
            ),
            _metricRowState(
              label: 'MS-SSIM',
              metric: ref.watch(currentPreviewMsSsimProvider),
              formatter: (value) =>
                  _formatNullableMetric(value, trimIfOne: true),
              scoreMapper: (value) =>
                  value == null ? null : (value * 100).clamp(0, 100).toDouble(),
              previewPendingBeforeMetrics: previewPendingBeforeMetrics,
            ),
            _metricRowState(
              label: 'SSIMULACRA 2',
              metric: ref.watch(currentPreviewSsimulacra2Provider),
              formatter: (value) =>
                  _formatNullableMetric(value, digits: 1, trimIfHundred: true),
              scoreMapper: (value) => value?.clamp(0, 100).toDouble(),
              previewPendingBeforeMetrics: previewPendingBeforeMetrics,
            ),
          ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.2),
        borderRadius: theme.borderRadiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: const Text('Quality').small().medium().muted()),
              SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: GhostButton(
                    key: const ValueKey('quality-metric-colors-button'),
                    size: ButtonSize.xSmall,
                    density: ButtonDensity.iconDense,
                    onPressed: settings == null
                        ? null
                        : () {
                            showDropdown(
                              context: context,
                              builder: (context) {
                                return Consumer(
                                  builder: (context, ref, child) {
                                    final settings = ref
                                        .watch(appSettingsProvider)
                                        .asData
                                        ?.value;
                                    if (settings == null) {
                                      return const SizedBox.shrink();
                                    }
                                    final colorCodingEnabled =
                                        settings.qualityMetricColorsEnabled;
                                    return DropdownMenu(
                                      children: [
                                        MenuCheckbox(
                                          key: const ValueKey(
                                            'quality-metric-colors-toggle',
                                          ),
                                          value: colorCodingEnabled,
                                          autoClose: false,
                                          onChanged: (context, value) {
                                            unawaited(
                                              ref
                                                  .read(
                                                    appSettingsProvider
                                                        .notifier,
                                                  )
                                                  .setQualityMetricColorsEnabled(
                                                    value,
                                                  ),
                                            );
                                          },
                                          child: Text(
                                            colorCodingEnabled
                                                ? 'Disable metric colors'
                                                : 'Enable metric colors',
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                            );
                          },
                    child: Icon(
                      Icons.settings,
                      size: 11,
                      color: theme.colorScheme.mutedForeground.withValues(
                        alpha: 0.35,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...[
            _BottomMetricRow(
              row: rows[index],
              colorCodingEnabled: colorCodingEnabled,
            ),
            if (index + 1 < rows.length) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

_BottomMetricRowState _metricRowStateFromAnalyzeSample({
  required String label,
  required double? value,
  required String Function(double? value) formatter,
  required double? Function(double? value) scoreMapper,
}) {
  return _BottomMetricRowState.text(
    label: label,
    value: formatter(value),
    qualityScore: scoreMapper(value),
  );
}

_BottomMetricRowState _metricRowState({
  required String label,
  required AsyncValue<PreviewMetricResult?> metric,
  required String Function(double?) formatter,
  required double? Function(double? value) scoreMapper,
  required bool previewPendingBeforeMetrics,
}) {
  if (previewPendingBeforeMetrics) {
    return _BottomMetricRowState.text(label: label, value: '—');
  }
  return metric.when(
    data: (result) => _BottomMetricRowState.text(
      label: label,
      value: formatter(result?.value),
      qualityScore: scoreMapper(result?.value),
      timingTooltip: result == null
          ? null
          : _formatMetricTimingTooltip(result.elapsedMilliseconds),
    ),
    error: (_, _) => _BottomMetricRowState.text(label: label, value: 'N/A'),
    loading: () => _BottomMetricRowState.loading(label: label),
  );
}

class _BottomMetricRowState {
  const _BottomMetricRowState._({
    required this.label,
    required this.state,
    this.value,
    this.qualityScore,
    this.timingTooltip,
  });

  const _BottomMetricRowState.loading({required String label})
    : this._(label: label, state: _BottomMetricRowDisplayState.loading);

  const _BottomMetricRowState.text({
    required String label,
    required String value,
    double? qualityScore,
    String? timingTooltip,
  }) : this._(
         label: label,
         state: _BottomMetricRowDisplayState.text,
         value: value,
         qualityScore: qualityScore,
         timingTooltip: timingTooltip,
       );

  final String label;
  final _BottomMetricRowDisplayState state;
  final String? value;
  final double? qualityScore;
  final String? timingTooltip;
}

enum _BottomMetricRowDisplayState { loading, text }

const _pixelMatchAnalyzeColor = Color(0xFF2563EB);
const _msSsimAnalyzeColor = Color(0xFFD97706);
const _ssimulacra2AnalyzeColor = Color(0xFF16A34A);

Color _analyzeMetricColorForLabel(String label) {
  return switch (label) {
    'Pixel Match' => _pixelMatchAnalyzeColor,
    'MS-SSIM' => _msSsimAnalyzeColor,
    'SSIMULACRA 2' => _ssimulacra2AnalyzeColor,
    _ => const Color(0xFF94A3B8),
  };
}

class _BottomMetricRow extends StatelessWidget {
  const _BottomMetricRow({required this.row, required this.colorCodingEnabled});

  final _BottomMetricRowState row;
  final bool colorCodingEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: ValueKey('metric-legend-dot-${row.label}'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _analyzeMetricColorForLabel(row.label),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(row.label).xSmall().medium().muted()),
      ],
    );
    final help = _metricHelpFor(row.label);
    final valueColor = colorCodingEnabled && row.qualityScore != null
        ? _qualityMetricColor(row.qualityScore!)
        : theme.colorScheme.mutedForeground;

    return Row(
      children: [
        Expanded(
          child: help == null
              ? labelWidget
              : _MetricHelpHoverCard(help: help, child: labelWidget),
        ),
        if (row.state == _BottomMetricRowDisplayState.loading)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else ...[
          (() {
            final valueWidget = Text(
              row.value!,
              style: TextStyle(color: valueColor),
            ).xSmall().medium();
            return row.timingTooltip == null
                ? valueWidget
                : Tooltip(
                    waitDuration: const Duration(milliseconds: 250),
                    showDuration: const Duration(milliseconds: 120),
                    tooltip: (context) =>
                        TooltipContainer(child: Text(row.timingTooltip!)),
                    child: valueWidget,
                  );
          })(),
        ],
      ],
    );
  }
}

Color _qualityMetricColor(double score) {
  return _interpolateColorStops(score, _qualityMetricColorStops);
}

Color _savingsMetricColor(double score) {
  return _interpolateColorStops(score, _savingsMetricColorStops);
}

double _bitsPerPixelColorScore(double bitsPerPixel) {
  if (bitsPerPixel <= 0.25) {
    return 100;
  }
  if (bitsPerPixel <= 0.5) {
    return _interpolateLinear(bitsPerPixel, 0.25, 0.5, 100, 75);
  }
  if (bitsPerPixel <= 1.0) {
    return _interpolateLinear(bitsPerPixel, 0.5, 1.0, 75, 60);
  }
  if (bitsPerPixel <= 1.6) {
    return _interpolateLinear(bitsPerPixel, 1.0, 1.6, 60, 40);
  }
  if (bitsPerPixel <= 2.0) {
    return _interpolateLinear(bitsPerPixel, 1.6, 2.0, 40, 20);
  }
  if (bitsPerPixel <= 5.0) {
    return _interpolateLinear(bitsPerPixel, 2.0, 5.0, 20, 0);
  }
  return 0;
}

double _interpolateLinear(
  double value,
  double lowerBound,
  double upperBound,
  double lowerOutput,
  double upperOutput,
) {
  final range = upperBound - lowerBound;
  if (range <= 0) {
    return upperOutput;
  }
  final t = (value - lowerBound) / range;
  return lowerOutput + ((upperOutput - lowerOutput) * t);
}

Color _interpolateColorStops(
  double score,
  List<({double value, Color color})> colorStops,
) {
  final clampedScore = score
      .clamp(colorStops.first.value, colorStops.last.value)
      .toDouble();

  for (var index = 1; index < colorStops.length; index++) {
    final lower = colorStops[index - 1];
    final upper = colorStops[index];
    if (clampedScore > upper.value) {
      continue;
    }

    final range = upper.value - lower.value;
    if (range <= 0) {
      return upper.color;
    }

    final t = (clampedScore - lower.value) / range;
    return Color.lerp(lower.color, upper.color, t) ?? upper.color;
  }

  return colorStops.last.color;
}

class _MetricHelpData {
  const _MetricHelpData({
    required this.description,
    required this.linkLabel,
    required this.linkUrl,
  });

  final String description;
  final String linkLabel;
  final Uri linkUrl;
}

class _MetricHelpHoverCard extends StatelessWidget {
  const _MetricHelpHoverCard({required this.help, required this.child});

  final _MetricHelpData help;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return HoverCard(
      wait: const Duration(milliseconds: 250),
      debounce: const Duration(milliseconds: 120),
      hoverBuilder: (context) {
        return Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.popover,
            borderRadius: theme.borderRadiusLg,
            border: Border.all(color: theme.colorScheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(help.description).xSmall().muted(),
              const SizedBox(height: 10),
              LinkButton(
                density: ButtonDensity.compact,
                onPressed: () async {
                  await launchUrl(
                    help.linkUrl,
                    mode: LaunchMode.externalApplication,
                  );
                },
                child: Text(help.linkLabel),
              ),
            ],
          ),
        );
      },
      child: child,
    );
  }
}

_MetricHelpData? _metricHelpFor(String label) {
  return switch (label) {
    'Pixel Match' => _MetricHelpData(
      description:
          'Estimates what percentage of the image remains visually unchanged.',
      linkLabel: 'Learn more on GitHub (dify)',
      linkUrl: Uri.parse('https://github.com/jihchi/dify'),
    ),
    'MS-SSIM' => _MetricHelpData(
      description:
          'Compares preserved structure and contrast across several viewing scales.',
      linkLabel: 'Learn more on Wikipedia',
      linkUrl: Uri.parse(
        'https://en.wikipedia.org/wiki/Structural_similarity_index_measure',
      ),
    ),
    'SSIMULACRA 2' => _MetricHelpData(
      description: 'A perceptual quality metric tuned to human vision.',
      linkLabel: 'Learn more on x266 wiki',
      linkUrl: Uri.parse('https://wiki.x266.mov/docs/metrics/SSIMULACRA2'),
    ),
    _ => null,
  };
}

class _BottomSummaryViewModel {
  const _BottomSummaryViewModel({
    required this.stats,
    required this.originalSectionTitle,
    required this.originalRows,
    required this.outputSectionTitle,
    required this.outputRows,
  });

  final List<_BottomStatData> stats;
  final String originalSectionTitle;
  final List<_BottomInfoRowData> originalRows;
  final String outputSectionTitle;
  final List<_BottomInfoRowData> outputRows;

  static _BottomSummaryViewModel build({
    required FileOpenController controller,
    required OpenedImageFile currentFile,
    required OptimizationRunState runState,
    required OptimizationPreview? preview,
    required AnalyzeSampleResult? analyzeSample,
    required bool isPreviewPending,
    required OptimizationPlan? plan,
    required AppSettings? settings,
    required AsyncValue<PreviewMetricResult?> pixelMatchMetric,
    required AsyncValue<PreviewMetricResult?> msSsimMetric,
    required AsyncValue<PreviewMetricResult?> ssimulacra2Metric,
  }) {
    if (controller.isFolderSelected) {
      return _buildFolder(
        controller: controller,
        runState: runState,
        settings: settings,
      );
    }

    return _buildFile(
      file: currentFile,
      runState: runState,
      preview: preview,
      analyzeSample: analyzeSample,
      isPreviewPending: isPreviewPending,
      plan: plan,
      pixelMatchMetric: pixelMatchMetric,
      msSsimMetric: msSsimMetric,
      ssimulacra2Metric: ssimulacra2Metric,
    );
  }

  static _BottomSummaryViewModel _buildFile({
    required OpenedImageFile file,
    required OptimizationRunState runState,
    required OptimizationPreview? preview,
    required AnalyzeSampleResult? analyzeSample,
    required bool isPreviewPending,
    required OptimizationPlan? plan,
    required AsyncValue<PreviewMetricResult?> pixelMatchMetric,
    required AsyncValue<PreviewMetricResult?> msSsimMetric,
    required AsyncValue<PreviewMetricResult?> ssimulacra2Metric,
  }) {
    final originalBytes = _originalFileSizeBytes(file);
    final hasSavedResult = file.lastResult != null;
    final isOptimizedPreviewPending =
        analyzeSample == null &&
        preview == null &&
        isPreviewPending &&
        !hasSavedResult;
    final newBytes =
        analyzeSample?.sizeBytes.toInt() ??
        preview?.result.sizeBytes.toInt() ??
        (isOptimizedPreviewPending ? null : _effectiveFileSizeBytes(file));
    final originalBpp = _bitsPerPixel(
      bytes: originalBytes,
      width: file.metadata.width,
      height: file.metadata.height,
    );
    final optimizedBpp = _bitsPerPixel(
      bytes: newBytes,
      width:
          analyzeSample?.width ??
          preview?.result.width ??
          file.lastResult?.width ??
          file.metadata.width,
      height:
          analyzeSample?.height ??
          preview?.result.height ??
          file.lastResult?.height ??
          file.metadata.height,
    );
    final savingsBytes = originalBytes != null && newBytes != null
        ? originalBytes - newBytes
        : null;
    final savingsPercent =
        originalBytes != null && originalBytes > 0 && savingsBytes != null
        ? (savingsBytes / originalBytes) * 100
        : null;
    final outputFormat =
        analyzeSample?.format ??
        file.lastResult?.format ??
        (plan == null ? null : codecIdOf(plan.targetCodec));
    final optimizedTimingTooltip = analyzeSample == null && preview != null
        ? _formatMetricTimingTooltip(preview.elapsedMilliseconds)
        : null;
    final similarityStat = _deriveSimilarityStat(
      analyzeSample: analyzeSample,
      pixelMatchMetric: pixelMatchMetric,
      msSsimMetric: msSsimMetric,
      ssimulacra2Metric: ssimulacra2Metric,
    );
    return _BottomSummaryViewModel(
      stats: [
        _BottomStatData(
          label: 'Original',
          value: _formatNullableBytes(originalBytes),
          color: const Color(0xFF6B7280),
          colorMode: _BottomStatColorMode.fileSize,
          colorScore: originalBpp,
        ),
        _BottomStatData(
          label: 'Optimized',
          value: _formatNullableBytes(newBytes),
          color: const Color(0xFF2563EB),
          colorMode: _BottomStatColorMode.fileSize,
          colorScore: optimizedBpp,
          loading: isOptimizedPreviewPending,
          tooltip: optimizedTimingTooltip,
        ),
        _BottomStatData(
          label: 'Savings',
          value: _formatNullablePercentValue(savingsPercent),
          alternateValue: _formatSavingsRatio(originalBytes, newBytes),
          color: const Color(0xFF16A34A),
          colorMode: _BottomStatColorMode.savings,
          colorScore: savingsPercent?.clamp(0, 400).toDouble(),
          toggleable: true,
        ),
        _BottomStatData(
          label: 'Similarity',
          value: similarityStat.value,
          color: Color(0xFFF59E0B),
          colorMode: _BottomStatColorMode.similarity,
          colorScore: similarityStat.score,
        ),
      ],
      originalSectionTitle: 'Original',
      originalRows: [
        _BottomInfoRowData(
          label: 'Format',
          value: formatLabel(file.metadata.format),
        ),
        _BottomInfoRowData(
          label: 'Bits Per Pixel',
          value: _formatNullableBpp(originalBpp),
          key: 'original-bpp-value',
          rowKey: 'original-bpp-row',
          bitsPerPixelValue: originalBpp,
          supportsBitsPerPixelColors: true,
        ),
      ],
      outputSectionTitle: 'Optimized',
      outputRows: [
        _BottomInfoRowData(
          label: 'Format',
          value: outputFormat == null ? '—' : formatLabel(outputFormat),
          key: 'optimized-format-value',
          highlightOnValueChange: true,
        ),
        _BottomInfoRowData(
          label: 'Bits Per Pixel',
          value: _formatNullableBpp(optimizedBpp),
          key: 'optimized-bpp-value',
          rowKey: 'optimized-bpp-row',
          bitsPerPixelValue: optimizedBpp,
          supportsBitsPerPixelColors: true,
        ),
      ],
    );
  }

  static _BottomSummaryViewModel _buildFolder({
    required FileOpenController controller,
    required OptimizationRunState runState,
    required AppSettings? settings,
  }) {
    final files = controller.selectedFolderFiles;
    final originalBytes = _aggregateFolderBytes(files, useOriginalSizes: true);
    final newBytes = _aggregateFolderBytes(files, useOriginalSizes: false);
    final originalBpp = _aggregateFolderBpp(files, useOriginalSizes: true);
    final optimizedBpp = _aggregateFolderBpp(files, useOriginalSizes: false);
    final savingsBytes = originalBytes != null && newBytes != null
        ? originalBytes - newBytes
        : null;
    final savingsPercent =
        originalBytes != null && originalBytes > 0 && savingsBytes != null
        ? (savingsBytes / originalBytes) * 100
        : null;
    final completedCount = files
        .where(
          (file) => _isTerminalStatus(_statusForFile(file, runState).status),
        )
        .length;

    return _BottomSummaryViewModel(
      stats: [
        _BottomStatData(
          label: 'Original',
          value: _formatNullableBytes(originalBytes),
          color: const Color(0xFF6B7280),
          colorMode: _BottomStatColorMode.fileSize,
          colorScore: originalBpp,
        ),
        _BottomStatData(
          label: 'Optimized',
          value: _formatNullableBytes(newBytes),
          color: const Color(0xFF2563EB),
          colorMode: _BottomStatColorMode.fileSize,
          colorScore: optimizedBpp,
        ),
        _BottomStatData(
          label: 'Savings',
          value: _formatNullablePercentValue(savingsPercent),
          alternateValue: _formatSavingsRatio(originalBytes, newBytes),
          color: const Color(0xFF16A34A),
          colorMode: _BottomStatColorMode.savings,
          colorScore: savingsPercent?.clamp(0, 400).toDouble(),
          toggleable: true,
        ),
        const _BottomStatData(
          label: 'Similarity',
          value: 'N/A',
          color: Color(0xFFF59E0B),
        ),
      ],
      originalSectionTitle: 'Original',
      originalRows: [
        _BottomInfoRowData(
          label: 'Folder',
          value:
              controller.selectedFolderName ??
              controller.selectedFolderPath ??
              'Unknown',
        ),
        _BottomInfoRowData(label: 'Images', value: '${files.length}'),
        const _BottomInfoRowData(label: 'Scope', value: 'Loaded'),
        _BottomInfoRowData(
          label: 'Bits Per Pixel',
          value: _formatNullableBpp(originalBpp),
          key: 'original-bpp-value',
          rowKey: 'original-bpp-row',
          bitsPerPixelValue: originalBpp,
          supportsBitsPerPixelColors: true,
        ),
      ],
      outputSectionTitle: 'Optimized',
      outputRows: [
        _BottomInfoRowData(
          label: 'Target',
          value: settings == null ? '—' : codecLabel(settings.effectiveCodec),
        ),
        _BottomInfoRowData(
          label: 'Completed',
          value: '$completedCount / ${files.length}',
        ),
        _BottomInfoRowData(
          label: 'Bits Per Pixel',
          value: _formatNullableBpp(optimizedBpp),
          key: 'optimized-bpp-value',
          rowKey: 'optimized-bpp-row',
          bitsPerPixelValue: optimizedBpp,
          supportsBitsPerPixelColors: true,
        ),
      ],
    );
  }
}

class _DerivedSimilarityStat {
  const _DerivedSimilarityStat({
    required this.value,
    required this.loading,
    this.score,
  });

  final String value;
  final bool loading;
  final double? score;
}

_DerivedSimilarityStat _deriveSimilarityStat({
  AnalyzeSampleResult? analyzeSample,
  required AsyncValue<PreviewMetricResult?> pixelMatchMetric,
  required AsyncValue<PreviewMetricResult?> msSsimMetric,
  required AsyncValue<PreviewMetricResult?> ssimulacra2Metric,
}) {
  if (analyzeSample != null) {
    final normalizedValues = <double>[
      if (analyzeSample.pixelMatch case final pixelMatch?)
        pixelMatch.clamp(0, 100).toDouble(),
      if (analyzeSample.msSsim case final msSsim?)
        (msSsim * 100).clamp(0, 100).toDouble(),
      if (analyzeSample.ssimulacra2 case final ssimulacra2?)
        ssimulacra2.clamp(0, 100).toDouble(),
    ];

    if (normalizedValues.isNotEmpty) {
      final average =
          normalizedValues.reduce((sum, value) => sum + value) /
          normalizedValues.length;
      return _DerivedSimilarityStat(
        value: _formatSimilarityPercentValue(average),
        loading: false,
        score: average,
      );
    }
  }

  final normalizedValues = <double>[
    ..._normalizedSimilarityValues(
      pixelMatchMetric,
      transform: (value) => value.clamp(0, 100).toDouble(),
    ),
    ..._normalizedSimilarityValues(
      msSsimMetric,
      transform: (value) => (value * 100).clamp(0, 100).toDouble(),
    ),
    ..._normalizedSimilarityValues(
      ssimulacra2Metric,
      transform: (value) => value.clamp(0, 100).toDouble(),
    ),
  ];

  if (normalizedValues.isNotEmpty) {
    final average =
        normalizedValues.reduce((sum, value) => sum + value) /
        normalizedValues.length;
    final isLoading =
        pixelMatchMetric.isLoading ||
        msSsimMetric.isLoading ||
        ssimulacra2Metric.isLoading;
    return _DerivedSimilarityStat(
      value: '${isLoading ? '~' : ''}${_formatSimilarityPercentValue(average)}',
      loading: false,
      score: average,
    );
  }

  final isLoading =
      pixelMatchMetric.isLoading ||
      msSsimMetric.isLoading ||
      ssimulacra2Metric.isLoading;
  return _DerivedSimilarityStat(value: isLoading ? '—' : 'N/A', loading: false);
}

Iterable<double> _normalizedSimilarityValues(
  AsyncValue<PreviewMetricResult?> metric, {
  required double Function(double value) transform,
}) sync* {
  final result = metric.asData?.value;
  final value = result?.value;
  if (value == null) {
    return;
  }
  yield transform(value);
}

class _BottomStatData {
  const _BottomStatData({
    required this.label,
    required this.value,
    required this.color,
    this.alternateValue,
    this.colorScore,
    this.colorMode = _BottomStatColorMode.none,
    this.loading = false,
    this.toggleable = false,
    this.tooltip,
  });

  final String label;
  final String value;
  final Color color;
  final String? alternateValue;
  final double? colorScore;
  final _BottomStatColorMode colorMode;
  final bool loading;
  final bool toggleable;
  final String? tooltip;
}

enum _BottomStatColorMode { none, fileSize, similarity, savings }

class _BottomInfoRowData {
  const _BottomInfoRowData({
    required this.label,
    required this.value,
    this.key,
    this.rowKey,
    this.bitsPerPixelValue,
    this.supportsBitsPerPixelColors = false,
    this.highlightOnValueChange = false,
  });

  final String label;
  final String value;
  final String? key;
  final String? rowKey;
  final double? bitsPerPixelValue;
  final bool supportsBitsPerPixelColors;
  final bool highlightOnValueChange;
}

int? _effectiveFileSizeBytes(OpenedImageFile file) {
  return file.lastResult?.newSize.toInt() ?? file.metadata.fileSize?.toInt();
}

int? _originalFileSizeBytes(OpenedImageFile file) {
  return file.lastResult?.originalSize.toInt() ??
      file.metadata.fileSize?.toInt();
}

int? _aggregateFolderBytes(
  List<OpenedImageFile> files, {
  required bool useOriginalSizes,
}) {
  var hasSize = false;
  var totalBytes = 0;

  for (final file in files) {
    final bytes = useOriginalSizes
        ? _originalFileSizeBytes(file)
        : _effectiveFileSizeBytes(file);
    if (bytes == null) {
      continue;
    }
    hasSize = true;
    totalBytes += bytes;
  }

  return hasSize ? totalBytes : null;
}

double? _aggregateFolderBpp(
  List<OpenedImageFile> files, {
  required bool useOriginalSizes,
}) {
  var totalBytes = 0;
  var totalPixels = 0;

  for (final file in files) {
    final bytes = useOriginalSizes
        ? _originalFileSizeBytes(file)
        : _effectiveFileSizeBytes(file);
    final width = useOriginalSizes
        ? file.metadata.width
        : (file.lastResult?.width ?? file.metadata.width);
    final height = useOriginalSizes
        ? file.metadata.height
        : (file.lastResult?.height ?? file.metadata.height);
    if (bytes == null || width <= 0 || height <= 0) {
      continue;
    }

    totalBytes += bytes;
    totalPixels += width * height;
  }

  if (totalBytes <= 0 || totalPixels <= 0) {
    return null;
  }

  return (totalBytes * 8) / totalPixels;
}

double? _bitsPerPixel({
  required int? bytes,
  required int width,
  required int height,
}) {
  if (bytes == null || bytes <= 0 || width <= 0 || height <= 0) {
    return null;
  }

  return (bytes * 8) / (width * height);
}

String _formatNullableBytes(int? bytes) {
  if (bytes == null) {
    return '—';
  }
  return _formatBytes(bytes);
}

String? _formatNullablePercent(double? value) {
  if (value == null) {
    return null;
  }
  if (value.toStringAsFixed(1) == '100.0') {
    return '100%';
  }
  return '${value.toStringAsFixed(1)}%';
}

String _formatNullablePercentValue(double? value) {
  return _formatNullablePercent(value) ?? '—';
}

String _formatSimilarityPercentValue(double? value) {
  if (value == null) {
    return '—';
  }

  final rounded = value.toStringAsFixed(1);
  if (rounded == '100.0') {
    return '100%';
  }

  return '$rounded%';
}

String _formatNullableBpp(double? value) {
  if (value == null) {
    return '—';
  }

  return value >= 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(2);
}

String _formatNullableMetric(
  double? value, {
  int digits = 3,
  bool trimIfHundred = false,
  bool trimIfOne = false,
}) {
  if (value == null) {
    return 'N/A';
  }

  final formatted = value.toStringAsFixed(digits);
  if (trimIfOne) {
    final wholeOne = '1.${'0' * digits}';
    if (formatted == wholeOne && digits > 0) {
      return '1.${'0' * (digits - 1)}';
    }
  }
  if (trimIfHundred) {
    final wholeHundred = '100.${'0' * digits}';
    if (formatted == wholeHundred) {
      return '100';
    }
  }
  return formatted;
}

String _formatNullableMetricPercent(double? value) {
  return _formatNullablePercent(value) ?? 'N/A';
}

String _formatSavingsRatio(int? originalBytes, int? newBytes) {
  if (originalBytes == null ||
      newBytes == null ||
      originalBytes <= 0 ||
      newBytes <= 0) {
    return '—';
  }

  final ratio = originalBytes / newBytes;
  return '${ratio.toStringAsFixed(1)}x';
}

String _formatMetricTimingTooltip(int elapsedMilliseconds) {
  if (elapsedMilliseconds >= 1000) {
    final seconds = elapsedMilliseconds / 1000;
    return '${seconds.toStringAsFixed(1)} s';
  }

  return '$elapsedMilliseconds ms';
}

String _formatMegapixels(int width, int height) {
  final megapixels = (width * height) / 1000000;
  return '${megapixels.toStringAsFixed(1)} MP';
}

bool _isAnalyzeSelectionEvent(FlTouchEvent event) {
  return event.isInterestedForInteractions;
}

bool _isAnalyzeCommitEvent(FlTouchEvent event) {
  return event is FlTapDownEvent;
}

bool _isTerminalStatus(OptimizationItemStatus status) {
  return switch (status) {
    OptimizationItemStatus.written ||
    OptimizationItemStatus.skipped ||
    OptimizationItemStatus.failed ||
    OptimizationItemStatus.canceled => true,
    OptimizationItemStatus.idle ||
    OptimizationItemStatus.queued ||
    OptimizationItemStatus.running => false,
  };
}

OptimizationItemState _statusForFile(
  OpenedImageFile file,
  OptimizationRunState runState,
) {
  final direct = runState.items[file.path];
  if (direct != null) {
    return direct;
  }

  if (file.lastError != null) {
    return OptimizationItemState(
      status: OptimizationItemStatus.failed,
      message: file.lastError,
    );
  }

  if (file.lastResult != null) {
    return OptimizationItemState(
      status: file.lastResult!.didWrite
          ? OptimizationItemStatus.written
          : OptimizationItemStatus.skipped,
      result: file.lastResult,
    );
  }

  return const OptimizationItemState(status: OptimizationItemStatus.idle);
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(label).xSmall().medium().muted();
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Basic(title: Text(title).small().medium());
  }
}

class _StorageDestinationCard extends StatelessWidget {
  const _StorageDestinationCard({
    required this.value,
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final StorageDestinationMode value;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: IgnorePointer(
        child: RadioCard<StorageDestinationMode>(
          value: value,
          enabled: enabled,
          child: child,
        ),
      ),
    );
  }
}

extension on Widget {
  Widget mediumIf(bool condition) {
    if (!condition) {
      return this;
    }
    return medium();
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  final fractionDigits = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}

String? _fileSizeLabel(OpenedImageFile file) {
  final bytes = file.metadata.fileSize?.toInt();
  if (bytes == null) {
    return null;
  }
  return _formatBytes(bytes);
}

String? _folderSizeLabel(List<OpenedImageFile> files) {
  var hasSize = false;
  var totalBytes = 0;
  for (final file in files) {
    final bytes = file.metadata.fileSize?.toInt();
    if (bytes == null) {
      continue;
    }
    hasSize = true;
    totalBytes += bytes;
  }
  if (!hasSize) {
    return null;
  }
  return _formatBytes(totalBytes);
}

String? _showInFileManagerLabel() {
  if (Platform.isMacOS) {
    return 'Show in Finder';
  }
  if (Platform.isWindows) {
    return 'Show in File Explorer';
  }
  if (Platform.isLinux) {
    return 'Show in File Manager';
  }
  return null;
}

String _qualityValueLabel(AppSettings settings) {
  if (settings.quality == 100 && settings.qualitySupportsLosslessAtMax) {
    return 'Lossless';
  }

  return '${settings.quality}';
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  Future<void> _browseFiles(BuildContext context, WidgetRef ref) async {
    await ref.read(fileOpenControllerProvider).pickFilesAndOpen();
  }

  Future<void> _browseFolder(BuildContext context, WidgetRef ref) async {
    await ref.read(fileOpenControllerProvider).pickFolderAndOpen();
  }

  void _showBrowseMenu(BuildContext context, WidgetRef ref) {
    showDropdown(
      context: context,
      builder: (context) {
        return DropdownMenu(
          children: [
            MenuButton(
              key: const ValueKey('empty-state-open-files'),
              leading: const Icon(LucideIcons.images, size: 16),
              onPressed: (context) {
                unawaited(_browseFiles(context, ref));
              },
              child: const Text('Open Files…'),
            ),
            MenuButton(
              key: const ValueKey('empty-state-open-folder'),
              leading: const Icon(LucideIcons.folderOpen, size: 16),
              onPressed: (context) {
                unawaited(_browseFolder(context, ref));
              },
              child: const Text('Open Folder…'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 920;

              final hero = Container(
                decoration: BoxDecoration(
                  borderRadius: theme.borderRadiusXxl,
                  border: Border.all(
                    color: theme.colorScheme.border.withValues(alpha: 0.7),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.background,
                      theme.colorScheme.primary.withValues(alpha: 0.06),
                      theme.colorScheme.secondary.withValues(alpha: 0.42),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      blurRadius: 42,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: -56,
                      right: -42,
                      child: Container(
                        width: 210,
                        height: 210,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.1,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -80,
                      left: -28,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.secondaryForeground
                              .withValues(alpha: 0.05),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Optimize your images easily',
                            style: TextStyle(
                              fontSize: 31,
                              height: 1.08,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.9,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'OIMG helps you choose the optimal image format and settings.',
                            style: TextStyle(
                              color: theme.colorScheme.mutedForeground,
                              fontSize: 13.6,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 26),
                          Row(
                            children: [
                              PrimaryButton(
                                key: const ValueKey(
                                  'empty-state-browse-button',
                                ),
                                onPressed: () => _showBrowseMenu(context, ref),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(LucideIcons.folderSearch, size: 16),
                                    SizedBox(width: 8),
                                    Text('Browse…'),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'or drop files and folders anywhere',
                                style: TextStyle(
                                  color: theme.colorScheme.mutedForeground,
                                ),
                              ).small(),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );

              final supportCards = const [
                _EmptyStateFeatureCard(
                  icon: LucideIcons.sparkles,
                  title: 'Preview',
                  description:
                      'Inspect the optimized images before you hit save.',
                ),
                _EmptyStateFeatureCard(
                  icon: LucideIcons.badgePercent,
                  title: 'Compare',
                  description:
                      'See how different image formats compare in savings, quality, and compatibility.',
                ),
                _EmptyStateFeatureCard(
                  icon: LucideIcons.chartSpline,
                  title: 'Analyze',
                  description:
                      'Explore the balance between size and quality using state-of-the-art image quality analysis methods.',
                ),
              ];

              final support = wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: supportCards[0]),
                        const SizedBox(width: 14),
                        Expanded(child: supportCards[1]),
                        const SizedBox(width: 14),
                        Expanded(child: supportCards[2]),
                      ],
                    )
                  : Column(
                      children: [
                        supportCards[0],
                        const SizedBox(height: 14),
                        supportCards[1],
                        const SizedBox(height: 14),
                        supportCards[2],
                      ],
                    );

              return Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: theme.borderRadiusXxl,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            theme.colorScheme.background,
                            theme.colorScheme.secondary.withValues(alpha: 0.32),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 28,
                    top: 24,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.05,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 54,
                    bottom: 20,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.secondaryForeground.withValues(
                          alpha: 0.04,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.8,
                          ),
                          child: hero,
                        ),
                        const SizedBox(height: 18),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.85,
                          ),
                          child: support,
                        ),
                        const SizedBox(height: 44),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 28,
                    bottom: 24,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlineButton(
                          key: const ValueKey('empty-state-github-button'),
                          onPressed: () async {
                            await launchUrl(
                              Uri.parse('https://github.com/yunho-c/oimg'),
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(LucideIcons.github, size: 15),
                              SizedBox(width: 8),
                              Text('GitHub'),
                            ],
                          ),
                        ),
                        OutlineButton(
                          key: const ValueKey('empty-state-feedback-button'),
                          onPressed: () {},
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(LucideIcons.messageSquare, size: 15),
                              SizedBox(width: 8),
                              Text('Feedback'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String? _transparencyWarningText({
  required AppSettings settings,
  required OpenedImageFile? file,
}) {
  if (file == null || !file.metadata.hasTransparency) {
    return null;
  }

  final codec = settings.effectiveCodec;
  if (codec.supportsTransparency) {
    return null;
  }

  return '${codecLabel(codec)} does not support transparency. Transparent areas will be flattened.';
}

String? _optimizedPreviewSizeWarningText({
  required FileOpenController controller,
  required OpenedImageFile? file,
  required OptimizedPreviewDisplay? optimizedDisplay,
}) {
  if (controller.isFolderSelected || file == null || optimizedDisplay == null) {
    return null;
  }

  final originalBytes = _originalFileSizeBytes(file);
  if (originalBytes == null) {
    return null;
  }

  return optimizedDisplay.sizeBytes.toInt() > originalBytes
      ? 'Original image is smaller.'
      : null;
}

class _SettingsWarningBlock extends StatelessWidget {
  const _SettingsWarningBlock({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const warningTint = Color(0xFFC75A5A);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          warningTint.withValues(alpha: 0.08),
          theme.colorScheme.background.withValues(alpha: 0.94),
        ),
        borderRadius: theme.borderRadiusLg,
        border: Border.all(
          color: Color.alphaBlend(
            warningTint.withValues(alpha: 0.18),
            theme.colorScheme.border.withValues(alpha: 0.92),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: warningTint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.mutedForeground,
                height: 1.4,
              ),
            ).small(),
          ),
        ],
      ),
    );
  }
}

class _EmptyStateFeatureCard extends StatelessWidget {
  const _EmptyStateFeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      borderRadius: theme.borderRadiusXl,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: theme.borderRadiusLg,
              ),
              child: Icon(icon, size: 18, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title).medium(),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(
                      color: theme.colorScheme.mutedForeground,
                      height: 1.45,
                    ),
                  ).small(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
