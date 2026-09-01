import 'api/bridge.dart' as bridge_api;
import 'types.dart';
export 'error.dart';
export 'types.dart';

class SlimgBridge {
  const SlimgBridge();

  String version() => bridge_api.version();

  List<FormatInfo> supportedFormats() => bridge_api.supportedFormats();

  bool gjxlBackendCompiled() => bridge_api.gjxlBackendCompiled();

  Future<ImageMetadata> inspectFile({required String inputPath}) =>
      bridge_api.inspectFile(inputPath: inputPath);

  void setTimingLogsEnabled({required bool enabled}) =>
      bridge_api.setTimingLogsEnabled(enabled: enabled);

  Future<ImageMetadata> inspectBytes({required List<int> data}) =>
      bridge_api.inspectBytes(data: data);

  Future<PreviewResult> previewFile({required PreviewFileRequest request}) =>
      bridge_api.previewFile(request: request);

  Future<double?> computePreviewPixelMatchPercentage({
    required PreviewArtifactRequest request,
  }) => bridge_api.computePreviewPixelMatchPercentage(request: request);

  Future<double?> computePreviewMsSsim({
    required PreviewArtifactRequest request,
  }) => bridge_api.computePreviewMsSsim(request: request);

  Future<double?> computePreviewSsimulacra2({
    required PreviewArtifactRequest request,
  }) => bridge_api.computePreviewSsimulacra2(request: request);

  Future<RawImageResult?> computePreviewDifferenceImage({
    required PreviewArtifactRequest request,
  }) => bridge_api.computePreviewDifferenceImage(request: request);

  Future<void> disposePreviewArtifact({required String artifactId}) =>
      bridge_api.disposePreviewArtifact(artifactId: artifactId);

  Future<ProcessResult> processFile({required ProcessFileRequest request}) =>
      bridge_api.processFile(request: request);

  Future<EncodedImageResult> processBytes({
    required ProcessBytesRequest request,
  }) => bridge_api.processBytes(request: request);

  Future<List<BatchItemResult>> processFiles({
    required BatchProcessRequest request,
  }) => bridge_api.processFiles(request: request);

  Future<List<BatchItemResult>> processFileBatch({
    required ProcessFileBatchRequest request,
  }) => bridge_api.processFileBatch(request: request);

  Future<BatchJobHandle> startProcessFileBatchJob({
    required ProcessFileBatchRequest request,
  }) => bridge_api.startProcessFileBatchJob(request: request);

  Future<BatchJobSnapshot> getProcessFileBatchJob({required String jobId}) =>
      bridge_api.getProcessFileBatchJob(jobId: jobId);

  Future<void> cancelProcessFileBatchJob({required String jobId}) =>
      bridge_api.cancelProcessFileBatchJob(jobId: jobId);

  Future<void> disposeProcessFileBatchJob({required String jobId}) =>
      bridge_api.disposeProcessFileBatchJob(jobId: jobId);

  Future<AnalyzeFileJobHandle> startAnalyzeFileJob({
    required AnalyzeFileRequest request,
  }) => bridge_api.startAnalyzeFileJob(request: request);

  Future<AnalyzeFileJobSnapshot> getAnalyzeFileJob({required String jobId}) =>
      bridge_api.getAnalyzeFileJob(jobId: jobId);

  Future<void> cancelAnalyzeFileJob({required String jobId}) =>
      bridge_api.cancelAnalyzeFileJob(jobId: jobId);

  Future<void> disposeAnalyzeFileJob({required String jobId}) =>
      bridge_api.disposeAnalyzeFileJob(jobId: jobId);
}
