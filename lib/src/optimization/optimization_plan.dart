import 'package:path/path.dart' as p;

import 'package:oimg/src/file_open/opened_image_file.dart';
import 'package:oimg/src/rust/types.dart';
import 'package:oimg/src/settings/app_settings.dart';

class OptimizationPlan {
  const OptimizationPlan({
    required this.sourceFile,
    required this.targetCodec,
    required this.processRequest,
    required this.previewRequest,
    required this.useSourceImageForPreview,
    required this.keepSourceEntry,
    required this.deleteSourceAfterSuccess,
    this.renameSourceAfterSuccessPath,
    this.moveOutputAfterSuccessPath,
  });

  final OpenedImageFile sourceFile;
  final PreferredCodec targetCodec;
  final ProcessFileRequest processRequest;
  final PreviewFileRequest previewRequest;
  final bool useSourceImageForPreview;
  final bool keepSourceEntry;
  final bool deleteSourceAfterSuccess;
  final String? renameSourceAfterSuccessPath;
  final String? moveOutputAfterSuccessPath;

  bool get usesSourceCodec =>
      sourceFile.metadata.format == codecIdOf(targetCodec);
}

OptimizationPlan buildOptimizationPlan({
  required OpenedImageFile file,
  required AppSettings settings,
  String? sourceRootPath,
}) {
  final targetCodec = settings.effectiveCodec;
  final targetFormat = codecIdOf(targetCodec);
  final usesSourceCodec = file.metadata.format == targetFormat;
  final effectiveQuality = settings.showsQualityControl
      ? settings.quality
      : 100;
  final effort = settings.effort;
  final pngPaletteMode = targetCodec == PreferredCodec.png
      ? _pngPaletteModeOf(settings.pngPaletteMode)
      : null;
  final useSourceImageForPreview =
      settings.preserveColorProfile &&
      switch (targetCodec) {
        PreferredCodec.png =>
          settings.pngPaletteMode == PngPalettePreference.off,
        PreferredCodec.webp => effectiveQuality == 100,
        PreferredCodec.jxl => effectiveQuality == 100,
        _ => false,
      };
  final operation = usesSourceCodec
      ? ImageOperation.optimize(
          OptimizeOptions(
            quality: effectiveQuality,
            effort: effort,
            pngPalette: pngPaletteMode,
            writeOnlyIfSmaller: true,
          ),
        )
      : ImageOperation.convert(
          ConvertOptions(
            targetFormat: targetFormat,
            quality: effectiveQuality,
            effort: effort,
            pngPalette: pngPaletteMode,
          ),
        );
  final storageDecision = _resolveStorageDecision(
    file: file,
    settings: settings,
    targetFormat: targetFormat,
    usesSourceCodec: usesSourceCodec,
    sourceRootPath: sourceRootPath,
  );

  return OptimizationPlan(
    sourceFile: file,
    targetCodec: targetCodec,
    useSourceImageForPreview: useSourceImageForPreview,
    processRequest: ProcessFileRequest(
      inputPath: file.path,
      outputPath: storageDecision.outputPath,
      overwrite: storageDecision.overwrite,
      preserveFileDates: settings.preserveOriginalDate,
      preserveExif: settings.preserveExif,
      colorProfileMode: settings.preserveColorProfile
          ? ColorProfileMode.preserve
          : ColorProfileMode.bakeToSrgb,
      operation: operation,
    ),
    previewRequest: PreviewFileRequest(
      inputPath: file.path,
      operation: operation,
      colorProfileMode: settings.preserveColorProfile
          ? ColorProfileMode.preserve
          : ColorProfileMode.bakeToSrgb,
    ),
    keepSourceEntry: storageDecision.keepSourceEntry,
    deleteSourceAfterSuccess: storageDecision.deleteSourceAfterSuccess,
    renameSourceAfterSuccessPath: storageDecision.renameSourceAfterSuccessPath,
    moveOutputAfterSuccessPath: storageDecision.moveOutputAfterSuccessPath,
  );
}

PngPaletteMode _pngPaletteModeOf(PngPalettePreference preference) {
  return switch (preference) {
    PngPalettePreference.off => PngPaletteMode.off,
    PngPalettePreference.auto => PngPaletteMode.auto,
    PngPalettePreference.on => PngPaletteMode.on_,
  };
}

String codecIdOf(PreferredCodec codec) {
  return switch (codec) {
    PreferredCodec.png => 'png',
    PreferredCodec.jpeg => 'jpeg',
    PreferredCodec.webp => 'webp',
    PreferredCodec.avif => 'avif',
    PreferredCodec.jxl => 'jxl',
  };
}

String codecLabel(PreferredCodec codec) {
  return switch (codec) {
    PreferredCodec.png => 'PNG',
    PreferredCodec.jpeg => 'JPEG',
    PreferredCodec.webp => 'WebP',
    PreferredCodec.avif => 'AVIF',
    PreferredCodec.jxl => 'JPEG XL',
  };
}

PreferredCodec? codecFromFormatId(String format) {
  for (final codec in PreferredCodec.values) {
    if (codecIdOf(codec) == format) {
      return codec;
    }
  }
  return null;
}

String formatLabel(String format) {
  final codec = codecFromFormatId(format);
  if (codec != null) {
    return codecLabel(codec);
  }
  return format.toUpperCase();
}

