import 'package:oimg/src/settings/developer_diagnostics.dart';

import 'slimg_bridge.dart';

abstract class SlimgApi {
  const SlimgApi();

  Future<ImageMetadata> inspectFile({required String inputPath});

  bool gjxlBackendCompiled();

  void setTimingLogsEnabled({required bool enabled});

  Future<PreviewResult> previewFile({required PreviewFileRequest request});

  Future<double?> computePreviewPixelMatchPercentage({
    required PreviewArtifactRequest request,
  });

  Future<double?> computePreviewMsSsim({
    required PreviewArtifactRequest request,
  });

  Future<double?> computePreviewSsimulacra2({
    required PreviewArtifactRequest request,
  });

  Future<RawImageResult?> computePreviewDifferenceImage({
    required PreviewArtifactRequest request,
  });

  Future<void> disposePreviewArtifact({required String artifactId});

  Future<ProcessResult> processFile({required ProcessFileRequest request});

  Future<List<BatchItemResult>> processFileBatch({
    required ProcessFileBatchRequest request,
  });

  Future<BatchJobHandle> startProcessFileBatchJob({
    required ProcessFileBatchRequest request,
  });

  Future<BatchJobSnapshot> getProcessFileBatchJob({required String jobId});

  Future<void> cancelProcessFileBatchJob({required String jobId});

  Future<void> disposeProcessFileBatchJob({required String jobId});

  Future<AnalyzeFileJobHandle> startAnalyzeFileJob({
    required AnalyzeFileRequest request,
  });

  Future<AnalyzeFileJobSnapshot> getAnalyzeFileJob({required String jobId});

  Future<void> cancelAnalyzeFileJob({required String jobId});

  Future<void> disposeAnalyzeFileJob({required String jobId});
}

class FrbSlimgApi implements SlimgApi {
  const FrbSlimgApi({SlimgBridge? bridge})
    : _bridge = bridge ?? const SlimgBridge();

  final SlimgBridge _bridge;

  @override
  Future<ImageMetadata> inspectFile({required String inputPath}) {
    return _bridge.inspectFile(inputPath: inputPath);
  }

  @override
  bool gjxlBackendCompiled() => _bridge.gjxlBackendCompiled();

  @override
  void setTimingLogsEnabled({required bool enabled}) {
    _bridge.setTimingLogsEnabled(enabled: enabled);
  }

  @override
  Future<PreviewResult> previewFile({required PreviewFileRequest request}) {
    final stopwatch = Stopwatch()..start();
    DeveloperDiagnostics.logTiming(
      'slimg-api',
      'preview start path=${request.inputPath}',
    );
    return _bridge
        .previewFile(request: request)
        .then(
          (result) {
            stopwatch.stop();
            DeveloperDiagnostics.logTiming(
              'slimg-api',
              'preview done path=${request.inputPath} total=${stopwatch.elapsedMilliseconds}ms format=${result.format} size=${result.sizeBytes}',
            );
            return result;
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            DeveloperDiagnostics.logTimingError('slimg-api', error, stackTrace);
            throw error;
          },
        );
  }

  @override
  Future<double?> computePreviewPixelMatchPercentage({
    required PreviewArtifactRequest request,
  }) {
    final stopwatch = Stopwatch()..start();
    DeveloperDiagnostics.logTiming(
      'preview-metric:pixel-match',
      'start artifact=${request.artifactId}',
    );
    return _bridge
        .computePreviewPixelMatchPercentage(request: request)
        .then(
          (result) {
            stopwatch.stop();
            DeveloperDiagnostics.logTiming(
              'preview-metric:pixel-match',
              'done total=${stopwatch.elapsedMilliseconds}ms value=$result',
            );
            return result;
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            DeveloperDiagnostics.logTimingError(
              'preview-metric:pixel-match',
              error,
              stackTrace,
            );
            throw error;
          },
        );
  }

