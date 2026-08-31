part of 'package:oimg/main.dart';

class _BottomSidebar extends ConsumerStatefulWidget {
  const _BottomSidebar({required this.controller});

  final FileOpenController controller;

  @override
  ConsumerState<_BottomSidebar> createState() => _BottomSidebarState();
}

class _BottomSidebarState extends ConsumerState<_BottomSidebar> {
  static const double _optimizeEtaSmoothing = 0.12;
  static const _optimizeEstimateDisplayInterval = Duration(seconds: 3);

  Timer? _optimizeSuccessTimer;
  Timer? _optimizeProgressTimer;
  DateTime? _optimizeProgressStartedAt;
  DateTime? _optimizeProgressLastCompletedAt;
  DateTime? _optimizeProgressLastEstimateDisplayedAt;
  int _optimizeProgressLastCompletedCount = 0;
  Duration? _optimizeProgressSmoothedItemDuration;
  Duration _optimizeProgressElapsed = Duration.zero;
  Duration? _optimizeProgressDisplayedEstimate;
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
    _stopOptimizeProgressTimer();
    super.dispose();
  }

  void _handleOptimizationRunStateChanged(
    OptimizationRunState? previous,
    OptimizationRunState next,
  ) {
    if (next.isRunning || next.jobState == BatchJobState.cancelRequested) {
      _clearOptimizeSuccess();
      if (previous?.isRunning != true) {
        _startOptimizeProgressTimer();
      }
      _updateOptimizeProgressEstimate(next);
      return;
    }

    if (previous?.isRunning == true) {
      _stopOptimizeProgressTimer();
    }

    final hasItemFailures = next.items.values.any(
      (item) => item.status == OptimizationItemStatus.failed,
    );
    if (next.jobState == BatchJobState.completed &&
        !hasItemFailures &&
        previous?.jobState != BatchJobState.completed) {
      _showOptimizeSuccessState();
      return;
    }

    if (hasItemFailures ||
        next.jobState == BatchJobState.failed ||
        next.jobState == BatchJobState.canceled) {
      _clearOptimizeSuccess();
    }
  }

  void _startOptimizeProgressTimer() {
    _optimizeProgressTimer?.cancel();
    final now = DateTime.now();
    _optimizeProgressStartedAt = now;
    _optimizeProgressLastCompletedAt = now;
    _optimizeProgressLastEstimateDisplayedAt = null;
    _optimizeProgressLastCompletedCount = 0;
    _optimizeProgressSmoothedItemDuration = null;
    _optimizeProgressElapsed = Duration.zero;
    _optimizeProgressDisplayedEstimate = null;
    _optimizeProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _optimizeProgressStartedAt;
      if (!mounted || startedAt == null) {
        return;
      }
      setState(() {
        _optimizeProgressElapsed = DateTime.now().difference(startedAt);
      });
    });
  }

  void _stopOptimizeProgressTimer() {
    _optimizeProgressTimer?.cancel();
    _optimizeProgressTimer = null;
    _optimizeProgressStartedAt = null;
    _optimizeProgressLastCompletedAt = null;
    _optimizeProgressLastEstimateDisplayedAt = null;
    _optimizeProgressLastCompletedCount = 0;
    _optimizeProgressSmoothedItemDuration = null;
    _optimizeProgressElapsed = Duration.zero;
    _optimizeProgressDisplayedEstimate = null;
  }

  void _updateOptimizeProgressEstimate(OptimizationRunState state) {
    final completedDelta =
        state.completedCount - _optimizeProgressLastCompletedCount;
    if (completedDelta <= 0) {
      return;
    }

    final now = DateTime.now();
    final lastCompletedAt = _optimizeProgressLastCompletedAt ?? now;
    final latestItemDuration = Duration(
      microseconds:
          now.difference(lastCompletedAt).inMicroseconds ~/ completedDelta,
    );
    final previousSmoothedDuration = _optimizeProgressSmoothedItemDuration;
    _optimizeProgressSmoothedItemDuration = previousSmoothedDuration == null
        ? latestItemDuration
        : Duration(
            microseconds:
                (_optimizeEtaSmoothing * latestItemDuration.inMicroseconds +
                        (1 - _optimizeEtaSmoothing) *
                            previousSmoothedDuration.inMicroseconds)
                    .round(),
          );
    _optimizeProgressLastCompletedAt = now;
    _optimizeProgressLastCompletedCount = state.completedCount;
    _maybeUpdateOptimizeProgressDisplayedEstimate(state, now);
  }

  void _maybeUpdateOptimizeProgressDisplayedEstimate(
    OptimizationRunState state,
    DateTime now,
  ) {
    final startedAt = _optimizeProgressStartedAt;
    final smoothedItemDuration = _optimizeProgressSmoothedItemDuration;
    if (startedAt == null ||
        smoothedItemDuration == null ||
        state.completedCount <= 0 ||
        state.totalCount <= 0) {
      _optimizeProgressDisplayedEstimate = null;
      _optimizeProgressLastEstimateDisplayedAt = null;
      return;
    }

    final lastDisplayedAt = _optimizeProgressLastEstimateDisplayedAt;
    if (_optimizeProgressDisplayedEstimate != null &&
        lastDisplayedAt != null &&
        now.difference(lastDisplayedAt) < _optimizeEstimateDisplayInterval) {
      return;
    }

    _optimizeProgressDisplayedEstimate = Duration(
      microseconds:
          now.difference(startedAt).inMicroseconds +
          smoothedItemDuration.inMicroseconds *
              (state.totalCount - state.completedCount),
    );
    _optimizeProgressLastEstimateDisplayedAt = now;
  }

  void _showOptimizeSuccessState() {
    _optimizeSuccessTimer?.cancel();
    if (!_showOptimizeSuccess) {
      setState(() {
        _showOptimizeSuccess = true;
      });
    }
    _optimizeSuccessTimer = Timer(const Duration(seconds: 3), () {
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
    final statsRetentionKey = controller.isFolderSelected
        ? 'folder:${controller.selectedFolderPath ?? controller.selectedFolderName ?? ''}'
        : 'file:${currentFile.path}';

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
                          child: _BottomStatsSection(
                            stats: summary.stats,
                            retentionKey: statsRetentionKey,
                          ),
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
                          if (runState.isRunning &&
                              runState.totalCount > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  '${runState.completedCount}/${runState.totalCount}',
                                  key: const ValueKey(
                                    'optimize-progress-count',
                                  ),
                                  style: TextStyle(
                                    color: theme.colorScheme.mutedForeground,
                                  ),
                                ).xSmall(),
                                const Spacer(),
                                Text(
                                  _formatOptimizeProgressTime(
                                    elapsed: _optimizeProgressElapsed,
                                    estimate:
                                        _optimizeProgressDisplayedEstimate,
                                  ),
                                  key: const ValueKey('optimize-progress-time'),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color: theme.colorScheme.mutedForeground,
                                  ),
                                ).xSmall(),
                              ],
                            ),
                          ] else if (analyzeState.isRunning &&
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
