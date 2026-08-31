part of 'package:oimg/main.dart';

class _SettingsSidebar extends ConsumerWidget {
  const _SettingsSidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);
    final fileController = ref.watch(fileOpenControllerProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final runState = ref.watch(optimizationRunControllerProvider);
    final analyzeState = ref.watch(analyzeRunControllerProvider);
    final preview = ref.watch(currentPreviewProvider).asData?.value;
    final controlsLocked = runState.isRunning || analyzeState.isRunning;
    final showAnalyzePanel =
        analyzeState.isRunning ||
        (analyzeState.samples.isNotEmpty && analyzeState.isChartVisible) ||
        analyzeState.globalError != null;

    Widget buildSettingsContent(
      AppSettings settings, {
      required bool includeBottomSectionsInScroll,
    }) {
      final transparencyWarning = _transparencyWarningText(
        settings: settings,
        hasTransparency:
            !fileController.isFolderSelected &&
            (preview?.result.sourceHasTransparency ??
                fileController.currentFile?.metadata.hasTransparency ??
                false),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SettingsModeSwitcher(
            settings: settings,
            controlsLocked: controlsLocked,
            notifier: notifier,
          ),
          const SizedBox(height: 12),
          if (settings.showsQualityControl) ...[
            _SettingsLabel('Quality'),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('0').xSmall().muted(),
                const Spacer(),
                Text(_qualityValueLabel(settings)).xSmall().medium().muted(),
              ],
            ),
            const SizedBox(height: 8),
            _HoverValueSlider(
              key: const ValueKey('quality-slider'),
              value: settings.quality.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              hoverEnabled: !controlsLocked,
              onChanged: controlsLocked
                  ? null
                  : (value) {
                      notifier.setQuality(value.round());
                    },
            ),
            const SizedBox(height: 12),
          ],
          if (transparencyWarning case final warning?) ...[
            _SettingsWarningBlock(
              icon: LucideIcons.triangleAlert,
              message: warning,
            ),
            const SizedBox(height: 12),
          ],
          if (runState.globalError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(error).xSmall().muted(),
            ),
          if (includeBottomSectionsInScroll) ...[
            const SizedBox(height: 12),
            _OptimizationCollapsible(
              settings: settings,
              controlsLocked: controlsLocked,
            ),
            const SizedBox(height: 12),
            _StorageCollapsible(
              settings: settings,
              controlsLocked: controlsLocked,
            ),
            const SizedBox(height: 12),
            const _MetadataCollapsible(),
          ],
        ],
      );
    }

    return Card(
      padding: EdgeInsets.zero,
      borderRadius: theme.borderRadiusXl,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      color: theme.colorScheme.mutedForeground,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ).xSmall(),
                ),
                settings.when(
                  data: (settings) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Advanced',
                          style: TextStyle(
                            color: theme.colorScheme.mutedForeground,
                          ),
                        ).xSmall(),
                        const SizedBox(width: 8),
                        Switch(
                          value: settings.advancedMode,
                          onChanged: controlsLocked
                              ? null
                              : notifier.setAdvancedMode,
                        ),
                      ],
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final foldBottomSectionsIntoScroll =
                    showAnalyzePanel &&
                    constraints.maxHeight <
                        _settingsBottomSectionsFoldThreshold;

                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('settings-scroll-view'),
                          child: settings.when(
                            data: (settings) => buildSettingsContent(
                              settings,
                              includeBottomSectionsInScroll:
                                  foldBottomSectionsIntoScroll,
                            ),
                            loading: () => Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: const Text('Loading settings').small(),
                              ),
                            ),
                            error: (_, _) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: const Text(
                                  'Unable to load settings',
                                ).small().muted(),
                              );
                            },
                          ),
                        ),
                      ),
                      if (!foldBottomSectionsIntoScroll) ...[
                        settings.when(
                          data: (settings) => Column(
                            children: [
                              const SizedBox(height: 12),
                              _OptimizationCollapsible(
                                settings: settings,
                                controlsLocked: controlsLocked,
                              ),
                              const SizedBox(height: 12),
                              _StorageCollapsible(
                                settings: settings,
                                controlsLocked: controlsLocked,
                              ),
                            ],
                          ),
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 12),
                        const _MetadataCollapsible(),
                      ],
                      if (showAnalyzePanel) ...[
                        const SizedBox(height: 12),
                        Container(height: 1, color: theme.colorScheme.border),
                        const SizedBox(height: 12),
                        Expanded(child: _AnalyzePanel(state: analyzeState)),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsModeSwitcher extends StatelessWidget {
  const _SettingsModeSwitcher({
    required this.settings,
    required this.controlsLocked,
    required this.notifier,
  });

  final AppSettings settings;
  final bool controlsLocked;
  final AppSettingsController notifier;

  @override
  Widget build(BuildContext context) {
    final activeKey = settings.advancedMode
        ? const ValueKey('advanced-settings-mode')
        : const ValueKey('basic-settings-mode');

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final isIncoming = child.key == activeKey;
          final enteringAdvanced = settings.advancedMode;
          final enterOffset = enteringAdvanced
              ? const Offset(0.04, 0)
              : const Offset(-0.04, 0);
          final exitOffset = enteringAdvanced
              ? const Offset(-0.04, 0)
              : const Offset(0.04, 0);
          final offsetAnimation = isIncoming
              ? Tween<Offset>(
                  begin: enterOffset,
                  end: Offset.zero,
                ).animate(animation)
              : Tween<Offset>(
                  begin: exitOffset,
                  end: Offset.zero,
                ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offsetAnimation, child: child),
          );
        },
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              // ignore: use_null_aware_elements
              if (currentChild != null) currentChild,
            ],
          );
        },
        child: settings.advancedMode
            ? _AdvancedSettingsModeSection(
                key: activeKey,
                settings: settings,
                controlsLocked: controlsLocked,
                notifier: notifier,
              )
            : _BasicSettingsModeSection(
                key: activeKey,
                settings: settings,
                controlsLocked: controlsLocked,
                notifier: notifier,
              ),
      ),
    );
  }
}