String _suffixedSiblingPath(String path, String suffix, String targetFormat) {
  final stem = p.basenameWithoutExtension(path);
  return p.join(p.dirname(path), '$stem$suffix.$targetFormat');
}

String _suffixedOriginalPath(String path, String suffix) {
  final stem = p.basenameWithoutExtension(path);
  return p.join(p.dirname(path), '$stem$suffix${p.extension(path)}');
}

String _replacementSiblingPath(String path, String targetFormat) {
  final stem = p.basenameWithoutExtension(path);
  return p.join(p.dirname(path), '$stem.$targetFormat');
}

String _renameOriginalTemporaryOutputPath(String path, String targetFormat) {
  final stem = p.basenameWithoutExtension(path);
  return p.join(p.dirname(path), '$stem.optimized.$targetFormat');
}

String _effectiveSuffix(String suffix, String fallback) {
  final safeSuffix = suffix.replaceAll(RegExp(r'[\\/]+'), '');
  return safeSuffix.isEmpty ? fallback : safeSuffix;
}

class _StorageDecision {
  const _StorageDecision({
    required this.outputPath,
    required this.overwrite,
    required this.keepSourceEntry,
    required this.deleteSourceAfterSuccess,
    this.renameSourceAfterSuccessPath,
    this.moveOutputAfterSuccessPath,
  });

  final String? outputPath;
  final bool overwrite;
  final bool keepSourceEntry;
  final bool deleteSourceAfterSuccess;
  final String? renameSourceAfterSuccessPath;
  final String? moveOutputAfterSuccessPath;
}

_StorageDecision _resolveStorageDecision({
  required OpenedImageFile file,
  required AppSettings settings,
  required String targetFormat,
  required bool usesSourceCodec,
  required String? sourceRootPath,
}) {
  if (settings.storageDestinationMode == StorageDestinationMode.sameFolder) {
    if (settings.sameFolderAction == SameFolderAction.keepSource) {
      switch (settings.keepSourceNaming) {
        case KeepSourceNaming.renameOptimized:
          final suffix = _effectiveSuffix(
            settings.keepSourceOptimizedSuffix,
            AppSettings.defaultKeepSourceOptimizedSuffix,
          );
          return _StorageDecision(
            outputPath: _suffixedSiblingPath(file.path, suffix, targetFormat),
            overwrite: true,
            keepSourceEntry: true,
            deleteSourceAfterSuccess: false,
          );
        case KeepSourceNaming.renameOriginal:
          final suffix = _effectiveSuffix(
            settings.keepSourceOriginalSuffix,
            AppSettings.defaultKeepSourceOriginalSuffix,
          );
          return _StorageDecision(
            outputPath: usesSourceCodec
                ? _renameOriginalTemporaryOutputPath(file.path, targetFormat)
                : _replacementSiblingPath(file.path, targetFormat),
            overwrite: true,
            keepSourceEntry: false,
            deleteSourceAfterSuccess: false,
            renameSourceAfterSuccessPath: _suffixedOriginalPath(
              file.path,
              suffix,
            ),
            moveOutputAfterSuccessPath: usesSourceCodec ? file.path : null,
          );
      }
    }

    return _StorageDecision(
      outputPath: usesSourceCodec
          ? null
          : _replacementSiblingPath(file.path, targetFormat),
      overwrite: true,
      keepSourceEntry: false,
      deleteSourceAfterSuccess: !usesSourceCodec,
    );
  }

  final outputRoot = settings.differentLocationPath;
  if (outputRoot == null || outputRoot.isEmpty) {
    return _StorageDecision(
      outputPath: usesSourceCodec
          ? null
          : _replacementSiblingPath(file.path, targetFormat),
      overwrite: true,
      keepSourceEntry: false,
      deleteSourceAfterSuccess: !usesSourceCodec,
    );
  }

  return _StorageDecision(
    outputPath: _differentLocationOutputPath(
      filePath: file.path,
      outputRoot: outputRoot,
      targetFormat: targetFormat,
      preserveFolderStructure: settings.preserveFolderStructure,
      sourceRootPath: sourceRootPath,
    ),
    overwrite: true,
    keepSourceEntry: true,
    deleteSourceAfterSuccess: false,
  );
}

String _differentLocationOutputPath({
  required String filePath,
  required String outputRoot,
  required String targetFormat,
  required bool preserveFolderStructure,
  required String? sourceRootPath,
}) {
  final fileName =
      '${p.basenameWithoutExtension(filePath)}.optimized.$targetFormat';
  if (!preserveFolderStructure || sourceRootPath == null) {
    return p.join(outputRoot, fileName);
  }

  final sourceDirectory = p.dirname(filePath);
  final normalizedRoot = p.normalize(sourceRootPath);
  final normalizedDirectory = p.normalize(sourceDirectory);
  if (!p.isWithin(normalizedRoot, normalizedDirectory) &&
      normalizedDirectory != normalizedRoot) {
    return p.join(outputRoot, fileName);
  }

  final relativeDirectory = p.relative(
    normalizedDirectory,
    from: normalizedRoot,
  );
  if (relativeDirectory == '.') {
    return p.join(outputRoot, fileName);
  }

  return p.join(outputRoot, relativeDirectory, fileName);
}
