part of 'package:oimg/main.dart';

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
    final isOpening = ref.watch(fileOpenControllerProvider).isOpening;
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
          if (isOpening)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: theme.colorScheme.background.withValues(alpha: 0.72),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<List<String>> _readDroppedPaths(PerformDropEvent event) async {
    final pendingUris = <Future<Uri?>>[];

    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.fileUri)) {
        continue;
      }

      pendingUris.add(_readDroppedFileUri(reader));
    }

    final paths = <String>[];
    for (final uri in await Future.wait(pendingUris)) {
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
