import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../l10n/app_localizations.dart';

/// Replaces the black scanner viewport when the camera cannot start — most
/// commonly a denied camera permission. Offers a retry and a direct path to
/// the Android app settings instead of leaving a dead black rectangle.
class ScannerErrorView extends StatelessWidget {
  const ScannerErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final Object? error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final permissionDenied = error is MobileScannerException &&
        (error as MobileScannerException).errorCode ==
            MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined,
                size: 48, color: colors.onSurface.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              permissionDenied
                  ? l10n.scannerPermissionTitle
                  : l10n.commonError,
              style: const TextStyle(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.scannerPermissionBody,
              style: TextStyle(
                  fontSize: 12.5,
                  color: colors.onSurface.withValues(alpha: 0.65)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.contactsRetry),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(l10n.scannerOpenSettings),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}