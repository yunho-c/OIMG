import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';
import 'package:oimg/src/file_open/file_open_providers.dart';
import 'package:oimg/src/file_open/opened_image_file.dart';
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:oimg/src/settings/app_settings.dart';
import 'package:oimg/src/settings/app_settings_controller.dart';
import 'package:oimg/src/settings/developer_diagnostics.dart';

import 'optimization_plan.dart';

final slimgApiProvider = Provider<SlimgApi>((ref) => const FrbSlimgApi());

final gjxlBackendCompiledProvider = Provider<bool>(
  (ref) => ref.watch(slimgApiProvider).gjxlBackendCompiled(),
);

class JxlEncoderPreferenceNotifier extends Notifier<JxlEncoderPreference> {
  @override
  JxlEncoderPreference build() => JxlEncoderPreference.libjxl;

  void setPreferGjxl(bool enabled) {
    state = enabled
        ? JxlEncoderPreference.preferGjxl
        : JxlEncoderPreference.libjxl;
  }
}

final jxlEncoderPreferenceProvider =
    NotifierProvider<JxlEncoderPreferenceNotifier, JxlEncoderPreference>(
      JxlEncoderPreferenceNotifier.new,
    );
int _previewRequestSequence = 0;
int _previewDifferenceRequestSequence = 0;
int _previewPixelMatchRequestSequence = 0;
int _previewMsSsimRequestSequence = 0;
int _previewSsimulacra2RequestSequence = 0;
int _analyzeRequestSequence = 0;
const List<int> _analyzeSweepQualities = <int>[
  0,
  10,
  20,
  30,
  40,
  50,
  60,
  70,
  80,
  90,
  100,
];
const int _previewCacheBudgetBytes = 128 * 1024 * 1024;
const int _previewDecodedImageBudget = 2;
const int _previewCacheEntryOverheadBytes = 4 * 1024;

enum PreviewDisplayMode { original, optimized, difference }

enum _PreviewMetricKind { pixelMatch, msSsim, ssimulacra2 }

class _PreviewCacheKey {
  const _PreviewCacheKey({required this.filePath, required this.operation});

  final String filePath;
  final ImageOperation operation;

  @override
  int get hashCode => Object.hash(filePath, operation);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PreviewCacheKey &&
          runtimeType == other.runtimeType &&
          filePath == other.filePath &&
          operation == other.operation;
}

class _PreviewMetricCacheSlot {
  const _PreviewMetricCacheSlot({required this.hasValue, this.result});

  final bool hasValue;
  final PreviewMetricResult? result;
}

class _PreviewCacheEntry {
  _PreviewCacheEntry({required this.key, required this.preview});

  final _PreviewCacheKey key;
  final OptimizationPreview preview;

  _PreviewMetricCacheSlot _pixelMatch = const _PreviewMetricCacheSlot(
    hasValue: false,
  );
  _PreviewMetricCacheSlot _msSsim = const _PreviewMetricCacheSlot(
    hasValue: false,
  );
  _PreviewMetricCacheSlot _ssimulacra2 = const _PreviewMetricCacheSlot(
    hasValue: false,
  );
  bool hasResolvedDifference = false;
  bool differenceAvailable = false;
  RawImageResult? differenceRawImage;
  ui.Image? differenceImage;

  String get artifactId => preview.result.artifactId;

  _PreviewMetricCacheSlot metric(_PreviewMetricKind kind) {
    return switch (kind) {
      _PreviewMetricKind.pixelMatch => _pixelMatch,
      _PreviewMetricKind.msSsim => _msSsim,
      _PreviewMetricKind.ssimulacra2 => _ssimulacra2,
    };
  }

  void setMetric(_PreviewMetricKind kind, PreviewMetricResult? result) {
    final slot = _PreviewMetricCacheSlot(hasValue: true, result: result);
    switch (kind) {
      case _PreviewMetricKind.pixelMatch:
        _pixelMatch = slot;
      case _PreviewMetricKind.msSsim:
        _msSsim = slot;
      case _PreviewMetricKind.ssimulacra2:
        _ssimulacra2 = slot;
    }
  }

  int estimatedBytes() {
    final originalRgbaBytes =
        preview.sourceFile.metadata.width *
        preview.sourceFile.metadata.height *
        4;
    final previewRgbaBytes = preview.result.width * preview.result.height * 4;
    final encodedBytes = preview.result.encodedBytes.length;
    final rawDifferenceBytes = differenceRawImage?.rgbaBytes.length ?? 0;
    final differenceBytes = differenceImage == null
        ? 0
        : preview.result.width * preview.result.height * 4;
    return _previewCacheEntryOverheadBytes +
        originalRgbaBytes +
        previewRgbaBytes +
        encodedBytes +
        rawDifferenceBytes +
        differenceBytes;
  }

  void disposeImages() {
    differenceImage?.dispose();
    differenceImage = null;
  }
}

class _PreviewCacheController {
  _PreviewCacheController(this._slimgApi);

  final SlimgApi _slimgApi;
  final LinkedHashMap<_PreviewCacheKey, _PreviewCacheEntry> _entries =
      LinkedHashMap<_PreviewCacheKey, _PreviewCacheEntry>();
  final LinkedHashSet<_PreviewCacheKey> _differenceImageKeys =
      LinkedHashSet<_PreviewCacheKey>();

  OptimizationPreview? getPreview(_PreviewCacheKey key) {
    final entry = _touchEntry(key);
    return entry?.preview;
  }

  PreviewMetricResult? getMetric(
    _PreviewCacheKey key,
    _PreviewMetricKind metric,
  ) {
    final entry = _touchEntry(key);
    if (entry == null) {
      return null;
    }
    final slot = entry.metric(metric);
    return slot.hasValue ? slot.result : null;
  }

  bool hasMetric(_PreviewCacheKey key, _PreviewMetricKind metric) {
    return _entries[key]?.metric(metric).hasValue ?? false;
  }

  void cacheMetric(
    _PreviewCacheKey key,
    _PreviewMetricKind metric,
    PreviewMetricResult? result,
  ) {
    final entry = _touchEntry(key);
    if (entry == null) {
      return;
    }
    entry.setMetric(metric, result);
    _evictEntriesIfNeeded();
  }

  ui.Image? getDifferenceImage(_PreviewCacheKey key) {
    final entry = _touchEntry(key);
    if (entry == null ||
        !entry.hasResolvedDifference ||
        !entry.differenceAvailable) {
      return null;
    }
    final image = entry.differenceImage;
    if (image != null) {
      _touchDifferenceImage(key);
    }
    return image;
  }

  RawImageResult? getDifferenceRawImage(_PreviewCacheKey key) {
    final entry = _touchEntry(key);
    if (entry == null ||
        !entry.hasResolvedDifference ||
        !entry.differenceAvailable) {
      return null;
    }
    return entry.differenceRawImage;
  }

  bool hasResolvedDifference(_PreviewCacheKey key) {
    return _entries[key]?.hasResolvedDifference ?? false;
  }

  bool isDifferenceUnavailable(_PreviewCacheKey key) {
    final entry = _entries[key];
    return entry != null &&
        entry.hasResolvedDifference &&
        !entry.differenceAvailable;
  }

  void cacheDifferenceUnavailable(_PreviewCacheKey key) {
    final entry = _touchEntry(key);
    if (entry == null) {
      return;
    }
    entry.hasResolvedDifference = true;
    entry.differenceAvailable = false;
    entry.differenceRawImage = null;
    entry.disposeImages();
    _differenceImageKeys.remove(key);
    _evictEntriesIfNeeded();
  }

