import 'dart:convert';

import 'package:shadcn_flutter/shadcn_flutter.dart';

enum CompressionMethod { lossless, lossy }

enum CompressionPriority { compatibility, efficiency }

enum PreferredCodec { png, jpeg, webp, avif, jxl }

enum StorageDestinationMode { sameFolder, differentLocation }

enum SameFolderAction { replaceSource, keepSource }

enum KeepSourceNaming { renameOptimized, renameOriginal }

enum AppThemePreference { system, light, dark }

const Object _noAppSettingsValue = Object();

extension PreferredCodecCapabilities on PreferredCodec {
  bool get supportsTransparency {
    return switch (this) {
      PreferredCodec.jpeg => false,
      _ => true,
    };
  }
}

extension AppThemePreferenceValues on AppThemePreference {
  ThemeMode get themeMode {
    return switch (this) {
      AppThemePreference.system => ThemeMode.system,
      AppThemePreference.light => ThemeMode.light,
      AppThemePreference.dark => ThemeMode.dark,
    };
  }

  String get label {
    return switch (this) {
      AppThemePreference.system => 'System',
      AppThemePreference.light => 'Light',
      AppThemePreference.dark => 'Dark',
    };
  }

  AppThemePreference get next {
    return switch (this) {
      AppThemePreference.system => AppThemePreference.light,
      AppThemePreference.light => AppThemePreference.dark,
      AppThemePreference.dark => AppThemePreference.system,
    };
  }
}

class AppSettings {
  const AppSettings({
    required this.compressionMethod,
    required this.compressionPriority,
    required this.advancedMode,
    required this.preferredCodec,
    required this.quality,
    required this.storageDestinationMode,
    required this.sameFolderAction,
    this.keepSourceNaming = KeepSourceNaming.renameOptimized,
    this.keepSourceOriginalSuffix = defaultKeepSourceOriginalSuffix,
    this.keepSourceOptimizedSuffix = defaultKeepSourceOptimizedSuffix,
    required this.preserveFolderStructure,
    required this.preserveOriginalDate,
    required this.preserveExif,
    required this.preserveColorProfile,
    this.qualityMetricColorsEnabled = false,
    this.similarityMetricColorsEnabled = false,
    this.savingsColorsEnabled = false,
    this.bitsPerPixelColorsEnabled = false,
    this.fileSizeColorsEnabled = false,
    this.differenceTooltipShowsCoordinates = true,
    this.differenceTooltipUsesSwatches = true,
    this.themePreference = AppThemePreference.system,
    required this.developerModeEnabled,
    required this.timingLogsEnabled,
    this.experimentalUrbanistFontEnabled = false,
    this.macOsCaptionButtonsEnabled = false,
    this.differentLocationPath,
    this.previewPathHeaderEnabled = false,
    this.homeShaderSpeed = defaultHomeShaderSpeed,
  });

  final CompressionMethod compressionMethod;
  final CompressionPriority compressionPriority;
  final bool advancedMode;
  final PreferredCodec preferredCodec;
  final int quality;
  final StorageDestinationMode storageDestinationMode;
  final SameFolderAction sameFolderAction;
  final KeepSourceNaming keepSourceNaming;
  final String keepSourceOriginalSuffix;
  final String keepSourceOptimizedSuffix;
  final String? differentLocationPath;
  final bool preserveFolderStructure;
  final bool preserveOriginalDate;
  final bool preserveExif;
  final bool preserveColorProfile;
  final bool qualityMetricColorsEnabled;
  final bool similarityMetricColorsEnabled;
  final bool savingsColorsEnabled;
  final bool bitsPerPixelColorsEnabled;
  final bool fileSizeColorsEnabled;
  final bool differenceTooltipShowsCoordinates;
  final bool differenceTooltipUsesSwatches;
  final AppThemePreference themePreference;
  final bool developerModeEnabled;
  final bool timingLogsEnabled;
  final bool experimentalUrbanistFontEnabled;
  final bool macOsCaptionButtonsEnabled;
  final bool previewPathHeaderEnabled;
  final double homeShaderSpeed;

