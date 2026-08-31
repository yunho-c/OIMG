import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oimg/src/build/distribution.dart';
import 'package:oimg/src/settings/app_settings.dart';
import 'package:oimg/src/settings/app_settings_controller.dart';
import 'package:oimg/src/settings/app_settings_repository.dart';
import 'package:oimg/src/settings/developer_diagnostics.dart';

void main() {
  group('AppSettingsController', () {
    test('loads defaults from the repository', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(store: _FakeAppSettingsStore()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final settings = await container.read(appSettingsProvider.future);

      expect(settings, AppSettings.defaults);
    });

    test('store builds keep persisted diagnostics inactive', () async {
      final storedSettings = AppSettings.defaults.copyWith(
        developerModeEnabled: true,
        timingLogsEnabled: true,
      );
      final store = _FakeAppSettingsStore()
        ..value = storedSettings.toJsonString();
      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(store: store),
          ),
        ],
      );
      addTearDown(() {
        DeveloperDiagnostics.setTimingLogsEnabled(false);
        container.dispose();
      });

      final settings = await container.read(appSettingsProvider.future);

      expect(settings.developerModeEnabled, isTrue);
      expect(settings.timingLogsEnabled, isTrue);
      expect(DeveloperDiagnostics.timingLogsEnabled, !isStoreBuild);
    });

    test('updates and persists settings changes', () async {
      final store = _FakeAppSettingsStore();
      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(store: store),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);

      await notifier.setCompressionMethod(CompressionMethod.lossless);
      await notifier.setCompressionPriority(CompressionPriority.efficiency);
      await notifier.setAdvancedMode(true);
      await notifier.setPreferredCodec(PreferredCodec.webp);
      await notifier.setQuality(92);
      await notifier.setEffort(74);
      await notifier.setPngPaletteMode(PngPalettePreference.auto);
      await notifier.setStorageDestinationMode(
        StorageDestinationMode.differentLocation,
      );
      await notifier.setSameFolderAction(SameFolderAction.keepSource);
      await notifier.setKeepSourceNaming(KeepSourceNaming.renameOriginal);
      await notifier.setKeepSourceOriginalSuffix('_raw');
      await notifier.setKeepSourceOptimizedSuffix('_small');
      await notifier.setDifferentLocation(
        path: '/tmp/export',
        bookmark: 'bookmark-data',
      );
      await notifier.setSameFolderAccesses(const [
        StoredDirectoryAccess(
          path: '/tmp/images',
          bookmark: 'same-folder-bookmark',
        ),
      ]);
      await notifier.setPreserveFolderStructure(false);
      await notifier.setPreserveOriginalDate(true);
      await notifier.setPreserveExif(true);
      await notifier.setPreserveColorProfile(true);
      await notifier.setQualityMetricColorsEnabled(true);
      await notifier.setSimilarityMetricColorsEnabled(true);
      await notifier.setSavingsColorsEnabled(true);
      await notifier.setBitsPerPixelColorsEnabled(true);
      await notifier.setFileSizeColorsEnabled(true);
      await notifier.setDifferenceTooltipShowsCoordinates(false);
      await notifier.setDifferenceTooltipUsesSwatches(true);
      await notifier.setThemePreference(AppThemePreference.dark);
      await notifier.setColorSchemePreference(AppColorSchemePreference.zinc);
      await notifier.setDeveloperModeEnabled(true);
      await notifier.setTimingLogsEnabled(true);
      await notifier.setMacOsCaptionButtonsEnabled(true);
      await notifier.setHomeAcrylicPanelEnabled(true);
      await notifier.setBottomStatAnimationMode(
        BottomStatAnimationMode.flipper,
      );

      final settings = container.read(appSettingsProvider).requireValue;
      expect(
        settings,
        const AppSettings(
          compressionMethod: CompressionMethod.lossless,
          compressionPriority: CompressionPriority.efficiency,
          advancedMode: true,
          preferredCodec: PreferredCodec.webp,
          quality: 92,
          effort: 74,
          pngPaletteMode: PngPalettePreference.auto,
          storageDestinationMode: StorageDestinationMode.differentLocation,
          sameFolderAction: SameFolderAction.keepSource,
          keepSourceNaming: KeepSourceNaming.renameOriginal,
          keepSourceOriginalSuffix: '_raw',
          keepSourceOptimizedSuffix: '_small',
          differentLocationPath: '/tmp/export',
          differentLocationBookmark: 'bookmark-data',
          sameFolderAccesses: [
            StoredDirectoryAccess(
              path: '/tmp/images',
              bookmark: 'same-folder-bookmark',
            ),
          ],
          preserveFolderStructure: false,
          preserveOriginalDate: true,
          preserveExif: true,
          preserveColorProfile: true,
          qualityMetricColorsEnabled: true,
          similarityMetricColorsEnabled: true,
          savingsColorsEnabled: true,
          bitsPerPixelColorsEnabled: true,
          fileSizeColorsEnabled: true,
          differenceTooltipShowsCoordinates: false,
          differenceTooltipUsesSwatches: true,
          themePreference: AppThemePreference.dark,
          colorSchemePreference: AppColorSchemePreference.zinc,
          developerModeEnabled: true,
          timingLogsEnabled: true,
          macOsCaptionButtonsEnabled: true,
          homeAcrylicPanelEnabled: true,
          bottomStatAnimationMode: BottomStatAnimationMode.flipper,
        ),
      );
      expect(await store.read(), settings.toJsonString());
    });
  });
}

class _FakeAppSettingsStore implements AppSettingsStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}