  void cacheDifferenceRawImage(_PreviewCacheKey key, RawImageResult result) {
    final entry = _touchEntry(key);
    if (entry == null) {
      return;
    }
    entry.hasResolvedDifference = true;
    entry.differenceAvailable = true;
    entry.differenceRawImage = result;
    _evictEntriesIfNeeded();
  }

  void cacheDifferenceImage(_PreviewCacheKey key, ui.Image image) {
    final entry = _touchEntry(key);
    if (entry == null) {
      image.dispose();
      return;
    }
    if (!identical(entry.differenceImage, image)) {
      entry.differenceImage?.dispose();
    }
    entry.hasResolvedDifference = true;
    entry.differenceAvailable = true;
    entry.differenceImage = image;
    _touchDifferenceImage(key);
    _evictDecodedImagesIfNeeded();
    _evictEntriesIfNeeded();
  }

  void cachePreview(_PreviewCacheKey key, OptimizationPreview preview) {
    final previous = _entries.remove(key);
    if (previous != null && previous.artifactId != preview.result.artifactId) {
      previous.disposeImages();
      _differenceImageKeys.remove(key);
      _disposeArtifact(previous.artifactId);
    }

    _entries[key] = _PreviewCacheEntry(key: key, preview: preview);
    _evictEntriesIfNeeded();
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.disposeImages();
      _disposeArtifact(entry.artifactId);
    }
    _entries.clear();
    _differenceImageKeys.clear();
  }

  _PreviewCacheEntry? _touchEntry(_PreviewCacheKey key) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    _entries[key] = entry;
    return entry;
  }

  void _touchDifferenceImage(_PreviewCacheKey key) {
    _differenceImageKeys.remove(key);
    _differenceImageKeys.add(key);
  }

  void _evictEntriesIfNeeded() {
    while (_estimatedTotalBytes() > _previewCacheBudgetBytes &&
        _entries.length > 1) {
      final key = _entries.keys.first;
      final entry = _entries.remove(key);
      if (entry == null) {
        continue;
      }
      _differenceImageKeys.remove(key);
      entry.disposeImages();
      _disposeArtifact(entry.artifactId);
    }
  }

  void _evictDecodedImagesIfNeeded() {
    while (_differenceImageKeys.length > _previewDecodedImageBudget) {
      final key = _differenceImageKeys.first;
      _differenceImageKeys.remove(key);
      final entry = _entries[key];
      entry?.differenceImage?.dispose();
      if (entry != null) {
        entry.differenceImage = null;
      }
    }
  }

  int _estimatedTotalBytes() {
    return _entries.values.fold<int>(
      0,
      (sum, entry) => sum + entry.estimatedBytes(),
    );
  }

  void _disposeArtifact(String artifactId) {
    unawaited(
      _slimgApi.disposePreviewArtifact(artifactId: artifactId).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DeveloperDiagnostics.logTimingError(
          'preview-artifact-dispose-cache',
          error,
          stackTrace,
        );
      }),
    );
  }
}

class PreviewDisplaySelection {
  const PreviewDisplaySelection({required this.filePath, required this.mode});

  final String filePath;
  final PreviewDisplayMode mode;
}

class PreviewDisplaySelectionNotifier
    extends Notifier<PreviewDisplaySelection?> {
  @override
  PreviewDisplaySelection? build() => null;

  void select({required String filePath, required PreviewDisplayMode mode}) {
    state = PreviewDisplaySelection(filePath: filePath, mode: mode);
  }
}

class PreviewDifferenceRequestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void requestForArtifact(String artifactId) {
    state = artifactId;
  }
}

class AnalyzeConfig {
  const AnalyzeConfig({required this.inputPath, required this.operation});

  final String inputPath;
  final ImageOperation operation;

  AnalyzeConfig get normalizedContext => AnalyzeConfig(
    inputPath: inputPath,
    operation: _normalizeAnalyzeOperation(operation),
  );

  AnalyzeFileRequest toRequest() {
    return AnalyzeFileRequest(
      inputPath: inputPath,
      operation: operation,
      qualities: Uint8List.fromList(_analyzeSweepQualities),
    );
  }

  @override
  int get hashCode => Object.hash(inputPath, operation);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnalyzeConfig &&
          runtimeType == other.runtimeType &&
          inputPath == other.inputPath &&
          operation == other.operation;
}

ImageOperation _normalizeAnalyzeOperation(ImageOperation operation) {
  return operation.when(
    convert: (options) => ImageOperation.convert(
      ConvertOptions(
        targetFormat: options.targetFormat,
        quality: 0,
        effort: options.effort,
        pngPalette: options.pngPalette,
        jxlEncoder: options.jxlEncoder,
      ),
    ),
    optimize: (options) => ImageOperation.optimize(
      OptimizeOptions(
        quality: 0,
        effort: options.effort,
        pngPalette: options.pngPalette,
        jxlEncoder: options.jxlEncoder,
        writeOnlyIfSmaller: options.writeOnlyIfSmaller,
      ),
    ),
    resize: (options) => ImageOperation.resize(
      ResizeOptions(
        resize: options.resize,
        targetFormat: options.targetFormat,
        quality: 0,
        effort: options.effort,
        pngPalette: options.pngPalette,
        jxlEncoder: options.jxlEncoder,
      ),
    ),
    crop: (options) => ImageOperation.crop(
      CropOptions(
        crop: options.crop,
        targetFormat: options.targetFormat,
        quality: 0,
        effort: options.effort,
        pngPalette: options.pngPalette,
        jxlEncoder: options.jxlEncoder,
      ),
    ),
    extend: (options) => ImageOperation.extend(
      ExtendOptions(
        extend: options.extend,
        fill: options.fill,
        targetFormat: options.targetFormat,
        quality: 0,
        effort: options.effort,
        pngPalette: options.pngPalette,
        jxlEncoder: options.jxlEncoder,
      ),
    ),
  );
}

enum AnalyzeAvailabilityStatus { loading, disabled, enabled }

class AnalyzeAvailability {
  const AnalyzeAvailability._({required this.status, this.reason, this.config});

  const AnalyzeAvailability.loading()
    : this._(status: AnalyzeAvailabilityStatus.loading);

  const AnalyzeAvailability.disabled(String reason)
    : this._(status: AnalyzeAvailabilityStatus.disabled, reason: reason);

  const AnalyzeAvailability.enabled(AnalyzeConfig config)
    : this._(status: AnalyzeAvailabilityStatus.enabled, config: config);

  final AnalyzeAvailabilityStatus status;
  final String? reason;
  final AnalyzeConfig? config;

  bool get isEnabled => status == AnalyzeAvailabilityStatus.enabled;
}

class OptimizedPreviewDisplay {
  const OptimizedPreviewDisplay({
    required this.artifactId,
    required this.format,
    required this.width,
    required this.height,
    required this.sizeBytes,
    this.encodedBytes,
    this.outputPath,
  });

  final String artifactId;
  final String format;
  final int width;
  final int height;
  final BigInt sizeBytes;
  final Uint8List? encodedBytes;
  final String? outputPath;

  bool get usesOutputPath => outputPath != null;
}

class PreviewMetricResult {
  const PreviewMetricResult({
    required this.value,
    required this.elapsedMilliseconds,
  });

  final double? value;
  final int elapsedMilliseconds;
}

class AnalyzeRunState {
  const AnalyzeRunState({
    required this.availability,
    this.contextConfig,
    this.jobId,
    this.jobState,
    this.completedCount = 0,
    this.totalCount = 0,
    this.currentQuality,
    this.samples = const <AnalyzeSampleResult>[],
    this.selectedArtifactId,
    this.hoveredArtifactId,
    this.globalError,
    this.isChartVisible = true,
  });

