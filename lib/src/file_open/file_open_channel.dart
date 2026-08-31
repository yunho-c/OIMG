import 'dart:async';

import 'package:flutter/services.dart';

typedef OpenFilesHandler = Future<void> Function(List<String> paths);

class SecurityScopedFileAccess {
  const SecurityScopedFileAccess({required this.path, this.bookmark});

  final String path;
  final String? bookmark;
}

abstract class FileOpenChannel {
  Future<void> bind(OpenFilesHandler onOpenFiles);
  Future<List<String>> pickFiles();
  Future<List<String>> pickFolder();

  Future<SecurityScopedFileAccess?> pickFolderForPersistentAccess() async {
    final paths = await pickFolder();
    if (paths.isEmpty) {
      return null;
    }
    return SecurityScopedFileAccess(path: paths.first);
  }

  Future<bool> startAccessingSecurityScopedResource(String bookmark) async {
    return false;
  }

  Future<bool> ensureWritableDirectoryAccess(List<String> paths);

  Future<void> showInFileManager(String path);
}

class MethodChannelFileOpenChannel implements FileOpenChannel {
  MethodChannelFileOpenChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'oimg/file_open';

  final MethodChannel _channel;

  @override
  Future<void> bind(OpenFilesHandler onOpenFiles) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openFiles') {
        throw MissingPluginException('Unknown method: ${call.method}');
      }

      final arguments = call.arguments;
      if (arguments is! List) {
        return;
      }

      final paths = arguments.whereType<String>().toList(growable: false);
      await onOpenFiles(paths);
    });

    unawaited(_waitForNativeChannel());
  }

  Future<void> _waitForNativeChannel() async {
    for (var attempt = 0; attempt < 50; attempt += 1) {
      try {
        await _channel.invokeMethod<void>('ready');
        return;
      } on MissingPluginException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  @override
  Future<List<String>> pickFiles() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('pickFiles');
      return _parsePathList(result);
    } on MissingPluginException {
      return const <String>[];
    }
  }

  @override
  Future<List<String>> pickFolder() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('pickFolder');
      return _parsePathList(result);
    } on MissingPluginException {
      return const <String>[];
    }
  }

  @override
  Future<SecurityScopedFileAccess?> pickFolderForPersistentAccess() async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'pickFolderForPersistentAccess',
      );
      if (result is Map) {
        final path = result['path'];
        if (path is! String || path.isEmpty) {
          return null;
        }
        final bookmark = result['bookmark'];
        return SecurityScopedFileAccess(
          path: path,
          bookmark: bookmark is String && bookmark.isNotEmpty ? bookmark : null,
        );
      }
    } on MissingPluginException {
      return _pickFolderForPersistentAccessFallback();
    }

    return null;
  }

  Future<SecurityScopedFileAccess?>
  _pickFolderForPersistentAccessFallback() async {
    final paths = await pickFolder();
    if (paths.isEmpty) {
      return null;
    }
    return SecurityScopedFileAccess(path: paths.first);
  }

  @override
  Future<bool> startAccessingSecurityScopedResource(String bookmark) async {
    if (bookmark.isEmpty) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>(
        'startAccessingSecurityScopedResource',
        bookmark,
      );
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> ensureWritableDirectoryAccess(List<String> paths) async {
    if (paths.isEmpty) {
      return true;
    }
    try {
      final result = await _channel.invokeMethod<bool>(
        'ensureWritableDirectoryAccess',
        paths,
      );
      return result ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> showInFileManager(String path) async {
    try {
      await _channel.invokeMethod<void>('showInFileManager', path);
    } on MissingPluginException {
      return;
    }
  }

  List<String> _parsePathList(List<Object?>? paths) {
    if (paths == null) {
      return const <String>[];
    }
    return paths.whereType<String>().toList(growable: false);
  }
}