  @override
  Future<double?> computePreviewMsSsim({
    required PreviewArtifactRequest request,
  }) {
    final stopwatch = Stopwatch()..start();
    DeveloperDiagnostics.logTiming(
      'preview-metric:ms-ssim',
      'start artifact=${request.artifactId}',
    );
    return _bridge
        .computePreviewMsSsim(request: request)
        .then(
          (result) {
            stopwatch.stop();
            DeveloperDiagnostics.logTiming(
              'preview-metric:ms-ssim',
              'done total=${stopwatch.elapsedMilliseconds}ms value=$result',
            );
            return result;
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            DeveloperDiagnostics.logTimingError(
              'preview-metric:ms-ssim',
              error,
              stackTrace,
            );
            throw error;
          },
        );
  }

  @override
  Future<double?> computePreviewSsimulacra2({
    required PreviewArtifactRequest request,
  }) {
    final stopwatch = Stopwatch()..start();
    DeveloperDiagnostics.logTiming(
      'preview-metric:ssimulacra2',
      'start artifact=${request.artifactId}',
    );
    return _bridge
        .computePreviewSsimulacra2(request: request)
        .then(
          (result) {
            stopwatch.stop();
            DeveloperDiagnostics.logTiming(
              'preview-metric:ssimulacra2',
              'done total=${stopwatch.elapsedMilliseconds}ms value=$result',
            );
            return result;
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            DeveloperDiagnostics.logTimingError(
              'preview-metric:ssimulacra2',
              error,
              stackTrace,
            );
            throw error;
          },
        );
  }

  @override
  Future<RawImageResult?> computePreviewDifferenceImage({
    required PreviewArtifactRequest request,
  }) {
    final stopwatch = Stopwatch()..start();
    DeveloperDiagnostics.logTiming(
      'preview-diff',
      'start artifact=${request.artifactId}',
    );
    return _bridge
        .computePreviewDifferenceImage(request: request)
        .then(
          (result) {
            stopwatch.stop();
            DeveloperDiagnostics.logTiming(
              'preview-diff',
              'done total=${stopwatch.elapsedMilliseconds}ms available=${result != null}',
            );
            return result;
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            DeveloperDiagnostics.logTimingError(
              'preview-diff',
              error,
              stackTrace,
            );
            throw error;
          },
        );
  }

  @override
  Future<void> disposePreviewArtifact({required String artifactId}) {
    return _bridge.disposePreviewArtifact(artifactId: artifactId);
  }

  @override
  Future<ProcessResult> processFile({required ProcessFileRequest request}) {
    return _bridge.processFile(request: request);
  }

  @override
  Future<List<BatchItemResult>> processFileBatch({
    required ProcessFileBatchRequest request,
  }) {
    return _bridge.processFileBatch(request: request);
  }

  @override
  Future<BatchJobHandle> startProcessFileBatchJob({
    required ProcessFileBatchRequest request,
  }) {
    return _bridge.startProcessFileBatchJob(request: request);
  }

  @override
  Future<BatchJobSnapshot> getProcessFileBatchJob({required String jobId}) {
    return _bridge.getProcessFileBatchJob(jobId: jobId);
  }

  @override
  Future<void> cancelProcessFileBatchJob({required String jobId}) {
    return _bridge.cancelProcessFileBatchJob(jobId: jobId);
  }

  @override
  Future<void> disposeProcessFileBatchJob({required String jobId}) {
    return _bridge.disposeProcessFileBatchJob(jobId: jobId);
  }

  @override
  Future<AnalyzeFileJobHandle> startAnalyzeFileJob({
    required AnalyzeFileRequest request,
  }) {
    return _bridge.startAnalyzeFileJob(request: request);
  }

  @override
  Future<AnalyzeFileJobSnapshot> getAnalyzeFileJob({required String jobId}) {
    return _bridge.getAnalyzeFileJob(jobId: jobId);
  }

  @override
  Future<void> cancelAnalyzeFileJob({required String jobId}) {
    return _bridge.cancelAnalyzeFileJob(jobId: jobId);
  }

  @override
  Future<void> disposeAnalyzeFileJob({required String jobId}) {
    return _bridge.disposeAnalyzeFileJob(jobId: jobId);
  }
}