  final AnalyzeAvailability availability;
  final AnalyzeConfig? contextConfig;
  final String? jobId;
  final BatchJobState? jobState;
  final int completedCount;
  final int totalCount;
  final int? currentQuality;
  final List<AnalyzeSampleResult> samples;
  final String? selectedArtifactId;
  final String? hoveredArtifactId;
  final String? globalError;
  final bool isChartVisible;

  bool get isRunning =>
      jobState == BatchJobState.running ||
      jobState == BatchJobState.cancelRequested;

  bool get isCancelRequested => jobState == BatchJobState.cancelRequested;

  String? get activeArtifactId => hoveredArtifactId ?? selectedArtifactId;

  AnalyzeSampleResult? get selectedSample {
    final artifactId = activeArtifactId;
    if (artifactId == null) {
      return null;
    }
    for (final sample in samples) {
      if (sample.artifactId == artifactId) {
        return sample;
      }
    }
    return null;
  }

  AnalyzeRunState copyWith({
    AnalyzeAvailability? availability,
    AnalyzeConfig? contextConfig,
    String? jobId,
    BatchJobState? jobState,
    int? completedCount,
    int? totalCount,
    int? currentQuality,
    List<AnalyzeSampleResult>? samples,
    String? selectedArtifactId,
    String? hoveredArtifactId,
    String? globalError,
    bool? isChartVisible,
    bool clearJobId = false,
    bool clearJobState = false,
    bool clearCurrentQuality = false,
    bool clearSelectedArtifactId = false,
    bool clearHoveredArtifactId = false,
    bool clearGlobalError = false,
  }) {
    return AnalyzeRunState(
      availability: availability ?? this.availability,
      contextConfig: contextConfig ?? this.contextConfig,
      jobId: clearJobId ? null : (jobId ?? this.jobId),
      jobState: clearJobState ? null : (jobState ?? this.jobState),
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      currentQuality: clearCurrentQuality
          ? null
          : (currentQuality ?? this.currentQuality),
      samples: samples ?? this.samples,
      selectedArtifactId: clearSelectedArtifactId
          ? null
          : (selectedArtifactId ?? this.selectedArtifactId),
      hoveredArtifactId: clearHoveredArtifactId
          ? null
          : (hoveredArtifactId ?? this.hoveredArtifactId),
      globalError: clearGlobalError ? null : (globalError ?? this.globalError),
      isChartVisible: isChartVisible ?? this.isChartVisible,
    );
  }
}

class _PreviewArtifactContext {
  const _PreviewArtifactContext({
    required this.request,
    required this.cacheKey,
  });

  final PreviewArtifactRequest request;
  final _PreviewCacheKey? cacheKey;
}

class PreviewDifferenceFrame {
  const PreviewDifferenceFrame({required this.image, required this.rawImage});

  final ui.Image image;
  final RawImageResult rawImage;
}

class DifferenceErrorStats {
  const DifferenceErrorStats({
    required this.mean,
    required this.top10Percent,
    required this.top1Percent,
  });

  final double mean;
  final double top10Percent;
  final double top1Percent;
}

