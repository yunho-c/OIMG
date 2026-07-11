import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/src/file_open/file_open_channel.dart';
import 'package:oimg/src/file_open/file_open_controller.dart';
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FileOpenController', () {
    test('accepts files that slimg can inspect', () async {
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            'photo.JPG': _metadata('jpeg'),
            'scan.TIFF': _metadata('png'),
          },
        ),
        initialPaths: const ['photo.JPG', 'notes.txt', 'scan.TIFF'],
      );

      await controller.initialize();

      expect(controller.sessionPaths, ['photo.JPG', 'scan.TIFF']);
      expect(controller.currentIndex, 0);
    });

    test(
      'keeps current session and emits notice when all files fail inspection',
      () async {
        final controller = FileOpenController(
          channel: _FakeFileOpenChannel(),
          slimg: _FakeSlimgApi(inspectResults: {'cover.png': _metadata('png')}),
          initialPaths: const ['cover.png'],
        );

        await controller.initialize();
        await controller.openPaths(const ['readme.md']);

        expect(controller.sessionPaths, ['cover.png']);
        expect(
          controller.takePendingNotice(),
          'Some files could not be opened.',
        );
      },
    );

    test('replaces the session and resets the current index', () async {
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            'first.png': _metadata('png'),
            'second.png': _metadata('png'),
            'new-a.webp': _metadata('webp'),
            'new-b.bmp': _metadata('jpeg'),
          },
        ),
        initialPaths: const ['first.png', 'second.png'],
      );

      await controller.initialize();
      controller.showNext();

      await controller.openPaths(const ['new-a.webp', 'new-b.bmp']);

      expect(controller.sessionPaths, ['new-a.webp', 'new-b.bmp']);
      expect(controller.currentIndex, 0);
    });

    test('supports bounded multi-file navigation', () async {
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            '1.png': _metadata('png'),
            '2.png': _metadata('png'),
          },
        ),
        initialPaths: const ['1.png', '2.png'],
      );

      await controller.initialize();

      expect(controller.canGoPrevious, isFalse);
      expect(controller.canGoNext, isTrue);

      controller.showPrevious();
      expect(controller.currentIndex, 0);

      controller.showNext();
      expect(controller.currentIndex, 1);
      expect(controller.canGoNext, isFalse);

      controller.showNext();
      expect(controller.currentIndex, 1);
    });

    test('can select a file directly by path', () async {
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            '1.png': _metadata('png'),
            '2.png': _metadata('png'),
            '3.png': _metadata('png'),
          },
        ),
        initialPaths: const ['1.png', '2.png', '3.png'],
      );

      await controller.initialize();
      controller.showPath('3.png');

      expect(controller.currentIndex, 2);
      expect(controller.currentPath, '3.png');

      controller.showPath('missing.png');
      expect(controller.currentIndex, 2);
    });

    test('can select a folder and expose its loaded files and size', () async {
      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            '/tmp/animals/cat.png': _metadata('png'),
            '/tmp/animals/dog.png': _metadata('png'),
            '/tmp/cars/road.png': _metadata('png'),
          },
        ),
        initialPaths: const [
          '/tmp/animals/cat.png',
          '/tmp/animals/dog.png',
          '/tmp/cars/road.png',
        ],
      );

      await controller.initialize();
      controller.showFolder('/tmp/animals');

      expect(controller.isFolderSelected, isTrue);
      expect(controller.selectedFolderName, 'animals');
      expect(controller.selectedFolderFiles.map((file) => file.path), [
        '/tmp/animals/cat.png',
        '/tmp/animals/dog.png',
      ]);
      expect(controller.selectedFolderSizeBytes, 2048);
      expect(controller.currentPositionLabel, isNull);

      controller.showPath('/tmp/animals/dog.png');

      expect(controller.isFolderSelected, isFalse);
      expect(controller.currentPath, '/tmp/animals/dog.png');
      expect(controller.currentPositionLabel, '2 / 3');
    });

    test('delegates show-in-file-manager requests to the channel', () async {
      final channel = _FakeFileOpenChannel();
      final controller = FileOpenController(
        channel: channel,
        slimg: _FakeSlimgApi(
          inspectResults: {'/tmp/animals/cat.png': _metadata('png')},
        ),
        initialPaths: const ['/tmp/animals/cat.png'],
      );

      await controller.initialize();
      await controller.showInFileManager('/tmp/animals/cat.png');

      expect(channel.shownPaths, ['/tmp/animals/cat.png']);
    });

    test('expands dropped directories into nested file candidates', () async {
      final root = await Directory.systemTemp.createTemp('oimg-drop-test');
      addTearDown(() async {
        await root.delete(recursive: true);
      });

      final nested = Directory(p.join(root.path, 'nested'))..createSync();
      final imageA = File(p.join(root.path, 'first.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final imageB = File(p.join(nested.path, 'second.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
      File(p.join(nested.path, 'notes.txt')).writeAsStringSync('ignored');

      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            imageA.path: _metadata('png'),
            imageB.path: _metadata('jpeg'),
          },
        ),
      );

      await controller.initialize();
      await controller.openPaths([root.path]);

      expect(controller.sessionPaths.toSet(), {imageA.path, imageB.path});
    });

    test('skips hidden folders and protected media library packages', () async {
      final root = await Directory.systemTemp.createTemp(
        'oimg-library-skip-test',
      );
      addTearDown(() async {
        await root.delete(recursive: true);
      });

      final ordinary = File(p.join(root.path, 'ordinary.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final hidden = Directory(p.join(root.path, '.private'))..createSync();
      final photos = Directory(
        p.join(root.path, 'Photos Library.photoslibrary'),
      )..createSync();
      final music = Directory(p.join(root.path, 'Music Library.musiclibrary'))
        ..createSync();
      final hiddenImage = File(p.join(hidden.path, 'hidden.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final photoLibraryImage = File(p.join(photos.path, 'photo.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final musicLibraryArtwork = File(p.join(music.path, 'artwork.jpg'))
        ..writeAsBytesSync([1, 2, 3]);

      final controller = FileOpenController(
        channel: _FakeFileOpenChannel(),
        slimg: _FakeSlimgApi(
          inspectResults: {
            ordinary.path: _metadata('png'),
            hiddenImage.path: _metadata('png'),
            photoLibraryImage.path: _metadata('png'),
            musicLibraryArtwork.path: _metadata('jpeg'),
          },
        ),
      );

      await controller.initialize();
      await controller.openPaths([root.path]);

      expect(controller.sessionPaths, [ordinary.path]);
    });

    test(
      'keeps the source entry when storage keeps the original file',
      () async {
        final controller = FileOpenController(
          channel: _FakeFileOpenChannel(),
          slimg: _FakeSlimgApi(
            inspectResults: {'/tmp/source.png': _metadata('png')},
          ),
          initialPaths: const ['/tmp/source.png'],
        );

        await controller.initialize();
        await controller.applyProcessResults(
          [
            BatchItemResult(
              inputPath: '/tmp/source.png',
              success: true,
              result: ProcessResult(
                outputPath: '/tmp/source.optimized.jpeg',
                format: 'jpeg',
                width: 48,
                height: 32,
                originalSize: BigInt.from(2400),
                newSize: BigInt.from(900),
                didWrite: true,
              ),
            ),
          ],
          keepSourceEntries: const {'/tmp/source.png'},
        );

        expect(controller.sessionPaths, ['/tmp/source.png']);
        expect(
          controller.currentFile?.lastResult?.outputPath,
          '/tmp/source.optimized.jpeg',
        );
      },
    );

    test(
      'renames the original after a successful keep-original conversion',
      () async {
        final root = await Directory.systemTemp.createTemp('oimg-rename-test');
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });

        final input = File('${root.path}/source.png')
          ..writeAsBytesSync([1, 2, 3]);
        final output = File('${root.path}/source.jpeg')
          ..writeAsBytesSync([4, 5, 6]);
        final renamedSource = '${root.path}/source_original.png';
        final controller = FileOpenController(
          channel: _FakeFileOpenChannel(),
          slimg: _FakeSlimgApi(
            inspectResults: {
              input.path: _metadata('png'),
              output.path: _metadata('jpeg'),
            },
          ),
          initialPaths: [input.path],
        );

        await controller.initialize();
        await controller.applyProcessResults(
          [
            BatchItemResult(
              inputPath: input.path,
              success: true,
              result: ProcessResult(
                outputPath: output.path,
                format: 'jpeg',
                width: 48,
                height: 32,
                originalSize: BigInt.from(2400),
                newSize: BigInt.from(900),
                didWrite: true,
              ),
            ),
          ],
          renameSourcesAfterSuccess: {input.path: renamedSource},
        );

        expect(controller.sessionPaths, [output.path]);
        expect(await input.exists(), isFalse);
        expect(await File(renamedSource).exists(), isTrue);
        expect(await output.exists(), isTrue);
      },
    );

    test(
      'moves optimized output into place after same-format source rename',
      () async {
        final root = await Directory.systemTemp.createTemp('oimg-move-test');
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });

        final input = File('${root.path}/source.jpg')
          ..writeAsBytesSync([1, 2, 3]);
        final temporaryOutput = File('${root.path}/source.optimized.jpeg')
          ..writeAsBytesSync([4, 5, 6]);
        final renamedSource = '${root.path}/source_original.jpg';
        final controller = FileOpenController(
          channel: _FakeFileOpenChannel(),
          slimg: _FakeSlimgApi(
            inspectResults: {
              input.path: _metadata('jpeg'),
              temporaryOutput.path: _metadata('jpeg'),
            },
          ),
          initialPaths: [input.path],
        );

        await controller.initialize();
        await controller.applyProcessResults(
          [
            BatchItemResult(
              inputPath: input.path,
              success: true,
              result: ProcessResult(
                outputPath: temporaryOutput.path,
                format: 'jpeg',
                width: 48,
                height: 32,
                originalSize: BigInt.from(2400),
                newSize: BigInt.from(900),
                didWrite: true,
              ),
            ),
          ],
          renameSourcesAfterSuccess: {input.path: renamedSource},
          moveOutputsAfterSuccess: {input.path: input.path},
        );

        expect(controller.sessionPaths, [input.path]);
        expect(await input.exists(), isTrue);
        expect(await File(renamedSource).exists(), isTrue);
        expect(await temporaryOutput.exists(), isFalse);
        expect(controller.currentFile?.lastResult?.outputPath, input.path);
      },
    );

    test(
      'deletes the original after a successful remove-original conversion',
      () async {
        final root = await Directory.systemTemp.createTemp('oimg-storage-test');
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });

        final input = File('${root.path}/source.png')
          ..writeAsBytesSync([1, 2, 3]);
        final output = File('${root.path}/source.jpeg')
          ..writeAsBytesSync([4, 5, 6]);
        final controller = FileOpenController(
          channel: _FakeFileOpenChannel(),
          slimg: _FakeSlimgApi(
            inspectResults: {
              input.path: _metadata('png'),
              output.path: _metadata('jpeg'),
            },
          ),
          initialPaths: [input.path],
        );

        await controller.initialize();
        await controller.applyProcessResults(
          [
            BatchItemResult(
              inputPath: input.path,
              success: true,
              result: ProcessResult(
                outputPath: output.path,
                format: 'jpeg',
                width: 48,
                height: 32,
                originalSize: BigInt.from(2400),
                newSize: BigInt.from(900),
                didWrite: true,
              ),
            ),
          ],
          deleteSourcesAfterSuccess: {input.path},
        );

        expect(controller.sessionPaths, [output.path]);
        expect(await input.exists(), isFalse);
        expect(await output.exists(), isTrue);
      },
    );
  });
}

