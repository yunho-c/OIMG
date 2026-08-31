import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/src/settings/app_settings.dart';

void main() {
  test('defaults show coordinates in the difference tooltip', () {
    expect(AppSettings.defaults.differenceTooltipShowsCoordinates, isTrue);
    expect(AppSettings.defaults.differenceTooltipUsesSwatches, isTrue);
  });

  test('round-trips persisted same-folder directory access', () {
    final settings = AppSettings.defaults.copyWith(
      sameFolderAccesses: const [
        StoredDirectoryAccess(path: '/tmp/images', bookmark: 'bookmark-one'),
        StoredDirectoryAccess(path: '/tmp/archive', bookmark: 'bookmark-two'),
      ],
    );

    final restored = AppSettings.fromJsonString(settings.toJsonString());

    expect(restored, settings);
    expect(restored.sameFolderAccesses, hasLength(2));
  });

  test('ignores malformed persisted directory access entries', () {
    final json = AppSettings.defaults.toJson()
      ..['sameFolderAccesses'] = <Object>[
        <String, String>{'path': '/tmp/images', 'bookmark': 'bookmark'},
        <String, String>{'path': '', 'bookmark': 'missing-path'},
        <String, String>{'path': '/tmp/archive', 'bookmark': ''},
        'invalid',
      ];

    final restored = AppSettings.fromJson(json);

    expect(restored.sameFolderAccesses, const [
      StoredDirectoryAccess(path: '/tmp/images', bookmark: 'bookmark'),
    ]);
  });

  group('AppSettings.effectiveCodec', () {
    test('uses intuitive mapping when advanced mode is off', () {
      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: false,
          preferredCodec: PreferredCodec.avif,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).effectiveCodec,
        PreferredCodec.png,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.efficiency,
          advancedMode: false,
          preferredCodec: PreferredCodec.png,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).effectiveCodec,
        PreferredCodec.jxl,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: false,
          preferredCodec: PreferredCodec.avif,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).effectiveCodec,
        PreferredCodec.jpeg,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.efficiency,
          advancedMode: false,
          preferredCodec: PreferredCodec.jpeg,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).effectiveCodec,
        PreferredCodec.avif,
      );
    });

    test('uses the preferred codec when advanced mode is on', () {
      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: true,
          preferredCodec: PreferredCodec.webp,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).effectiveCodec,
        PreferredCodec.webp,
      );
    });
  });

  group('AppSettings quality helpers', () {
    test('shows quality control only for lossy selections', () {
      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: false,
          preferredCodec: PreferredCodec.jpeg,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).showsQualityControl,
        isFalse,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: false,
          preferredCodec: PreferredCodec.png,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).showsQualityControl,
        isTrue,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: true,
          preferredCodec: PreferredCodec.png,
          quality: 80,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).showsQualityControl,
        isFalse,
      );
    });

    test('only webp and jpeg xl support lossless at max quality', () {
      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: true,
          preferredCodec: PreferredCodec.webp,
          quality: 100,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).qualitySupportsLosslessAtMax,
        isTrue,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: true,
          preferredCodec: PreferredCodec.jxl,
          quality: 100,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).qualitySupportsLosslessAtMax,
        isTrue,
      );

      expect(
        const AppSettings(
          compressionMethod: CompressionMethod.lossy,
          compressionPriority: CompressionPriority.compatibility,
          advancedMode: true,
          preferredCodec: PreferredCodec.jpeg,
          quality: 100,
          storageDestinationMode: StorageDestinationMode.sameFolder,
          sameFolderAction: SameFolderAction.replaceSource,
          preserveFolderStructure: true,
          preserveOriginalDate: false,
          preserveExif: false,
          preserveColorProfile: false,
          developerModeEnabled: false,
          timingLogsEnabled: false,
        ).qualitySupportsLosslessAtMax,
        isFalse,
      );
    });

    test('defaults developer fields when older JSON omits them', () {
      final settings = AppSettings.fromJsonString(
        '{"compressionMethod":"lossy","compressionPriority":"compatibility","advancedMode":false,"preferredCodec":"jpeg","quality":80}',
      );

      expect(settings.developerModeEnabled, isFalse);
      expect(settings.timingLogsEnabled, isFalse);
      expect(settings.macOsCaptionButtonsEnabled, isFalse);
      expect(settings.previewPathHeaderEnabled, isFalse);
      expect(settings.homeShaderSpeed, AppSettings.defaultHomeShaderSpeed);
      expect(settings.homeAcrylicPanelEnabled, isTrue);
      expect(settings.bottomStatAnimationMode, BottomStatAnimationMode.ticker);
      expect(settings.effort, AppSettings.defaults.effort);
      expect(settings.pngPaletteMode, AppSettings.defaults.pngPaletteMode);
      expect(
        settings.storageDestinationMode,
        StorageDestinationMode.sameFolder,
      );
      expect(settings.sameFolderAction, SameFolderAction.replaceSource);
      expect(settings.keepSourceNaming, KeepSourceNaming.renameOptimized);
      expect(settings.keepSourceOriginalSuffix, '_original');
      expect(settings.keepSourceOptimizedSuffix, '_optimized');
      expect(settings.differentLocationPath, isNull);
      expect(settings.differentLocationBookmark, isNull);
      expect(settings.sameFolderAccesses, isEmpty);
      expect(settings.preserveFolderStructure, isTrue);
      expect(settings.preserveOriginalDate, isFalse);
      expect(settings.preserveExif, isFalse);
      expect(settings.preserveColorProfile, isFalse);
      expect(settings.qualityMetricColorsEnabled, isFalse);
      expect(settings.similarityMetricColorsEnabled, isFalse);
      expect(settings.savingsColorsEnabled, isFalse);
      expect(settings.bitsPerPixelColorsEnabled, isFalse);
      expect(settings.fileSizeColorsEnabled, isFalse);
      expect(settings.themePreference, AppThemePreference.system);
      expect(settings.colorSchemePreference, AppColorSchemePreference.slate);
    });
  });
}