final _previewCacheControllerProvider = Provider<_PreviewCacheController>((
  ref,
) {
  final controller = _PreviewCacheController(ref.read(slimgApiProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

final currentOptimizationPlanProvider =
    FutureProvider.autoDispose<OptimizationPlan?>((ref) async {
      final controller = ref.watch(fileOpenControllerProvider);
      final currentFile = controller.currentFile;
      if (currentFile == null) {
        return null;
      }

      final settings = await ref.watch(appSettingsProvider.future);
      final jxlEncoder = ref.watch(jxlEncoderPreferenceProvider);
      return buildOptimizationPlan(
        file: currentFile,
        settings: settings,
        jxlEncoder: jxlEncoder,
      );
    });

final analyzeAvailabilityProvider = Provider.autoDispose<AnalyzeAvailability>((
  ref,
) {
  final controller = ref.watch(fileOpenControllerProvider);
  if (controller.isFolderSelected) {
    return const AnalyzeAvailability.disabled('Select a file to analyze.');
  }

  final currentFile = controller.currentFile;
  if (currentFile == null) {
    return const AnalyzeAvailability.disabled('Select a file to analyze.');
  }

  final settings = ref.watch(appSettingsProvider);
  final plan = ref.watch(currentOptimizationPlanProvider);
  final settingsData = settings.asData?.value;
  final planData = plan.asData?.value;

  if (settings.isLoading || plan.isLoading) {
    return const AnalyzeAvailability.loading();
  }
  if (settings.hasError ||
      plan.hasError ||
      settingsData == null ||
      planData == null) {
    return const AnalyzeAvailability.disabled('Unavailable right now.');
  }
  if (!settingsData.showsQualityControl) {
    return const AnalyzeAvailability.disabled('Unavailable for this format.');
  }
  if (planData.targetCodec == PreferredCodec.png) {
    return const AnalyzeAvailability.disabled('Unavailable for PNG.');
  }

  return AnalyzeAvailability.enabled(
    AnalyzeConfig(
      inputPath: planData.sourceFile.path,
      operation: planData.processRequest.operation,
    ),
  );
});

final analyzeRunControllerProvider =
    NotifierProvider<AnalyzeRunController, AnalyzeRunState>(
      AnalyzeRunController.new,
    );

class AnalyzeRunController extends Notifier<AnalyzeRunState> {
  String? _activeJobId;
  bool _didBuild = false;
  bool _didRegisterDispose = false;

  @override
  AnalyzeRunState build() {
    final availability = ref.watch(analyzeAvailabilityProvider);
    if (!_didRegisterDispose) {
      _didRegisterDispose = true;
      ref.onDispose(() {
        final jobId = _activeJobId;
        if (jobId != null) {
          unawaited(_disposeJob(jobId));
        }
      });
    }
    if (!_didBuild) {
      _didBuild = true;
      return AnalyzeRunState(
        availability: availability,
        contextConfig: availability.config?.normalizedContext,
      );
    }
    return _rebaseAnalyzeState(state, availability);
  }

  AnalyzeRunState _rebaseAnalyzeState(
    AnalyzeRunState previous,
    AnalyzeAvailability availability,
  ) {
    final nextContextConfig = availability.config?.normalizedContext;

    if (availability.status == AnalyzeAvailabilityStatus.loading) {
      return previous.copyWith(availability: availability);
    }

    if (previous.contextConfig == nextContextConfig) {
      return previous.copyWith(
        availability: availability,
        contextConfig: nextContextConfig,
      );
    }

    final isEmptyIdleState =
        previous.contextConfig == null &&
        previous.jobId == null &&
        previous.samples.isEmpty &&
        previous.selectedArtifactId == null &&
        previous.hoveredArtifactId == null &&
        previous.globalError == null;
    if (isEmptyIdleState) {
      return previous.copyWith(
        availability: availability,
        contextConfig: nextContextConfig,
      );
    }

    if (previous.jobId case final jobId?) {
      _activeJobId = null;
      unawaited(_disposeJob(jobId));
    }

    return AnalyzeRunState(
      availability: availability,
      contextConfig: nextContextConfig,
    );
  }

  Future<void> startAnalyze() async {
    if (state.isRunning || !state.availability.isEnabled) {
      return;
    }

    final config = state.availability.config;
    if (config == null) {
      return;
    }

    if (state.jobId case final existingJobId?) {
      await _disposeJob(existingJobId);
    }

    final requestId = ++_analyzeRequestSequence;
    DeveloperDiagnostics.logTiming(
      'analyze:$requestId',
      'start input=${config.inputPath}',
    );

    try {
      final handle = await ref
          .read(slimgApiProvider)
          .startAnalyzeFileJob(request: config.toRequest());
      state = AnalyzeRunState(
        availability: state.availability,
        contextConfig: state.contextConfig,
        jobId: handle.jobId,
        jobState: BatchJobState.running,
        totalCount: _analyzeSweepQualities.length,
      );
      _activeJobId = handle.jobId;
      unawaited(_pollJob(handle.jobId, requestId));
    } on Object catch (error, stackTrace) {
      DeveloperDiagnostics.logTimingError(
        'analyze:$requestId',
        error,
        stackTrace,
      );
      _activeJobId = null;
      state = AnalyzeRunState(
        availability: state.availability,
        contextConfig: state.contextConfig,
        globalError: error.toString(),
      );
    }
  }

  Future<void> cancelAnalyze() async {
    if (!state.isRunning || state.isCancelRequested || state.jobId == null) {
      return;
    }

    final jobId = state.jobId!;
    state = state.copyWith(
      jobState: BatchJobState.cancelRequested,
      clearGlobalError: true,
    );
    await ref.read(slimgApiProvider).cancelAnalyzeFileJob(jobId: jobId);
  }

  void selectSample(AnalyzeSampleResult sample) {
    state = state.copyWith(
      selectedArtifactId: sample.artifactId,
      clearHoveredArtifactId: true,
    );
  }

  void hoverSample(AnalyzeSampleResult sample) {
    state = state.copyWith(hoveredArtifactId: sample.artifactId);
  }

  AnalyzeSampleResult? clearHoveredSample() {
    state = state.copyWith(clearHoveredArtifactId: true);
    return state.selectedSample;
  }

  void toggleChartVisibility() {
    if (state.isRunning || state.samples.isEmpty) {
      return;
    }
    state = state.copyWith(isChartVisible: !state.isChartVisible);
  }

  Future<void> _pollJob(String jobId, int requestId) async {
    while (state.jobId == jobId) {
      try {
        final snapshot = await ref
            .read(slimgApiProvider)
            .getAnalyzeFileJob(jobId: jobId);
        if (state.jobId != jobId) {
          return;
        }

        final priorSelection = state.selectedArtifactId;
        final autoSelectedArtifactId =
            !_isTerminalAnalyzeState(snapshot.state) &&
                snapshot.results.isNotEmpty
            ? snapshot.results.last.artifactId
            : null;
        final selectedArtifactId =
            autoSelectedArtifactId ??
            (priorSelection != null &&
                    snapshot.results.any(
                      (sample) => sample.artifactId == priorSelection,
                    )
                ? priorSelection
                : null);
        final priorHover = state.hoveredArtifactId;
        final hoveredArtifactId =
            priorHover != null &&
                snapshot.results.any(
                  (sample) => sample.artifactId == priorHover,
                )
            ? priorHover
            : null;

        state = state.copyWith(
          jobState: snapshot.state,
          completedCount: snapshot.completedCount,
          totalCount: snapshot.totalCount,
          currentQuality: snapshot.currentQuality,
          samples: snapshot.results,
          selectedArtifactId: selectedArtifactId,
          hoveredArtifactId: hoveredArtifactId,
          globalError: snapshot.error?.toString(),
        );

        if (_isTerminalAnalyzeState(snapshot.state)) {
          DeveloperDiagnostics.logTiming(
            'analyze:$requestId',
            'done state=${snapshot.state.name} completed=${snapshot.completedCount}/${snapshot.totalCount}',
          );
          return;
        }
      } on Object catch (error, stackTrace) {
        DeveloperDiagnostics.logTimingError(
          'analyze:$requestId',
          error,
          stackTrace,
        );
        state = AnalyzeRunState(
          availability: state.availability,
          contextConfig: state.contextConfig,
          samples: state.samples,
          selectedArtifactId: state.selectedArtifactId,
          hoveredArtifactId: state.hoveredArtifactId,
          globalError: error.toString(),
        );
        _activeJobId = null;
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 140));
    }
  }

  Future<void> _disposeJob(String jobId) async {
    try {
      await ref.read(slimgApiProvider).disposeAnalyzeFileJob(jobId: jobId);
    } on Object catch (error, stackTrace) {
      DeveloperDiagnostics.logTimingError('analyze-dispose', error, stackTrace);
    } finally {
      if (_activeJobId == jobId) {
        _activeJobId = null;
      }
    }
  }
}

bool _isTerminalAnalyzeState(BatchJobState state) {
  return switch (state) {
    BatchJobState.completed ||
    BatchJobState.canceled ||
    BatchJobState.failed => true,
    _ => false,
  };
}

final selectedAnalyzeSampleProvider = Provider<AnalyzeSampleResult?>((ref) {
  return ref.watch(analyzeRunControllerProvider).selectedSample;
});

final currentOptimizedDisplayProvider =
    Provider.autoDispose<OptimizedPreviewDisplay?>((ref) {
      final selectedAnalyzeSample = ref.watch(selectedAnalyzeSampleProvider);
      if (selectedAnalyzeSample != null) {
        return OptimizedPreviewDisplay(
          artifactId: selectedAnalyzeSample.artifactId,
          format: selectedAnalyzeSample.format,
          width: selectedAnalyzeSample.width,
          height: selectedAnalyzeSample.height,
          sizeBytes: selectedAnalyzeSample.sizeBytes,
          encodedBytes: selectedAnalyzeSample.encodedBytes,
        );
      }

      final preview = ref.watch(currentPreviewProvider).asData?.value;
      if (preview == null) {
        return null;
      }
      return OptimizedPreviewDisplay(
        artifactId: preview.result.artifactId,
        format: preview.result.format,
        width: preview.result.width,
        height: preview.result.height,
        sizeBytes: preview.result.sizeBytes,
        encodedBytes: preview.result.encodedBytes,
      );
    });

class OptimizationPreview {
  const OptimizationPreview({
    required this.sourceFile,
    required this.plan,
    required this.result,
    required this.elapsedMilliseconds,
  });

  final OpenedImageFile sourceFile;
  final OptimizationPlan plan;
  final PreviewResult result;
  final int elapsedMilliseconds;

  _PreviewCacheKey get _cacheKey => _PreviewCacheKey(
    filePath: sourceFile.path,
    operation: plan.previewRequest.operation,
  );

  int? get originalSize => sourceFile.metadata.fileSize?.toInt();

  int? get savingsBytes {
    final size = originalSize;
    if (size == null) {
      return null;
    }
    return size - result.sizeBytes.toInt();
  }

  double? get savingsPercent {
    final size = originalSize;
    final savings = savingsBytes;
    if (size == null || size <= 0 || savings == null) {
      return null;
    }
    return (savings / size) * 100;
  }
}

final currentPreviewProvider = FutureProvider.autoDispose<OptimizationPreview?>((
  ref,
) async {
  final requestId = ++_previewRequestSequence;
  final totalStopwatch = Stopwatch()..start();
  final cache = ref.read(_previewCacheControllerProvider);
  ref.onDispose(() {
    DeveloperDiagnostics.logTiming(
      'preview:$requestId',
      'disposed total=${totalStopwatch.elapsedMilliseconds}ms',
    );
  });

  try {
    final planStopwatch = Stopwatch()..start();
    final plan = await ref.watch(currentOptimizationPlanProvider.future);
    planStopwatch.stop();
    if (plan == null) {
      return null;
    }

    DeveloperDiagnostics.logTiming(
      'preview:$requestId',
      'plan=${planStopwatch.elapsedMilliseconds}ms path=${plan.sourceFile.path} codec=${plan.targetCodec.name} useSource=${plan.useSourceImageForPreview}',
    );

    final cacheKey = _PreviewCacheKey(
      filePath: plan.sourceFile.path,
      operation: plan.previewRequest.operation,
    );
    final cachedPreview = cache.getPreview(cacheKey);
    if (cachedPreview != null) {
      totalStopwatch.stop();
      DeveloperDiagnostics.logTiming(
        'preview:$requestId',
        'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${cachedPreview.result.artifactId}',
      );
      return cachedPreview;
    }

    final debounceStopwatch = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    debounceStopwatch.stop();
    DeveloperDiagnostics.logTiming(
      'preview:$requestId',
      'debounce=${debounceStopwatch.elapsedMilliseconds}ms target=${plan.targetCodec.name} sourceCodec=${plan.usesSourceCodec}',
    );

    final previewStopwatch = Stopwatch()..start();
    final result = await ref
        .read(slimgApiProvider)
        .previewFile(request: plan.previewRequest);
    previewStopwatch.stop();
    totalStopwatch.stop();
    DeveloperDiagnostics.logTiming(
      'preview:$requestId',
      'preview=${previewStopwatch.elapsedMilliseconds}ms total=${totalStopwatch.elapsedMilliseconds}ms format=${result.format} size=${result.sizeBytes}',
    );
    final preview = OptimizationPreview(
      sourceFile: plan.sourceFile,
      plan: plan,
      result: result,
      elapsedMilliseconds: previewStopwatch.elapsedMilliseconds,
    );
    cache.cachePreview(cacheKey, preview);
    return preview;
  } on Object catch (error, stackTrace) {
    DeveloperDiagnostics.logTimingError(
      'preview:$requestId',
      error,
      stackTrace,
    );
    rethrow;
  }
});

final previewDisplaySelectionProvider =
    NotifierProvider.autoDispose<
      PreviewDisplaySelectionNotifier,
      PreviewDisplaySelection?
    >(PreviewDisplaySelectionNotifier.new);

final previewDifferenceRequestProvider =
    NotifierProvider.autoDispose<PreviewDifferenceRequestNotifier, String?>(
      PreviewDifferenceRequestNotifier.new,
    );

final currentPreviewDisplayModeProvider =
    Provider.autoDispose<PreviewDisplayMode>((ref) {
      final controller = ref.watch(fileOpenControllerProvider);
      final currentFile = controller.currentFile;
      if (currentFile == null) {
        return PreviewDisplayMode.original;
      }

      final manualSelection = ref.watch(previewDisplaySelectionProvider);
      final optimizedDisplay = ref.watch(currentOptimizedDisplayProvider);
      final plan = ref
          .watch(currentOptimizationPlanProvider)
          .maybeWhen(data: (value) => value, orElse: () => null);

      final hasPreview = optimizedDisplay != null;
      final isLosslessPreview = plan?.useSourceImageForPreview ?? false;
      final supportsDifference =
          hasPreview &&
          !isLosslessPreview &&
          optimizedDisplay.width == currentFile.metadata.width &&
          optimizedDisplay.height == currentFile.metadata.height;

      if (manualSelection != null &&
          manualSelection.filePath == currentFile.path) {
        switch (manualSelection.mode) {
          case PreviewDisplayMode.original:
            return PreviewDisplayMode.original;
          case PreviewDisplayMode.optimized:
            return hasPreview
                ? PreviewDisplayMode.optimized
                : PreviewDisplayMode.original;
          case PreviewDisplayMode.difference:
            return supportsDifference
                ? PreviewDisplayMode.difference
                : PreviewDisplayMode.original;
        }
      }

      final defaultsToOriginal = plan?.useSourceImageForPreview ?? true;
      if (defaultsToOriginal || !hasPreview) {
        return PreviewDisplayMode.original;
      }
      return PreviewDisplayMode.optimized;
    });

final _currentPreviewArtifactContextProvider =
    FutureProvider.autoDispose<_PreviewArtifactContext?>((ref) async {
      final controller = ref.watch(fileOpenControllerProvider);
      if (controller.isFolderSelected) {
        return null;
      }
      final analyzeSample = ref.watch(selectedAnalyzeSampleProvider);
      if (analyzeSample != null) {
        return _PreviewArtifactContext(
          request: PreviewArtifactRequest(artifactId: analyzeSample.artifactId),
          cacheKey: null,
        );
      }
      final preview = await ref.watch(currentPreviewProvider.future);
      if (preview == null) {
        return null;
      }
      return _PreviewArtifactContext(
        request: PreviewArtifactRequest(artifactId: preview.result.artifactId),
        cacheKey: preview._cacheKey,
      );
    });

final currentPreviewDifferenceFrameProvider = FutureProvider.autoDispose<PreviewDifferenceFrame?>((
  ref,
) async {
  final requestId = ++_previewDifferenceRequestSequence;
  final totalStopwatch = Stopwatch()..start();
  final cache = ref.read(_previewCacheControllerProvider);
  ref.onDispose(() {
    DeveloperDiagnostics.logTiming(
      'preview-diff:$requestId',
      'disposed total=${totalStopwatch.elapsedMilliseconds}ms',
    );
  });

  try {
    final context = await ref.watch(
      _currentPreviewArtifactContextProvider.future,
    );
    if (context == null) {
      return null;
    }
    final requestedArtifactId = ref.watch(previewDifferenceRequestProvider);
    final displayMode = ref.watch(currentPreviewDisplayModeProvider);
    final isActiveDifferenceMode = displayMode == PreviewDisplayMode.difference;
    if (!isActiveDifferenceMode &&
        requestedArtifactId != context.request.artifactId) {
      return null;
    }
    final cacheKey = context.cacheKey;
    if (cacheKey != null) {
      final cachedImage = cache.getDifferenceImage(cacheKey);
      final cachedRawImage = cache.getDifferenceRawImage(cacheKey);
      if (cachedImage != null && cachedRawImage != null) {
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-diff:$requestId',
          'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId}',
        );
        return PreviewDifferenceFrame(
          image: cachedImage,
          rawImage: cachedRawImage,
        );
      }
      if (cache.isDifferenceUnavailable(cacheKey)) {
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-diff:$requestId',
          'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} available=false',
        );
        return null;
      }
      if (cachedRawImage != null) {
        final image = await _decodeRawImage(cachedRawImage);
        cache.cacheDifferenceImage(cacheKey, image);
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-diff:$requestId',
          'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} source=raw',
        );
        return PreviewDifferenceFrame(image: image, rawImage: cachedRawImage);
      }
      if (cachedImage != null) {
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-diff:$requestId',
          'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} image-only',
        );
        return null;
      }
    }

    DeveloperDiagnostics.logTiming(
      'preview-diff:$requestId',
      'start artifact=${context.request.artifactId}',
    );
    final diffStopwatch = Stopwatch()..start();
    final result = await ref
        .read(slimgApiProvider)
        .computePreviewDifferenceImage(request: context.request);
    diffStopwatch.stop();
    totalStopwatch.stop();
    DeveloperDiagnostics.logTiming(
      'preview-diff:$requestId',
      'done diff=${diffStopwatch.elapsedMilliseconds}ms total=${totalStopwatch.elapsedMilliseconds}ms available=${result != null}',
    );
    if (result == null) {
      if (cacheKey != null) {
        cache.cacheDifferenceUnavailable(cacheKey);
      }
      return null;
    }
    if (cacheKey != null) {
      cache.cacheDifferenceRawImage(cacheKey, result);
    }
    final image = await _decodeRawImage(result);
    if (cacheKey != null) {
      cache.cacheDifferenceImage(cacheKey, image);
    } else {
      ref.onDispose(image.dispose);
    }
    return PreviewDifferenceFrame(image: image, rawImage: result);
  } on Object catch (error, stackTrace) {
    DeveloperDiagnostics.logTimingError(
      'preview-diff:$requestId',
      error,
      stackTrace,
    );
    rethrow;
  }
});

