part of 'package:oimg/main.dart';

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  final fractionDigits = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}

String? _fileSizeLabel(OpenedImageFile file) {
  final bytes = file.metadata.fileSize?.toInt();
  if (bytes == null) {
    return null;
  }
  return _formatBytes(bytes);
}

String? _folderSizeLabel(List<OpenedImageFile> files) {
  var hasSize = false;
  var totalBytes = 0;
  for (final file in files) {
    final bytes = file.metadata.fileSize?.toInt();
    if (bytes == null) {
      continue;
    }
    hasSize = true;
    totalBytes += bytes;
  }
  if (!hasSize) {
    return null;
  }
  return _formatBytes(totalBytes);
}

String? _showInFileManagerLabel() {
  if (Platform.isMacOS) {
    return 'Show in Finder';
  }
  if (Platform.isWindows) {
    return 'Show in File Explorer';
  }
  if (Platform.isLinux) {
    return 'Show in File Manager';
  }
  return null;
}

String _qualityValueLabel(AppSettings settings) {
  if (settings.quality == 100 && settings.qualitySupportsLosslessAtMax) {
    return 'Lossless';
  }

  return '${settings.quality}';
}

String _pngPaletteLabel(PngPalettePreference mode) {
  return switch (mode) {
    PngPalettePreference.off => 'Off',
    PngPalettePreference.auto => 'Auto',
    PngPalettePreference.on => 'On',
  };
}

String? _paletteSuggestionLabel(PaletteSuitability? suitability) {
  if (suitability == null) {
    return null;
  }

  return switch (suitability.recommendation) {
    PaletteRecommendation.on_ => '(Suggested: On)',
    PaletteRecommendation.review => '(Suggested: On)',
    PaletteRecommendation.off => '(Suggested: Off)',
  };
}

String? _paletteSuggestionTooltip(PaletteSuitability? suitability) {
  if (suitability == null) {
    return null;
  }

  final uniqueColors = suitability.uniqueColorCountExceeded
      ? '>${_formatInteger(suitability.uniqueColorCount)}'
      : _formatInteger(suitability.uniqueColorCount);
  return 'Unique colors: $uniqueColors';
}

String _formatInteger(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i += 1) {
    final remaining = digits.length - i;
    if (i > 0 && remaining % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