ImageMetadata _metadata(String format) {
  return ImageMetadata(
    width: 48,
    height: 32,
    format: format,
    fileSize: BigInt.from(1024),
    hasTransparency: false,
    metadataSize: BigInt.zero,
  );
}

class _FakeFileOpenChannel implements FileOpenChannel {
  final List<String> shownPaths = <String>[];

  @override
  Future<void> bind(OpenFilesHandler onOpenFiles) async {}

  @override
  Future<List<String>> pickFiles() async => const <String>[];

  @override
  Future<List<String>> pickFolder() async => const <String>[];

  @override
  Future<SecurityScopedFileAccess?> pickFolderForPersistentAccess() async {
    final paths = await pickFolder();
    if (paths.isEmpty) {
      return null;
    }
    return SecurityScopedFileAccess(path: paths.first);
  }

  @override
  Future<bool> startAccessingSecurityScopedResource(String bookmark) async {
    return false;
  }

  @override
  Future<void> showInFileManager(String path) async {
    shownPaths.add(path);
  }
}

class _FakeSlimgApi implements SlimgApi {
  _FakeSlimgApi({required this.inspectResults});

  final Map<String, ImageMetadata> inspectResults;

  @override
  void setTimingLogsEnabled({required bool enabled}) {}

  @override
  Future<ImageMetadata> inspectFile({required String inputPath}) async {
    final value = inspectResults[inputPath];
    if (value == null) {
      throw StateError('unsupported');
    }
    return value;
  }

  @override
  Future<PreviewResult> previewFile({
    required PreviewFileRequest request,
  }) async {
    return PreviewResult(
      encodedBytes: Uint8List(0),
      artifactId: 'preview-artifact-test',
      format: 'png',
      width: 48,
      height: 32,
      sizeBytes: BigInt.from(512),
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