  static const defaultKeepSourceOriginalSuffix = '_original';
  static const defaultKeepSourceOptimizedSuffix = '_optimized';
  static const defaultHomeShaderSpeed = 0.5;

  static const defaults = AppSettings(
    compressionMethod: CompressionMethod.lossy,
    compressionPriority: CompressionPriority.compatibility,
    advancedMode: false,
    preferredCodec: PreferredCodec.jpeg,
    quality: 80,
    storageDestinationMode: StorageDestinationMode.sameFolder,
    sameFolderAction: SameFolderAction.replaceSource,
    keepSourceNaming: KeepSourceNaming.renameOptimized,
    keepSourceOriginalSuffix: defaultKeepSourceOriginalSuffix,
    keepSourceOptimizedSuffix: defaultKeepSourceOptimizedSuffix,
    preserveFolderStructure: true,
    preserveOriginalDate: false,
    preserveExif: false,
    preserveColorProfile: false,
    qualityMetricColorsEnabled: false,
    similarityMetricColorsEnabled: false,
    savingsColorsEnabled: false,
    bitsPerPixelColorsEnabled: false,
    fileSizeColorsEnabled: false,
    differenceTooltipShowsCoordinates: true,
    differenceTooltipUsesSwatches: true,
    themePreference: AppThemePreference.system,
    developerModeEnabled: false,
    timingLogsEnabled: false,
    experimentalUrbanistFontEnabled: false,
    macOsCaptionButtonsEnabled: false,
    previewPathHeaderEnabled: false,
    homeShaderSpeed: defaultHomeShaderSpeed,
  );

  PreferredCodec get effectiveCodec {
    if (advancedMode) {
      return preferredCodec;
    }

    return switch ((compressionMethod, compressionPriority)) {
      (CompressionMethod.lossless, CompressionPriority.compatibility) =>
        PreferredCodec.png,
      (CompressionMethod.lossless, CompressionPriority.efficiency) =>
        PreferredCodec.jxl,
      (CompressionMethod.lossy, CompressionPriority.compatibility) =>
        PreferredCodec.jpeg,
      (CompressionMethod.lossy, CompressionPriority.efficiency) =>
        PreferredCodec.avif,
    };
  }

  bool get showsQualityControl {
    if (!advancedMode) {
      return compressionMethod == CompressionMethod.lossy;
    }

    return switch (preferredCodec) {
      PreferredCodec.png => false,
      PreferredCodec.jpeg => true,
      PreferredCodec.webp => true,
      PreferredCodec.avif => true,
      PreferredCodec.jxl => true,
    };
  }

  bool get qualitySupportsLosslessAtMax {
    if (!showsQualityControl) {
      return false;
    }

    return switch (advancedMode ? preferredCodec : effectiveCodec) {
      PreferredCodec.webp => true,
      PreferredCodec.jxl => true,
      _ => false,
    };
  }

