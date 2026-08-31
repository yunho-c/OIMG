import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:oimg/src/rust/slimg_api.dart';
import 'package:oimg/src/settings/developer_diagnostics.dart';
import 'package:oimg/src/rust/types.dart';

import 'file_open_channel.dart';
import 'opened_image_file.dart';

enum ExplorerSelectionType { file, folder }

const _directoryExtensionsToSkipDuringExpansion = <String>{
  'medialibrary',
  'musiclibrary',
  'photolibrary',
  'photoslibrary',
};

class ExplorerSelection {
  const ExplorerSelection._({required this.type, required this.path});

  const ExplorerSelection.file(String path)
    : this._(type: ExplorerSelectionType.file, path: path);

  const ExplorerSelection.folder(String path)
    : this._(type: ExplorerSelectionType.folder, path: path);

  final ExplorerSelectionType type;
  final String path;
}

class FileOpenController extends ChangeNotifier {
  static const _maxConcurrentInspections = 8;

  FileOpenController({
    required FileOpenChannel channel,
    required SlimgApi slimg,
    List<String> initialPaths = const [],
  }) : _channel = channel,
       _slimg = slimg,
       _initialPaths = List<String>.unmodifiable(initialPaths);

  final FileOpenChannel _channel;
  final SlimgApi _slimg;
  final List<String> _initialPaths;

  List<OpenedImageFile> _sessionFiles = const [];
  int _currentIndex = 0;
  String? _pendingNotice;
  String? _selectedFolderPath;
  bool _isOpening = false;

  UnmodifiableListView<OpenedImageFile> get sessionFiles =>
      UnmodifiableListView(_sessionFiles);
  UnmodifiableListView<String> get sessionPaths =>
      UnmodifiableListView(_sessionFiles.map((file) => file.path).toList());

  bool get hasSession => _sessionFiles.isNotEmpty;
  bool get isOpening => _isOpening;
  int get currentIndex => _currentIndex;
  int get sessionLength => _sessionFiles.length;
  bool get canGoPrevious => _currentIndex > 0;
  bool get canGoNext => _currentIndex + 1 < _sessionFiles.length;
  OpenedImageFile? get currentFile =>
      hasSession ? _sessionFiles[_currentIndex] : null;
  String? get currentPath => currentFile?.path;
  String? get selectedFolderPath => _selectedFolderPath;
  bool get isFolderSelected => _selectedFolderPath != null;
  ExplorerSelection? get explorerSelection {
    if (_selectedFolderPath case final folderPath?) {
      return ExplorerSelection.folder(folderPath);
    }
    if (currentPath case final path?) {
      return ExplorerSelection.file(path);
    }
    return null;
  }

  String? get currentFileName =>
      currentPath == null ? null : fileNameOf(currentPath!);
  String? get currentDisplayTitle => isFolderSelected
      ? (selectedFolderName ?? selectedFolderPath)
      : currentFileName;
  String? get selectedFolderName => _selectedFolderPath == null
      ? null
      : directoryLabelOf(_selectedFolderPath!);
  UnmodifiableListView<OpenedImageFile> get selectedFolderFiles {
    if (_selectedFolderPath == null) {
      return UnmodifiableListView(const <OpenedImageFile>[]);
    }

    final files = _sessionFiles
        .where((file) => directoryOf(file.path) == _selectedFolderPath)
        .toList(growable: false);
    return UnmodifiableListView(files);
  }

  int? get selectedFolderSizeBytes {
    if (_selectedFolderPath == null) {
      return null;
    }

    var hasSize = false;
    var totalBytes = 0;
    for (final file in _sessionFiles) {
      if (directoryOf(file.path) != _selectedFolderPath) {
        continue;
      }
      final bytes = file.metadata.fileSize?.toInt();
      if (bytes == null) {
        continue;
      }
      hasSize = true;
      totalBytes += bytes;
    }
    return hasSize ? totalBytes : null;
  }