final currentDifferenceErrorStatsProvider = FutureProvider.autoDispose
    .family<DifferenceErrorStats, RawImageResult>((ref, rawImage) async {
      if (rawImage.differenceStats case final stats?) {
        return DifferenceErrorStats(
          mean: stats.mean,
          top10Percent: stats.top10Percent,
          top1Percent: stats.top1Percent,
        );
      }
      return _computeDifferenceErrorStats(rawImage);
    });

DifferenceErrorStats _computeDifferenceErrorStats(RawImageResult rawImage) {
  final pixelCount = rawImage.width * rawImage.height;
  if (pixelCount <= 0) {
    return const DifferenceErrorStats(mean: 0, top10Percent: 0, top1Percent: 0);
  }

  final histogram = List<int>.filled(766, 0);
  var totalSum = 0;
  for (var i = 0; i < pixelCount; i++) {
    final byteIndex = i * 4;
    final pixelSum =
        rawImage.rgbaBytes[byteIndex] +
        rawImage.rgbaBytes[byteIndex + 1] +
        rawImage.rgbaBytes[byteIndex + 2];
    histogram[pixelSum] += 1;
    totalSum += pixelSum;
  }

  final top10Count = math.max(1, (pixelCount * 0.10).ceil());
  final top1Count = math.max(1, (pixelCount * 0.01).ceil());

  return DifferenceErrorStats(
    mean: totalSum / pixelCount / 3,
    top10Percent: _topHistogramAverage(histogram, top10Count),
    top1Percent: _topHistogramAverage(histogram, top1Count),
  );
}