  AppSettings copyWith({
    CompressionMethod? compressionMethod,
    CompressionPriority? compressionPriority,
    bool? advancedMode,
    PreferredCodec? preferredCodec,
    int? quality,
    StorageDestinationMode? storageDestinationMode,
    SameFolderAction? sameFolderAction,
    KeepSourceNaming? keepSourceNaming,
    String? keepSourceOriginalSuffix,
    String? keepSourceOptimizedSuffix,
    Object? differentLocationPath = _noAppSettingsValue,
    bool? preserveFolderStructure,
    bool? preserveOriginalDate,
    bool? preserveExif,
    bool? preserveColorProfile,
    bool? qualityMetricColorsEnabled,
    bool? similarityMetricColorsEnabled,
    bool? savingsColorsEnabled,
    bool? bitsPerPixelColorsEnabled,
    bool? fileSizeColorsEnabled,
    bool? differenceTooltipShowsCoordinates,
    bool? differenceTooltipUsesSwatches,
    AppThemePreference? themePreference,
    bool? developerModeEnabled,
    bool? timingLogsEnabled,
    bool? experimentalUrbanistFontEnabled,
    bool? macOsCaptionButtonsEnabled,
    bool? previewPathHeaderEnabled,
    double? homeShaderSpeed,
  }) {
    return AppSettings(
      compressionMethod: compressionMethod ?? this.compressionMethod,
      compressionPriority: compressionPriority ?? this.compressionPriority,
      advancedMode: advancedMode ?? this.advancedMode,
      preferredCodec: preferredCodec ?? this.preferredCodec,
      quality: quality ?? this.quality,
      storageDestinationMode:
          storageDestinationMode ?? this.storageDestinationMode,
      sameFolderAction: sameFolderAction ?? this.sameFolderAction,
      keepSourceNaming: keepSourceNaming ?? this.keepSourceNaming,
      keepSourceOriginalSuffix:
          keepSourceOriginalSuffix ?? this.keepSourceOriginalSuffix,
      keepSourceOptimizedSuffix:
          keepSourceOptimizedSuffix ?? this.keepSourceOptimizedSuffix,
      differentLocationPath:
          identical(differentLocationPath, _noAppSettingsValue)
          ? this.differentLocationPath
          : differentLocationPath as String?,
      preserveFolderStructure:
          preserveFolderStructure ?? this.preserveFolderStructure,
      preserveOriginalDate: preserveOriginalDate ?? this.preserveOriginalDate,
      preserveExif: preserveExif ?? this.preserveExif,
      preserveColorProfile: preserveColorProfile ?? this.preserveColorProfile,
      qualityMetricColorsEnabled:
          qualityMetricColorsEnabled ?? this.qualityMetricColorsEnabled,
      similarityMetricColorsEnabled:
          similarityMetricColorsEnabled ?? this.similarityMetricColorsEnabled,
      savingsColorsEnabled: savingsColorsEnabled ?? this.savingsColorsEnabled,
      bitsPerPixelColorsEnabled:
          bitsPerPixelColorsEnabled ?? this.bitsPerPixelColorsEnabled,
      fileSizeColorsEnabled:
          fileSizeColorsEnabled ?? this.fileSizeColorsEnabled,
      differenceTooltipShowsCoordinates:
          differenceTooltipShowsCoordinates ??
          this.differenceTooltipShowsCoordinates,
      differenceTooltipUsesSwatches:
          differenceTooltipUsesSwatches ?? this.differenceTooltipUsesSwatches,
      themePreference: themePreference ?? this.themePreference,
      developerModeEnabled: developerModeEnabled ?? this.developerModeEnabled,
      timingLogsEnabled: timingLogsEnabled ?? this.timingLogsEnabled,
      experimentalUrbanistFontEnabled:
          experimentalUrbanistFontEnabled ??
          this.experimentalUrbanistFontEnabled,
      macOsCaptionButtonsEnabled:
          macOsCaptionButtonsEnabled ?? this.macOsCaptionButtonsEnabled,
      previewPathHeaderEnabled:
          previewPathHeaderEnabled ?? this.previewPathHeaderEnabled,
      homeShaderSpeed: homeShaderSpeed ?? this.homeShaderSpeed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'compressionMethod': compressionMethod.name,
      'compressionPriority': compressionPriority.name,
      'advancedMode': advancedMode,
      'preferredCodec': preferredCodec.name,
      'quality': quality,
      'storageDestinationMode': storageDestinationMode.name,
      'sameFolderAction': sameFolderAction.name,
      'keepSourceNaming': keepSourceNaming.name,
      'keepSourceOriginalSuffix': keepSourceOriginalSuffix,
      'keepSourceOptimizedSuffix': keepSourceOptimizedSuffix,
      'differentLocationPath': differentLocationPath,
      'preserveFolderStructure': preserveFolderStructure,
      'preserveOriginalDate': preserveOriginalDate,
      'preserveExif': preserveExif,
      'preserveColorProfile': preserveColorProfile,
      'qualityMetricColorsEnabled': qualityMetricColorsEnabled,
      'similarityMetricColorsEnabled': similarityMetricColorsEnabled,
      'savingsColorsEnabled': savingsColorsEnabled,
      'bitsPerPixelColorsEnabled': bitsPerPixelColorsEnabled,
      'fileSizeColorsEnabled': fileSizeColorsEnabled,
      'differenceTooltipShowsCoordinates': differenceTooltipShowsCoordinates,
      'differenceTooltipUsesSwatches': differenceTooltipUsesSwatches,
      'themePreference': themePreference.name,
      'developerModeEnabled': developerModeEnabled,
      'timingLogsEnabled': timingLogsEnabled,
      'experimentalUrbanistFontEnabled': experimentalUrbanistFontEnabled,
      'macOsCaptionButtonsEnabled': macOsCaptionButtonsEnabled,
      'previewPathHeaderEnabled': previewPathHeaderEnabled,
      'homeShaderSpeed': homeShaderSpeed,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static AppSettings fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Settings JSON must be an object.');
    }
    return fromJson(decoded);
  }

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      compressionMethod: CompressionMethod.values.byName(
        json['compressionMethod'] as String,
      ),
      compressionPriority: CompressionPriority.values.byName(
        json['compressionPriority'] as String,
      ),
      advancedMode: json['advancedMode'] as bool,
      preferredCodec: PreferredCodec.values.byName(
        json['preferredCodec'] as String,
      ),
      quality: json['quality'] as int? ?? defaults.quality,
      storageDestinationMode: StorageDestinationMode.values.byName(
        json['storageDestinationMode'] as String? ??
            defaults.storageDestinationMode.name,
      ),
      sameFolderAction: SameFolderAction.values.byName(
        json['sameFolderAction'] as String? ?? defaults.sameFolderAction.name,
      ),
      keepSourceNaming: KeepSourceNaming.values.byName(
        json['keepSourceNaming'] as String? ?? defaults.keepSourceNaming.name,
      ),
      keepSourceOriginalSuffix:
          json['keepSourceOriginalSuffix'] as String? ??
          defaults.keepSourceOriginalSuffix,
      keepSourceOptimizedSuffix:
          json['keepSourceOptimizedSuffix'] as String? ??
          defaults.keepSourceOptimizedSuffix,
      differentLocationPath:
          json['differentLocationPath'] as String? ??
          defaults.differentLocationPath,
      preserveFolderStructure:
          json['preserveFolderStructure'] as bool? ??
          defaults.preserveFolderStructure,
      preserveOriginalDate:
          json['preserveOriginalDate'] as bool? ??
          defaults.preserveOriginalDate,
      preserveExif: json['preserveExif'] as bool? ?? defaults.preserveExif,
      preserveColorProfile:
          json['preserveColorProfile'] as bool? ??
          defaults.preserveColorProfile,
      qualityMetricColorsEnabled:
          json['qualityMetricColorsEnabled'] as bool? ??
          defaults.qualityMetricColorsEnabled,
      similarityMetricColorsEnabled:
          json['similarityMetricColorsEnabled'] as bool? ??
          defaults.similarityMetricColorsEnabled,
      savingsColorsEnabled:
          json['savingsColorsEnabled'] as bool? ??
          defaults.savingsColorsEnabled,
      bitsPerPixelColorsEnabled:
          json['bitsPerPixelColorsEnabled'] as bool? ??
          defaults.bitsPerPixelColorsEnabled,
      fileSizeColorsEnabled:
          json['fileSizeColorsEnabled'] as bool? ??
          defaults.fileSizeColorsEnabled,
      differenceTooltipShowsCoordinates:
          json['differenceTooltipShowsCoordinates'] as bool? ??
          defaults.differenceTooltipShowsCoordinates,
      differenceTooltipUsesSwatches:
          json['differenceTooltipUsesSwatches'] as bool? ??
          defaults.differenceTooltipUsesSwatches,
      themePreference: AppThemePreference.values.byName(
        json['themePreference'] as String? ?? defaults.themePreference.name,
      ),
      developerModeEnabled:
          json['developerModeEnabled'] as bool? ??
          defaults.developerModeEnabled,
      timingLogsEnabled:
          json['timingLogsEnabled'] as bool? ?? defaults.timingLogsEnabled,
      experimentalUrbanistFontEnabled:
          json['experimentalUrbanistFontEnabled'] as bool? ??
          defaults.experimentalUrbanistFontEnabled,
      macOsCaptionButtonsEnabled:
          json['macOsCaptionButtonsEnabled'] as bool? ??
          defaults.macOsCaptionButtonsEnabled,
      previewPathHeaderEnabled:
          json['previewPathHeaderEnabled'] as bool? ??
          defaults.previewPathHeaderEnabled,
      homeShaderSpeed:
          (json['homeShaderSpeed'] as num?)?.toDouble() ??
          defaults.homeShaderSpeed,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppSettings &&
        other.compressionMethod == compressionMethod &&
        other.compressionPriority == compressionPriority &&
        other.advancedMode == advancedMode &&
        other.preferredCodec == preferredCodec &&
        other.quality == quality &&
        other.storageDestinationMode == storageDestinationMode &&
        other.sameFolderAction == sameFolderAction &&
        other.keepSourceNaming == keepSourceNaming &&
        other.keepSourceOriginalSuffix == keepSourceOriginalSuffix &&
        other.keepSourceOptimizedSuffix == keepSourceOptimizedSuffix &&
        other.differentLocationPath == differentLocationPath &&
        other.preserveFolderStructure == preserveFolderStructure &&
        other.preserveOriginalDate == preserveOriginalDate &&
        other.preserveExif == preserveExif &&
        other.preserveColorProfile == preserveColorProfile &&
        other.qualityMetricColorsEnabled == qualityMetricColorsEnabled &&
        other.similarityMetricColorsEnabled == similarityMetricColorsEnabled &&
        other.savingsColorsEnabled == savingsColorsEnabled &&
        other.bitsPerPixelColorsEnabled == bitsPerPixelColorsEnabled &&
        other.fileSizeColorsEnabled == fileSizeColorsEnabled &&
        other.differenceTooltipShowsCoordinates ==
            differenceTooltipShowsCoordinates &&
        other.differenceTooltipUsesSwatches == differenceTooltipUsesSwatches &&
        other.themePreference == themePreference &&
        other.developerModeEnabled == developerModeEnabled &&
        other.timingLogsEnabled == timingLogsEnabled &&
        other.experimentalUrbanistFontEnabled ==
            experimentalUrbanistFontEnabled &&
        other.macOsCaptionButtonsEnabled == macOsCaptionButtonsEnabled &&
        other.previewPathHeaderEnabled == previewPathHeaderEnabled &&
        other.homeShaderSpeed == homeShaderSpeed;
  }

  @override
  int get hashCode => Object.hashAll([
    compressionMethod,
    compressionPriority,
    advancedMode,
    preferredCodec,
    quality,
    storageDestinationMode,
    sameFolderAction,
    keepSourceNaming,
    keepSourceOriginalSuffix,
    keepSourceOptimizedSuffix,
    differentLocationPath,
    preserveFolderStructure,
    preserveOriginalDate,
    preserveExif,
    preserveColorProfile,
    qualityMetricColorsEnabled,
    similarityMetricColorsEnabled,
    savingsColorsEnabled,
    bitsPerPixelColorsEnabled,
    fileSizeColorsEnabled,
    differenceTooltipShowsCoordinates,
    differenceTooltipUsesSwatches,
    themePreference,
    developerModeEnabled,
    timingLogsEnabled,
    experimentalUrbanistFontEnabled,
    macOsCaptionButtonsEnabled,
    previewPathHeaderEnabled,
    homeShaderSpeed,
  ]);
}