  String? get currentPositionLabel => isFolderSelected
      ? null
      : (hasSession ? '${_currentIndex + 1} / ${_sessionFiles.length}' : null);

  Future<void> initialize() async {
    await _channel.bind(openPaths);
    await openPaths(_initialPaths);
  }

  Future<void> pickFilesAndOpen() async {
    final paths = await _channel.pickFiles();
    if (paths.isEmpty) {
      return;
    }
    await openPaths(paths);
  }

  Future<void> pickFolderAndOpen() async {
    final paths = await _channel.pickFolder();
    if (paths.isEmpty) {
      return;
    }
    await openPaths(paths);
  }

  Future<SecurityScopedFileAccess?> pickStorageFolder() async {
    return _channel.pickFolderForPersistentAccess();
  }

  Future<bool> startAccessingSecurityScopedResource(String? bookmark) async {
    if (bookmark == null || bookmark.isEmpty) {
      return false;
    }
    return _channel.startAccessingSecurityScopedResource(bookmark);
  }

  Future<void> showInFileManager(String path) async {
    await _channel.showInFileManager(path);
  }

  void clearSession() {
    if (_sessionFiles.isEmpty && _selectedFolderPath == null) {
      return;
    }

    _sessionFiles = const [];
    _currentIndex = 0;
    _selectedFolderPath = null;
    _pendingNotice = null;
    notifyListeners();
  }

  Future<void> openPaths(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }

    _isOpening = true;
    notifyListeners();
    try {
      final candidatePaths = await _expandCandidatePaths(paths);
      final inspectionResults = await _inspectCandidatePaths(candidatePaths);
      final inspectedFiles = inspectionResults
          .whereType<OpenedImageFile>()
          .toList(growable: false);
      final rejectedCount = inspectionResults.length - inspectedFiles.length;

      if (inspectedFiles.isEmpty) {
        if (candidatePaths.isNotEmpty) {
          _pendingNotice = 'Some files could not be opened.';
        }
        return;
      }

      _sessionFiles = inspectedFiles;
      _currentIndex = 0;
      _selectedFolderPath = null;
      _pendingNotice = rejectedCount == 0
          ? null
          : 'Some files could not be opened.';
    } finally {
      _isOpening = false;
      notifyListeners();
    }
  }

  void showPrevious() {
    if (!canGoPrevious) {
      return;
    }

    _currentIndex -= 1;
    _selectedFolderPath = null;
    notifyListeners();
  }

  void showNext() {
    if (!canGoNext) {
      return;
    }

    _currentIndex += 1;
    _selectedFolderPath = null;
    notifyListeners();
  }

  void showPath(String path) {
    final index = _sessionFiles.indexWhere((file) => file.path == path);
    if (index == -1) {
      return;
    }
    if (index == _currentIndex && _selectedFolderPath == null) {
      return;
    }

    _currentIndex = index;
    _selectedFolderPath = null;
    notifyListeners();
  }

  void showFolder(String path) {
    final hasFilesInFolder = _sessionFiles.any(
      (file) => directoryOf(file.path) == path,
    );
    if (!hasFilesInFolder || _selectedFolderPath == path) {
      return;
    }

    _selectedFolderPath = path;
    notifyListeners();
  }

  String? takePendingNotice() {
    final notice = _pendingNotice;
    _pendingNotice = null;
    return notice;
  }

  Future<void> applyProcessResults(
    List<BatchItemResult> results, {
    Set<String> keepSourceEntries = const <String>{},
    Set<String> deleteSourcesAfterSuccess = const <String>{},
    Map<String, String> renameSourcesAfterSuccess = const <String, String>{},
    Map<String, String> moveOutputsAfterSuccess = const <String, String>{},
  }) async {
    if (_sessionFiles.isEmpty) {
      return;
    }

    final updatedFiles = _sessionFiles.toList(growable: false);
    final selectedIndex = _currentIndex;

    for (final item in results) {
      DeveloperDiagnostics.logTiming(
        'optimize-results',
        'input=${item.inputPath} success=${item.success} hasResult=${item.result != null} error=${item.error}',
      );
      final index = updatedFiles.indexWhere(
        (file) => file.path == item.inputPath,
      );
      if (index == -1) {
        continue;
      }

      if (!item.success || item.result == null) {
        DeveloperDiagnostics.logTiming(
          'optimize-results',
          'failed input=${item.inputPath} error=${item.error}',
        );
        updatedFiles[index] = updatedFiles[index].copyWith(
          lastError: item.error?.toString() ?? 'Unable to optimize file.',
          clearLastResult: true,
        );
        continue;
      }

      var result = item.result!;
      final keepSourceEntry = keepSourceEntries.contains(item.inputPath);
      final deleteSourceAfterSuccess = deleteSourcesAfterSuccess.contains(
        item.inputPath,
      );
      final sourceRenamePath = renameSourcesAfterSuccess[item.inputPath];
      final outputMovePath = moveOutputsAfterSuccess[item.inputPath];

      if (sourceRenamePath != null && !result.didWrite) {
        final effectiveResult = _copyProcessResult(
          result,
          outputPath: item.inputPath,
        );
        updatedFiles[index] = updatedFiles[index].copyWith(
          lastResult: effectiveResult,
          clearLastError: true,
        );
        continue;
      }

      if (sourceRenamePath != null && result.didWrite) {
        try {
          final actualRenamePath = await _renameSourceFile(
            from: item.inputPath,
            preferredTo: sourceRenamePath,
          );
          DeveloperDiagnostics.logTiming(
            'optimize-results',
            'renamed-source input=${item.inputPath} renamed=$actualRenamePath',
          );
        } on Object catch (error) {
          DeveloperDiagnostics.logTimingError('optimize-results', error);
          updatedFiles[index] = updatedFiles[index].copyWith(
            lastResult: result,
            lastError: 'Unable to rename original file.',
          );
          continue;
        }
      }

      if (outputMovePath != null &&
          result.didWrite &&
          result.outputPath != outputMovePath) {
        try {
          final movedOutput = await _moveOutputFile(
            from: result.outputPath,
            to: outputMovePath,
          );
          result = _copyProcessResult(result, outputPath: movedOutput);
          DeveloperDiagnostics.logTiming(
            'optimize-results',
            'moved-output from=${item.result!.outputPath} to=$movedOutput',
          );
        } on Object catch (error) {
          DeveloperDiagnostics.logTimingError('optimize-results', error);
          updatedFiles[index] = updatedFiles[index].copyWith(
            lastResult: result,
            lastError: 'Unable to move optimized file.',
          );
          continue;
        }
      }

      if (keepSourceEntry) {
        DeveloperDiagnostics.logTiming(
          'optimize-results',
          'retained-source input=${item.inputPath} output=${result.outputPath} didWrite=${result.didWrite}',
        );
        updatedFiles[index] = updatedFiles[index].copyWith(
          lastResult: result,
          clearLastError: true,
        );
        continue;
      }

      DeveloperDiagnostics.logTiming(
        'optimize-results',
        'applied input=${item.inputPath} output=${result.outputPath} didWrite=${result.didWrite} original=${result.originalSize} new=${result.newSize}',
      );
      if (deleteSourceAfterSuccess &&
          result.didWrite &&
          result.outputPath != item.inputPath) {
        try {
          final inputFile = File(item.inputPath);
          if (await inputFile.exists()) {
            await inputFile.delete();
          }
        } on Object {
          // Best-effort cleanup; the optimized file has already been written.
        }
      }
      updatedFiles[index] = OpenedImageFile(
        path: result.outputPath,
        metadata: _metadataFromProcessResult(result),
        lastResult: result,
      );
    }

    _sessionFiles = updatedFiles;
    if (_sessionFiles.isNotEmpty) {
      _currentIndex = selectedIndex.clamp(0, _sessionFiles.length - 1);
    }
    if (_selectedFolderPath case final folderPath?) {
      final folderStillExists = _sessionFiles.any(
        (file) => directoryOf(file.path) == folderPath,
      );
      if (!folderStillExists) {
        _selectedFolderPath = null;
      }
    }
    notifyListeners();
  }

  Future<OpenedImageFile?> _inspectPath(String path) async {
    try {
      final metadata = await _slimg.inspectFile(inputPath: path);
      return OpenedImageFile(path: path, metadata: metadata);
    } on Object {
      return null;
    }
  }

  Future<List<OpenedImageFile?>> _inspectCandidatePaths(
    List<String> candidatePaths,
  ) async {
    if (candidatePaths.isEmpty) {
      return const <OpenedImageFile?>[];
    }

    final results = List<OpenedImageFile?>.filled(candidatePaths.length, null);
    var nextIndex = 0;

    Future<void> inspectNext() async {
      while (nextIndex < candidatePaths.length) {
        final index = nextIndex;
        nextIndex += 1;
        results[index] = await _inspectPath(candidatePaths[index]);
      }
    }

    final workerCount = math.min(
      _maxConcurrentInspections,
      candidatePaths.length,
    );
    await Future.wait(List.generate(workerCount, (_) => inspectNext()));
    return results;
  }

  static ImageMetadata _metadataFromProcessResult(ProcessResult result) {
    return ImageMetadata(
      width: result.width,
      height: result.height,
      format: result.format,
      fileSize: result.newSize,
      hasTransparency: null,
    );
  }

  Future<String> _renameSourceFile({
    required String from,
    required String preferredTo,
  }) async {
    final source = File(from);
    if (!await source.exists()) {
      return from;
    }

    final destination = await _availableSiblingPath(preferredTo);
    await source.rename(destination);
    return destination;
  }

  Future<String> _moveOutputFile({
    required String from,
    required String to,
  }) async {
    final output = File(from);
    await output.rename(to);
    return to;
  }

  Future<String> _availableSiblingPath(String preferredPath) async {
    if (!await File(preferredPath).exists()) {
      return preferredPath;
    }

    final directory = p.dirname(preferredPath);
    final stem = p.basenameWithoutExtension(preferredPath);
    final extension = p.extension(preferredPath);
    for (var index = 1; index < 10000; index += 1) {
      final candidate = p.join(directory, '$stem-$index$extension');
      if (!await File(candidate).exists()) {
        return candidate;
      }
    }

    throw FileSystemException('Unable to find available rename path');
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

  static String fileNameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
  }

  static String directoryOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    if (separator < 0) {
      return '.';
    }
    if (separator == 0) {
      return '/';
    }
    return normalized.substring(0, separator);
  }

  static String directoryLabelOf(String directory) {
    final label = fileNameOf(directory);
    if (label.isNotEmpty) {
      return label;
    }
    return directory;
  }

  Future<List<String>> _expandCandidatePaths(List<String> paths) async {
    final expanded = <String>{};

    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final didExpand = await _expandDirectory(path, expanded);
        if (!didExpand) {
          expanded.add(path);
        }
        continue;
      }

      expanded.add(path);
    }

    return expanded.toList(growable: false);
  }

  Future<bool> _expandDirectory(String path, Set<String> expanded) async {
    if (_shouldSkipDirectoryDuringExpansion(path)) {
      return true;
    }

    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        if (entity is File) {
          expanded.add(entity.path);
        } else if (entity is Directory) {
          await _expandDirectory(entity.path, expanded);
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _shouldSkipDirectoryDuringExpansion(String path) {
    final name = p.basename(path);
    if (name.startsWith('.')) {
      return true;
    }
    return _directoryExtensionsToSkipDuringExpansion.contains(
      p.extension(name).toLowerCase().replaceFirst('.', ''),
    );
  }
}