double _topHistogramAverage(List<int> histogram, int requestedCount) {
  var remaining = requestedCount;
  var sum = 0;
  for (var value = histogram.length - 1; value >= 0 && remaining > 0; value--) {
    final take = math.min(remaining, histogram[value]);
    sum += value * take;
    remaining -= take;
  }
  return sum / requestedCount / 3;
}

Future<ui.Image> _decodeRawImage(RawImageResult result) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    result.rgbaBytes,
    result.width,
    result.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

final currentPreviewPixelMatchProvider =
    FutureProvider.autoDispose<PreviewMetricResult?>((ref) async {
      final requestId = ++_previewPixelMatchRequestSequence;
      final totalStopwatch = Stopwatch()..start();
      final cache = ref.read(_previewCacheControllerProvider);
      ref.onDispose(() {
        DeveloperDiagnostics.logTiming(
          'preview-metric:pixel-match:$requestId',
          'disposed total=${totalStopwatch.elapsedMilliseconds}ms',
        );
      });

      try {
        final context = await ref.watch(
          _currentPreviewArtifactContextProvider.future,
        );
        if (context == null) {
          return null;
        }
        final cacheKey = context.cacheKey;
        if (cacheKey != null &&
            cache.hasMetric(cacheKey, _PreviewMetricKind.pixelMatch)) {
          final result = cache.getMetric(
            cacheKey,
            _PreviewMetricKind.pixelMatch,
          );
          totalStopwatch.stop();
          DeveloperDiagnostics.logTiming(
            'preview-metric:pixel-match:$requestId',
            'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} value=${result?.value}',
          );
          return result;
        }

        DeveloperDiagnostics.logTiming(
          'preview-metric:pixel-match:$requestId',
          'start artifact=${context.request.artifactId}',
        );
        final metricStopwatch = Stopwatch()..start();
        final result = await ref
            .read(slimgApiProvider)
            .computePreviewPixelMatchPercentage(request: context.request);
        metricStopwatch.stop();
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-metric:pixel-match:$requestId',
          'done metric=${metricStopwatch.elapsedMilliseconds}ms total=${totalStopwatch.elapsedMilliseconds}ms value=$result',
        );
        final metricResult = PreviewMetricResult(
          value: result,
          elapsedMilliseconds: metricStopwatch.elapsedMilliseconds,
        );
        if (cacheKey != null) {
          cache.cacheMetric(
            cacheKey,
            _PreviewMetricKind.pixelMatch,
            metricResult,
          );
        }
        return metricResult;
      } on Object catch (error, stackTrace) {
        DeveloperDiagnostics.logTimingError(
          'preview-metric:pixel-match:$requestId',
          error,
          stackTrace,
        );
        rethrow;
      }
    });

final currentPreviewMsSsimProvider = FutureProvider.autoDispose<PreviewMetricResult?>((
  ref,
) async {
  final requestId = ++_previewMsSsimRequestSequence;
  final totalStopwatch = Stopwatch()..start();
  final cache = ref.read(_previewCacheControllerProvider);
  ref.onDispose(() {
    DeveloperDiagnostics.logTiming(
      'preview-metric:ms-ssim:$requestId',
      'disposed total=${totalStopwatch.elapsedMilliseconds}ms',
    );
  });

  try {
    final context = await ref.watch(
      _currentPreviewArtifactContextProvider.future,
    );
    if (context == null) {
      return null;
    }
    final cacheKey = context.cacheKey;
    if (cacheKey != null &&
        cache.hasMetric(cacheKey, _PreviewMetricKind.msSsim)) {
      final result = cache.getMetric(cacheKey, _PreviewMetricKind.msSsim);
      totalStopwatch.stop();
      DeveloperDiagnostics.logTiming(
        'preview-metric:ms-ssim:$requestId',
        'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} value=${result?.value}',
      );
      return result;
    }

    DeveloperDiagnostics.logTiming(
      'preview-metric:ms-ssim:$requestId',
      'start artifact=${context.request.artifactId}',
    );
    final metricStopwatch = Stopwatch()..start();
    final result = await ref
        .read(slimgApiProvider)
        .computePreviewMsSsim(request: context.request);
    metricStopwatch.stop();
    totalStopwatch.stop();
    DeveloperDiagnostics.logTiming(
      'preview-metric:ms-ssim:$requestId',
      'done metric=${metricStopwatch.elapsedMilliseconds}ms total=${totalStopwatch.elapsedMilliseconds}ms value=$result',
    );
    final metricResult = PreviewMetricResult(
      value: result,
      elapsedMilliseconds: metricStopwatch.elapsedMilliseconds,
    );
    if (cacheKey != null) {
      cache.cacheMetric(cacheKey, _PreviewMetricKind.msSsim, metricResult);
    }
    return metricResult;
  } on Object catch (error, stackTrace) {
    DeveloperDiagnostics.logTimingError(
      'preview-metric:ms-ssim:$requestId',
      error,
      stackTrace,
    );
    rethrow;
  }
});

final currentPreviewSsimulacra2Provider =
    FutureProvider.autoDispose<PreviewMetricResult?>((ref) async {
      final requestId = ++_previewSsimulacra2RequestSequence;
      final totalStopwatch = Stopwatch()..start();
      final cache = ref.read(_previewCacheControllerProvider);
      ref.onDispose(() {
        DeveloperDiagnostics.logTiming(
          'preview-metric:ssimulacra2:$requestId',
          'disposed total=${totalStopwatch.elapsedMilliseconds}ms',
        );
      });

      try {
        final context = await ref.watch(
          _currentPreviewArtifactContextProvider.future,
        );
        if (context == null) {
          return null;
        }
        final cacheKey = context.cacheKey;
        if (cacheKey != null &&
            cache.hasMetric(cacheKey, _PreviewMetricKind.ssimulacra2)) {
          final result = cache.getMetric(
            cacheKey,
            _PreviewMetricKind.ssimulacra2,
          );
          totalStopwatch.stop();
          DeveloperDiagnostics.logTiming(
            'preview-metric:ssimulacra2:$requestId',
            'cache-hit total=${totalStopwatch.elapsedMilliseconds}ms artifact=${context.request.artifactId} value=${result?.value}',
          );
          return result;
        }

        DeveloperDiagnostics.logTiming(
          'preview-metric:ssimulacra2:$requestId',
          'start artifact=${context.request.artifactId}',
        );
        final metricStopwatch = Stopwatch()..start();
        final result = await ref
            .read(slimgApiProvider)
            .computePreviewSsimulacra2(request: context.request);
        metricStopwatch.stop();
        totalStopwatch.stop();
        DeveloperDiagnostics.logTiming(
          'preview-metric:ssimulacra2:$requestId',
          'done metric=${metricStopwatch.elapsedMilliseconds}ms total=${totalStopwatch.elapsedMilliseconds}ms value=$result',
        );
        final metricResult = PreviewMetricResult(
          value: result,
          elapsedMilliseconds: metricStopwatch.elapsedMilliseconds,
        );
        if (cacheKey != null) {
          cache.cacheMetric(
            cacheKey,
            _PreviewMetricKind.ssimulacra2,
            metricResult,
          );
        }
        return metricResult;
      } on Object catch (error, stackTrace) {
        DeveloperDiagnostics.logTimingError(
          'preview-metric:ssimulacra2:$requestId',
          error,
          stackTrace,
        );
        rethrow;
      }
    });

