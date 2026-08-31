import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/main.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';
import 'package:oimg/src/file_open/file_open_controller.dart';
import 'package:oimg/src/file_open/file_open_providers.dart';
import 'package:oimg/src/optimization/optimization_providers.dart';
import 'package:oimg/src/rust/frb_generated.dart';
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:oimg/src/settings/app_settings_controller.dart';
import 'package:oimg/src/settings/app_settings_repository.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Shows the empty state without opened files', (
    WidgetTester tester,
  ) async {
    final slimg = _FakeSlimgApi();
    final controller = FileOpenController(
      channel: _NoopFileOpenChannel(),
      slimg: slimg,
    );
    await controller.initialize();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          slimgApiProvider.overrideWithValue(slimg),
          fileOpenControllerProvider.overrideWith((ref) => controller),
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(store: _FakeAppSettingsStore()),
          ),
        ],
        child: const MyApp(),
      ),
    );
    expect(find.text('Optimize images easily'), findsOneWidget);
  });
}

class _NoopFileOpenChannel implements FileOpenChannel {
  @override
  Future<void> bind(OpenFilesHandler onOpenFiles) async {}

  @override
  Future<List<String>> pickFiles() async => const <String>[];

  @override
  Future<List<String>> pickFolder() async => const <String>[];

  @override
  Future<SecurityScopedFileAccess?> pickFolderForPersistentAccess() async {
    return null;
  }

  @override
  Future<bool> startAccessingSecurityScopedResource(String bookmark) async {
    return false;
  }

  @override
  Future<void> showInFileManager(String path) async {}
}

class _FakeSlimgApi implements SlimgApi {
  @override
  void setTimingLogsEnabled({required bool enabled}) {}

  @override
  Future<ImageMetadata> inspectFile({required String inputPath}) {
    throw StateError('unsupported');
  }

  @override
  Future<PreviewResult> previewFile({
    required PreviewFileRequest request,
  }) async {
    return PreviewResult(
      encodedBytes: Uint8List(0),
      artifactId: 'integration-preview-artifact',
      format: 'png',
      width: 1,
      height: 1,
      sizeBytes: BigInt.one,
      sourceHasTransparency: false,
    );
  }

  @override
  Future<double?> computePreviewPixelMatchPercentage({
    required PreviewArtifactRequest request,
  }) async {
    return null;
  }

  @override
  Future<double?> computePreviewMsSsim({
    required PreviewArtifactRequest request,
  }) async {
    return null;
  }

  @override
  Future<double?> computePreviewSsimulacra2({
    required PreviewArtifactRequest request,
  }) async {
    return null;
  }

  @override
  Future<RawImageResult?> computePreviewDifferenceImage({
    required PreviewArtifactRequest request,
  }) async {
    return null;
  }

  @override
  Future<void> disposePreviewArtifact({required String artifactId}) async {}

  @override
  Future<ProcessResult> processFile({required ProcessFileRequest request}) {
    throw UnimplementedError();
  }

  @override
  Future<List<BatchItemResult>> processFileBatch({
    required ProcessFileBatchRequest request,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BatchJobHandle> startProcessFileBatchJob({
    required ProcessFileBatchRequest request,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BatchJobSnapshot> getProcessFileBatchJob({required String jobId}) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelProcessFileBatchJob({required String jobId}) {
    throw UnimplementedError();
  }

  @override
  Future<void> disposeProcessFileBatchJob({required String jobId}) {
    throw UnimplementedError();
  }

  @override
  Future<AnalyzeFileJobHandle> startAnalyzeFileJob({
    required AnalyzeFileRequest request,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AnalyzeFileJobSnapshot> getAnalyzeFileJob({required String jobId}) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelAnalyzeFileJob({required String jobId}) {
    throw UnimplementedError();
  }

  @override
  Future<void> disposeAnalyzeFileJob({required String jobId}) {
    throw UnimplementedError();
  }
}

class _FakeAppSettingsStore implements AppSettingsStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}
