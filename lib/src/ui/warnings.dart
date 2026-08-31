part of 'package:oimg/main.dart';

String? _transparencyWarningText({
  required AppSettings settings,
  required bool hasTransparency,
}) {
  if (!hasTransparency) {
    return null;
  }

  final codec = settings.effectiveCodec;
  if (codec.supportsTransparency) {
    return null;
  }

  return '${codecLabel(codec)} does not support transparency. Transparent areas will be flattened.';
}

String? _optimizedPreviewSizeWarningText({
  required FileOpenController controller,
  required OpenedImageFile? file,
  required OptimizedPreviewDisplay? optimizedDisplay,
}) {
  if (controller.isFolderSelected || file == null || optimizedDisplay == null) {
    return null;
  }

  final originalBytes = _originalFileSizeBytes(file);
  if (originalBytes == null) {
    return null;
  }

  return optimizedDisplay.sizeBytes.toInt() > originalBytes
      ? 'Original image is smaller.'
      : null;
}

class _SettingsWarningBlock extends StatelessWidget {
  const _SettingsWarningBlock({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const warningTint = Color(0xFFC75A5A);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          warningTint.withValues(alpha: 0.08),
          theme.colorScheme.background.withValues(alpha: 0.94),
        ),
        borderRadius: theme.borderRadiusLg,
        border: Border.all(
          color: Color.alphaBlend(
            warningTint.withValues(alpha: 0.18),
            theme.colorScheme.border.withValues(alpha: 0.92),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: warningTint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.mutedForeground,
                height: 1.4,
              ),
            ).small(),
          ),
        ],
      ),
    );
  }
}