enum OptimizationItemStatus {
  idle,
  queued,
  running,
  written,
  skipped,
  failed,
  canceled,
}

class OptimizationItemState {
  const OptimizationItemState({
    required this.status,
    this.message,
    this.result,
  });

  final OptimizationItemStatus status;
  final String? message;
  final ProcessResult? result;
}

class OptimizationRunState {
  const OptimizationRunState({
    this.jobId,
    this.jobState,
    this.completedCount = 0,
    this.totalCount = 0,
    this.currentInputPath,
    this.appliedResultCount = 0,
    this.items = const {},
    this.globalError,
  });

  final String? jobId;
  final BatchJobState? jobState;
  final int completedCount;
  final int totalCount;
  final String? currentInputPath;
  final int appliedResultCount;
  final Map<String, OptimizationItemState> items;
  final String? globalError;

  bool get isRunning =>
      jobState == BatchJobState.running ||
      jobState == BatchJobState.cancelRequested;

  bool get isCancelRequested => jobState == BatchJobState.cancelRequested;

  OptimizationRunState copyWith({
    String? jobId,
    BatchJobState? jobState,
    int? completedCount,
    int? totalCount,
    String? currentInputPath,
    int? appliedResultCount,
    Map<String, OptimizationItemState>? items,
    String? globalError,
    bool clearGlobalError = false,
    bool clearJobId = false,
    bool clearJobState = false,
    bool clearCurrentInputPath = false,
  }) {
    return OptimizationRunState(
      jobId: clearJobId ? null : (jobId ?? this.jobId),
      jobState: clearJobState ? null : (jobState ?? this.jobState),
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      currentInputPath: clearCurrentInputPath
          ? null
          : (currentInputPath ?? this.currentInputPath),
      appliedResultCount: appliedResultCount ?? this.appliedResultCount,
      items: items ?? this.items,
      globalError: clearGlobalError ? null : (globalError ?? this.globalError),
    );
  }
}

final optimizationRunControllerProvider =
    NotifierProvider<OptimizationRunController, OptimizationRunState>(
      OptimizationRunController.new,
    );

class OptimizationRunController extends Notifier<OptimizationRunState> {
  List<String> _activeInputPaths = const <String>[];
  Set<String> _keepSourceEntryPaths = const <String>{};
  Set<String> _deleteSourceAfterSuccessPaths = const <String>{};
  Map<String, String> _renameSourceAfterSuccessPaths = const <String, String>{};
  Map<String, String> _moveOutputAfterSuccessPaths = const <String, String>{};
  Map<String, String> _finalOutputPaths = const <String, String>{};

  @override
  OptimizationRunState build() => const OptimizationRunState();

  Future<void> optimizeSelected() async {
    final file = ref.read(fileOpenControllerProvider).currentFile;
    if (file == null) {
      return;
    }
    await _run([file]);
  }

  Future<void> optimizeAll() async {
    final files = ref.read(fileOpenControllerProvider).sessionFiles.toList();
    if (files.isEmpty) {
      return;
    }
    await _run(files);
  }

  Future<void> cancelCurrentRun() async {
    if (!state.isRunning || state.isCancelRequested || state.jobId == null) {
      return;
    }

    final jobId = state.jobId!;
    state = state.copyWith(
      jobState: BatchJobState.cancelRequested,
      clearGlobalError: true,
    );

    try {
      await ref.read(slimgApiProvider).cancelProcessFileBatchJob(jobId: jobId);
    } on Object catch (error) {
      state = _idleState(items: state.items, globalError: error.toString());
    }
  }

  Future<void> _run(List<OpenedImageFile> files) async {
    if (state.isRunning) {
      return;
    }

    final fileController = ref.read(fileOpenControllerProvider);
    final settings = await ref.read(appSettingsProvider.future);
    final jxlEncoder = ref.read(jxlEncoderPreferenceProvider);
    if (settings.storageDestinationMode == StorageDestinationMode.sameFolder) {
      final accessResult = await fileController
          .ensureWritableContainingDirectoryAccess(
            files.map((file) => file.path),
            persistentAccesses: settings.sameFolderAccesses
                .map(
                  (access) => SecurityScopedFileAccess(
                    path: access.path,
                    bookmark: access.bookmark,
                  ),
                )
                .toList(growable: false),
          );
      final updatedAccesses = accessResult.persistentAccesses
          .where(
            (access) => access.bookmark != null && access.bookmark!.isNotEmpty,
          )
          .map(
            (access) => StoredDirectoryAccess(
              path: access.path,
              bookmark: access.bookmark!,
            ),
          )
          .toList(growable: false);
      if (settings.copyWith(sameFolderAccesses: updatedAccesses) != settings) {
        await ref
            .read(appSettingsProvider.notifier)
            .setSameFolderAccesses(updatedAccesses);
      }
      if (!accessResult.didStartAccess) {
        state = _idleState(
          items: state.items,
          globalError: 'Choose the save folder to continue.',
        );
        return;
      }
    } else {
      final bookmark = settings.differentLocationBookmark;
      final didStartAccess = await fileController
          .startAccessingSecurityScopedResource(bookmark);
      if (bookmark != null && bookmark.isNotEmpty && !didStartAccess) {
        state = _idleState(
          items: state.items,
          globalError: 'Choose the output folder again.',
        );
        return;
      }
    }
    final plans = files
        .map(
          (file) => buildOptimizationPlan(
            file: file,
            settings: settings,
            sourceRootPath: fileController.selectedFolderPath,
            jxlEncoder: jxlEncoder,
          ),
        )
        .toList(growable: false);
    final requests = plans
        .map((plan) => plan.processRequest)
        .toList(growable: false);
    final inputPaths = files.map((file) => file.path).toList(growable: false);
    final queuedItems = {
      for (final path in inputPaths)
        path: const OptimizationItemState(
          status: OptimizationItemStatus.queued,
        ),
    };

    try {
      DeveloperDiagnostics.logTiming(
        'optimize-run',
        'start files=${inputPaths.length} paths=${inputPaths.join(",")}',
      );
      final handle = await ref
          .read(slimgApiProvider)
          .startProcessFileBatchJob(
            request: ProcessFileBatchRequest(
              requests: requests,
              continueOnError: true,
            ),
          );
      _activeInputPaths = inputPaths;
      _keepSourceEntryPaths = plans
          .where((plan) => plan.keepSourceEntry)
          .map((plan) => plan.sourceFile.path)
          .toSet();
      _deleteSourceAfterSuccessPaths = plans
          .where((plan) => plan.deleteSourceAfterSuccess)
          .map((plan) => plan.sourceFile.path)
          .toSet();
      _renameSourceAfterSuccessPaths = Map<String, String>.fromEntries(
        plans
            .where((plan) => plan.renameSourceAfterSuccessPath != null)
            .map(
              (plan) => MapEntry(
                plan.sourceFile.path,
                plan.renameSourceAfterSuccessPath!,
              ),
            ),
      );
      _moveOutputAfterSuccessPaths = Map<String, String>.fromEntries(
        plans
            .where((plan) => plan.moveOutputAfterSuccessPath != null)
            .map(
              (plan) => MapEntry(
                plan.sourceFile.path,
                plan.moveOutputAfterSuccessPath!,
              ),
            ),
      );
      _finalOutputPaths = Map<String, String>.fromEntries(
        plans
            .where((plan) => plan.moveOutputAfterSuccessPath != null)
            .map(
              (plan) => MapEntry(
                plan.sourceFile.path,
                plan.moveOutputAfterSuccessPath!,
              ),
            ),
      );
      state = OptimizationRunState(
        jobId: handle.jobId,
        jobState: BatchJobState.running,
        totalCount: inputPaths.length,
        items: queuedItems,
      );
      DeveloperDiagnostics.logTiming(
        'optimize-run',
        'job-started jobId=${handle.jobId} total=${inputPaths.length}',
      );
      unawaited(_pollJob(handle.jobId));
    } on Object catch (error) {
      DeveloperDiagnostics.logTimingError('optimize-run', error);
      state = _idleState(items: queuedItems, globalError: error.toString());
    }
  }

