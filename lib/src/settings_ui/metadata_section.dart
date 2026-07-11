part of 'package:oimg/main.dart';

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
    final fileController = ref.watch(fileOpenControllerProvider);
    final metadata = fileController.isFolderSelected
        ? null
        : fileController.currentFile?.metadata;
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
                Expanded(
                  child: Row(
                    children: [
                      const Text('Metadata').small().medium(),
                      if (metadata != null &&
                          metadata.metadataSize > BigInt.zero) ...[
                        const SizedBox(width: 6),
                        Text(
                          _formatBytes(metadata.metadataSize.toInt()),
                        ).xSmall().muted(),
                      ],
                    ],
                  ),
                ),
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
                              label: metadata?.colorProfile == null
                                  ? 'Preserve color'
                                  : 'Preserve color  ·  ${_formatBytes(metadata!.colorProfile!.sizeBytes.toInt())}',
                              value: settings.preserveColorProfile,
                              onChanged: notifier.setPreserveColorProfile,
                            ),
                            option(
                              key: const ValueKey('metadata-preserve-exif'),
                              label: metadata?.exif == null
                                  ? 'Preserve camera info'
                                  : 'Preserve camera info  ·  ${_formatBytes(metadata!.exif!.sizeBytes.toInt())}',
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
