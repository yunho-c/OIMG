import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
import 'app_settings_repository.dart';
import 'developer_diagnostics.dart';

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  return AppSettingsRepository(store: SharedPreferencesAppSettingsStore());
});

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsController, AppSettings>(
      AppSettingsController.new,
    );

class AppSettingsController extends AsyncNotifier<AppSettings> {
  AppSettingsRepository get _repository =>
      ref.read(appSettingsRepositoryProvider);

  @override
  Future<AppSettings> build() async {
    final settings = await _repository.load();
    _applyDiagnostics(settings);
    return settings;
  }

  Future<void> setCompressionMethod(CompressionMethod compressionMethod) async {
    await _update(
      (settings) => settings.copyWith(compressionMethod: compressionMethod),
    );
  }

  Future<void> setCompressionPriority(
    CompressionPriority compressionPriority,
  ) async {
    await _update(
      (settings) => settings.copyWith(compressionPriority: compressionPriority),
    );
  }

  Future<void> setAdvancedMode(bool advancedMode) async {
    await _update((settings) => settings.copyWith(advancedMode: advancedMode));
  }

  Future<void> setPreferredCodec(PreferredCodec preferredCodec) async {
    await _update(
      (settings) => settings.copyWith(preferredCodec: preferredCodec),
    );
  }

  Future<void> setQuality(int quality) async {
    await _update((settings) => settings.copyWith(quality: quality));
  }

  Future<void> setStorageDestinationMode(
    StorageDestinationMode storageDestinationMode,
  ) async {
    await _update(
      (settings) =>
          settings.copyWith(storageDestinationMode: storageDestinationMode),
    );
  }

  Future<void> setSameFolderAction(SameFolderAction sameFolderAction) async {
    await _update(
      (settings) => settings.copyWith(sameFolderAction: sameFolderAction),
    );
  }

  Future<void> setKeepSourceNaming(KeepSourceNaming keepSourceNaming) async {
    await _update(
      (settings) => settings.copyWith(keepSourceNaming: keepSourceNaming),
    );
  }

  Future<void> setKeepSourceOriginalSuffix(
    String keepSourceOriginalSuffix,
  ) async {
    await _update(
      (settings) =>
          settings.copyWith(keepSourceOriginalSuffix: keepSourceOriginalSuffix),
    );
  }

  Future<void> setKeepSourceOptimizedSuffix(
    String keepSourceOptimizedSuffix,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        keepSourceOptimizedSuffix: keepSourceOptimizedSuffix,
      ),
    );
  }

  Future<void> setDifferentLocationPath(String? differentLocationPath) async {
    await _update(
      (settings) =>
          settings.copyWith(differentLocationPath: differentLocationPath),
    );
  }

  Future<void> setPreserveFolderStructure(bool preserveFolderStructure) async {
    await _update(
      (settings) =>
          settings.copyWith(preserveFolderStructure: preserveFolderStructure),
    );
  }

  Future<void> setPreserveOriginalDate(bool preserveOriginalDate) async {
    await _update(
      (settings) =>
          settings.copyWith(preserveOriginalDate: preserveOriginalDate),
    );
  }

  Future<void> setPreserveExif(bool preserveExif) async {
    await _update((settings) => settings.copyWith(preserveExif: preserveExif));
  }

  Future<void> setPreserveColorProfile(bool preserveColorProfile) async {
    await _update(
      (settings) =>
          settings.copyWith(preserveColorProfile: preserveColorProfile),
    );
  }

  Future<void> setQualityMetricColorsEnabled(
    bool qualityMetricColorsEnabled,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        qualityMetricColorsEnabled: qualityMetricColorsEnabled,
      ),
    );
  }

  Future<void> setSimilarityMetricColorsEnabled(
    bool similarityMetricColorsEnabled,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        similarityMetricColorsEnabled: similarityMetricColorsEnabled,
      ),
    );
  }

  Future<void> setSavingsColorsEnabled(bool savingsColorsEnabled) async {
    await _update(
      (settings) =>
          settings.copyWith(savingsColorsEnabled: savingsColorsEnabled),
    );
  }

  Future<void> setBitsPerPixelColorsEnabled(
    bool bitsPerPixelColorsEnabled,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        bitsPerPixelColorsEnabled: bitsPerPixelColorsEnabled,
      ),
    );
  }

  Future<void> setFileSizeColorsEnabled(bool fileSizeColorsEnabled) async {
    await _update(
      (settings) =>
          settings.copyWith(fileSizeColorsEnabled: fileSizeColorsEnabled),
    );
  }

  Future<void> setDifferenceTooltipShowsCoordinates(
    bool differenceTooltipShowsCoordinates,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        differenceTooltipShowsCoordinates: differenceTooltipShowsCoordinates,
      ),
    );
  }

  Future<void> setDifferenceTooltipUsesSwatches(
    bool differenceTooltipUsesSwatches,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        differenceTooltipUsesSwatches: differenceTooltipUsesSwatches,
      ),
    );
  }

  Future<void> setThemePreference(AppThemePreference themePreference) async {
    await _update(
      (settings) => settings.copyWith(themePreference: themePreference),
    );
  }

  Future<void> cycleThemePreference() async {
    await _update(
      (settings) =>
          settings.copyWith(themePreference: settings.themePreference.next),
    );
  }

  Future<void> setDeveloperModeEnabled(bool developerModeEnabled) async {
    await _update(
      (settings) => settings.copyWith(
        developerModeEnabled: developerModeEnabled,
        timingLogsEnabled: developerModeEnabled
            ? settings.timingLogsEnabled
            : false,
        experimentalUrbanistFontEnabled: developerModeEnabled
            ? settings.experimentalUrbanistFontEnabled
            : false,
        macOsCaptionButtonsEnabled: developerModeEnabled
            ? settings.macOsCaptionButtonsEnabled
            : false,
      ),
    );
  }

  Future<void> setTimingLogsEnabled(bool timingLogsEnabled) async {
    await _update(
      (settings) => settings.copyWith(timingLogsEnabled: timingLogsEnabled),
    );
  }

  Future<void> setExperimentalUrbanistFontEnabled(
    bool experimentalUrbanistFontEnabled,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        experimentalUrbanistFontEnabled: experimentalUrbanistFontEnabled,
      ),
    );
  }

  Future<void> setPreviewPathHeaderEnabled(
    bool previewPathHeaderEnabled,
  ) async {
    await _update(
      (settings) =>
          settings.copyWith(previewPathHeaderEnabled: previewPathHeaderEnabled),
    );
  }

  Future<void> setMacOsCaptionButtonsEnabled(
    bool macOsCaptionButtonsEnabled,
  ) async {
    await _update(
      (settings) => settings.copyWith(
        macOsCaptionButtonsEnabled: macOsCaptionButtonsEnabled,
      ),
    );
  }

  Future<void> setHomeShaderSpeed(double homeShaderSpeed) async {
    await _update(
      (settings) => settings.copyWith(homeShaderSpeed: homeShaderSpeed),
    );
  }

  Future<void> _update(
    AppSettings Function(AppSettings settings) transform,
  ) async {
    final currentSettings = state.hasValue ? state.requireValue : await future;
    final nextSettings = transform(currentSettings);
    _applyDiagnostics(nextSettings);
    state = AsyncData(nextSettings);
    await _repository.save(nextSettings);
  }

  void _applyDiagnostics(AppSettings settings) {
    DeveloperDiagnostics.setTimingLogsEnabled(
      settings.developerModeEnabled && settings.timingLogsEnabled,
    );
  }
}