  Future<void> _pollJob(String jobId) async {
    while (state.jobId == jobId) {
      try {
        final snapshot = await ref
            .read(slimgApiProvider)
            .getProcessFileBatchJob(jobId: jobId);
        if (state.jobId != jobId) {
          return;
        }

        DeveloperDiagnostics.logTiming(
          'optimize-run',
          'snapshot jobId=$jobId state=${snapshot.state.name} completed=${snapshot.completedCount}/${snapshot.totalCount} current=${snapshot.currentInputPath} results=${snapshot.results.length} error=${snapshot.error}',
        );
        await _applySnapshot(jobId, snapshot);
        if (_isTerminalJobState(snapshot.state)) {
          await _disposeJob(jobId);
          final terminalItems = _buildItemsForSnapshot(snapshot);
          final hasItemFailures = terminalItems.values.any(
            (item) => item.status == OptimizationItemStatus.failed,
          );
          DeveloperDiagnostics.logTiming(
            'optimize-run',
            'job-terminal jobId=$jobId state=${snapshot.state.name} error=${snapshot.error}',
          );
          state = _idleState(
            items: terminalItems,
            globalError:
                snapshot.error?.toString() ??
                (hasItemFailures ? 'Some images could not be saved.' : null),
          );
          _activeInputPaths = const <String>[];
          _keepSourceEntryPaths = const <String>{};
          _deleteSourceAfterSuccessPaths = const <String>{};
          _renameSourceAfterSuccessPaths = const <String, String>{};
          _moveOutputAfterSuccessPaths = const <String, String>{};
          _finalOutputPaths = const <String, String>{};
          return;
        }
      } on Object catch (error) {
        if (state.jobId != jobId) {
          return;
        }

        await _disposeJob(jobId);
        DeveloperDiagnostics.logTimingError('optimize-run', error);
        state = _idleState(items: state.items, globalError: error.toString());
        _activeInputPaths = const <String>[];
        _keepSourceEntryPaths = const <String>{};
        _deleteSourceAfterSuccessPaths = const <String>{};
        _renameSourceAfterSuccessPaths = const <String, String>{};
        _moveOutputAfterSuccessPaths = const <String, String>{};
        _finalOutputPaths = const <String, String>{};
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> _applySnapshot(String jobId, BatchJobSnapshot snapshot) async {
    final newResults = snapshot.results.skip(state.appliedResultCount).toList();
    if (newResults.isNotEmpty) {
      for (final item in newResults) {
        DeveloperDiagnostics.logTiming(
          'optimize-run',
          'result input=${item.inputPath} success=${item.success} error=${item.error} output=${item.result?.outputPath} didWrite=${item.result?.didWrite}',
        );
      }
      await ref
          .read(fileOpenControllerProvider)
          .applyProcessResults(
            newResults,
            keepSourceEntries: _keepSourceEntryPaths,
            deleteSourcesAfterSuccess: _deleteSourceAfterSuccessPaths,
            renameSourcesAfterSuccess: _renameSourceAfterSuccessPaths,
            moveOutputsAfterSuccess: _moveOutputAfterSuccessPaths,
          );
      if (state.jobId != jobId) {
        return;
      }
    }

    state = state.copyWith(
      jobState: snapshot.state,
      completedCount: snapshot.completedCount,
      totalCount: snapshot.totalCount,
      currentInputPath: snapshot.currentInputPath,
      appliedResultCount: snapshot.results.length,
      items: _buildItemsForSnapshot(snapshot),
      globalError: snapshot.error?.toString(),
      clearGlobalError: snapshot.error == null,
      clearCurrentInputPath: snapshot.currentInputPath == null,
    );
  }

  Map<String, OptimizationItemState> _buildItemsForSnapshot(
    BatchJobSnapshot snapshot,
  ) {
    final nextItems = <String, OptimizationItemState>{
      for (final path in _activeInputPaths)
        path: const OptimizationItemState(
          status: OptimizationItemStatus.queued,
        ),
    };
    final completedInputs = <String>{};

    for (final item in snapshot.results) {
      completedInputs.add(item.inputPath);
      nextItems.remove(item.inputPath);

      if (!item.success || item.result == null) {
        nextItems[item.inputPath] = OptimizationItemState(
          status: OptimizationItemStatus.failed,
          message: item.error?.toString() ?? 'Failed',
        );
        continue;
      }

      var result = item.result!;
      final finalOutputPath = _finalOutputPaths[item.inputPath];
      if (result.didWrite && finalOutputPath != null) {
        result = _copyProcessResult(result, outputPath: finalOutputPath);
      }
      final displayPath = _keepSourceEntryPaths.contains(item.inputPath)
          ? item.inputPath
          : result.outputPath;
      nextItems[displayPath] = OptimizationItemState(
        status: result.didWrite
            ? OptimizationItemStatus.written
            : OptimizationItemStatus.skipped,
        result: result,
      );
    }

    if (snapshot.currentInputPath case final currentPath?) {
      nextItems[currentPath] = const OptimizationItemState(
        status: OptimizationItemStatus.running,
      );
    }

    if (snapshot.state == BatchJobState.canceled) {
      for (final path in _activeInputPaths) {
        if (!completedInputs.contains(path)) {
          nextItems[path] = const OptimizationItemState(
            status: OptimizationItemStatus.canceled,
          );
        }
      }
    }

    return nextItems;
  }

  OptimizationRunState _idleState({
    required Map<String, OptimizationItemState> items,
    String? globalError,
  }) {
    return OptimizationRunState(items: items, globalError: globalError);
  }

  Future<void> _disposeJob(String jobId) async {
    try {
      await ref.read(slimgApiProvider).disposeProcessFileBatchJob(jobId: jobId);
    } on Object {
      // The job is already terminal in the UI path; disposal failures are non-fatal.
    }
  }
}

bool _isTerminalJobState(BatchJobState state) {
  return switch (state) {
    BatchJobState.completed ||
    BatchJobState.canceled ||
    BatchJobState.failed => true,
    BatchJobState.running || BatchJobState.cancelRequested => false,
  };
}

ProcessResult _copyProcessResult(
  ProcessResult result, {
  required String outputPath,
}) {
  return ProcessResult(
    outputPath: outputPath,
    format: result.format,
    width: result.width,
    height: result.height,
    originalSize: result.originalSize,
    newSize: result.newSize,
    didWrite: result.didWrite,
  );
}
