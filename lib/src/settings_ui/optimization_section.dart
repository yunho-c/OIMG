part of 'package:oimg/main.dart';

class _OptimizationCollapsible extends ConsumerStatefulWidget {
  const _OptimizationCollapsible({
    required this.settings,
    required this.controlsLocked,
  });

  final AppSettings settings;
  final bool controlsLocked;

  @override
  ConsumerState<_OptimizationCollapsible> createState() =>
      _OptimizationCollapsibleState();
}

class _OptimizationCollapsibleState
    extends ConsumerState<_OptimizationCollapsible> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(appSettingsProvider.notifier);
    final gjxlBackendCompiled = ref.watch(gjxlBackendCompiledProvider);
    final jxlEncoderPreference = ref.watch(jxlEncoderPreferenceProvider);
    final paletteSuitability = ref
        .watch(currentPreviewProvider)
        .asData
        ?.value
        ?.result
        .paletteSuitability;

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              children: [
                Expanded(child: const Text('Optimization').small().medium()),
                GhostButton(
                  key: const ValueKey('optimization-collapsible-toggle'),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SettingsLabel('Effort'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text('0').xSmall().muted(),
                          const Spacer(),
                          Text(
                            '${widget.settings.effort}',
                          ).xSmall().medium().muted(),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _HoverValueSlider(
                        key: const ValueKey('effort-slider'),
                        value: widget.settings.effort.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 100,
                        hoverEnabled: !widget.controlsLocked,
                        hoverOpacityKey: const ValueKey(
                          'effort-slider-hover-opacity',
                        ),
                        hoverValueKey: const ValueKey(
                          'effort-slider-hover-value',
                        ),
                        onChanged: widget.controlsLocked
                            ? null
                            : (value) {
                                notifier.setEffort(value.round());
                              },
                      ),
                      if (widget.settings.effectiveCodec ==
                              PreferredCodec.jxl &&
                          gjxlBackendCompiled) ...[
                        const SizedBox(height: 12),
                        Checkbox(
                          key: const ValueKey('prefer-gjxl-checkbox'),
                          state:
                              jxlEncoderPreference ==
                                  JxlEncoderPreference.preferGjxl
                              ? CheckboxState.checked
                              : CheckboxState.unchecked,
                          onChanged: widget.controlsLocked
                              ? null
                              : (value) {
                                  ref
                                      .read(
                                        jxlEncoderPreferenceProvider.notifier,
                                      )
                                      .setPreferGjxl(
                                        value == CheckboxState.checked,
                                      );
                                },
                          trailing: Expanded(
                            child: const Text('Use GJXL').small(),
                          ),
                        ),
                      ],
                      if (widget.settings.effectiveCodec ==
                          PreferredCodec.png) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const _SettingsLabel('Palette'),
                            const Spacer(),
                            if (_paletteSuggestionLabel(paletteSuitability)
                                case final suggestion?)
                              Tooltip(
                                tooltip: (context) => TooltipContainer(
                                  child: Text(
                                    _paletteSuggestionTooltip(
                                      paletteSuitability,
                                    )!,
                                  ),
                                ),
                                child: Text(suggestion).xSmall().muted(),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _PngPaletteTabs(
                          value: widget.settings.pngPaletteMode,
                          onChanged: widget.controlsLocked
                              ? null
                              : notifier.setPngPaletteMode,
                        ),
                      ],
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

class _PngPaletteTabs extends StatelessWidget {
  const _PngPaletteTabs({required this.value, required this.onChanged});

  final PngPalettePreference value;
  final ValueChanged<PngPalettePreference>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = PngPalettePreference.values.indexOf(value);
    final enabled = onChanged != null;

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: TabContainer(
        selected: selectedIndex,
        onSelect: enabled
            ? (index) {
                onChanged?.call(PngPalettePreference.values[index]);
              }
            : null,
        builder: (context, children) {
          return _SlidingTabTrack(
            selectedIndex: selectedIndex,
            itemCount: PngPalettePreference.values.length,
            children: children,
          );
        },
        childBuilder: _buildTab,
        children: [
          for (final mode in PngPalettePreference.values)
            TabItem(child: Text(_pngPaletteLabel(mode))),
        ],
      ),
    );
  }

  Widget _buildTab(BuildContext context, TabContainerData data, Widget child) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final densityGap = theme.density.baseGap * scaling;
    final densityContentPadding = theme.density.baseContentPadding * scaling;
    final compTheme = ComponentTheme.maybeOf<TabsTheme>(context);
    final tabPadding = styleValue(
      defaultValue: EdgeInsets.symmetric(
        horizontal: densityContentPadding,
        vertical: densityGap * 0.5,
      ),
      themeValue: compTheme?.tabPadding,
      widgetValue: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    );
    final selected = data.index == data.selected;
    final selectable = data.onSelect != null;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: selectable ? () => data.onSelect?.call(data.index) : null,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        cursor: selectable
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          alignment: Alignment.center,
          padding: tabPadding,
          child: (selected ? child.foreground() : child.muted())
              .small()
              .medium(),
        ),
      ),
    );
  }
}

class _SlidingTabTrack extends StatelessWidget {
  const _SlidingTabTrack({
    required this.selectedIndex,
    required this.itemCount,
    required this.children,
  });

  final int selectedIndex;
  final int itemCount;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final densityGap = theme.density.baseGap * scaling;
    final compTheme = ComponentTheme.maybeOf<TabsTheme>(context);
    final containerPadding = styleValue(
      defaultValue: EdgeInsets.all(densityGap * 0.5),
      themeValue: compTheme?.containerPadding,
    );
    final backgroundColor = styleValue(
      defaultValue: theme.colorScheme.muted,
      themeValue: compTheme?.backgroundColor,
    );
    final borderRadius = styleValue(
      defaultValue: BorderRadius.circular(theme.radiusLg),
      themeValue: compTheme?.borderRadius,
    );
    final resolvedBorderRadius = borderRadius is BorderRadius
        ? borderRadius
        : borderRadius.resolve(Directionality.of(context));

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: resolvedBorderRadius,
      ),
      padding: containerPadding,
      child: ClipRRect(
        borderRadius: resolvedBorderRadius,
        child: IntrinsicHeight(
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: _alignmentFor(selectedIndex),
                  child: FractionallySizedBox(
                    widthFactor: 1 / itemCount,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.background,
                        borderRadius: BorderRadius.circular(theme.radiusMd),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in children) Expanded(child: child),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Alignment _alignmentFor(int index) {
    if (itemCount <= 1) {
      return Alignment.center;
    }
    return Alignment(-1 + (2 * index / (itemCount - 1)), 0);
  }
}
