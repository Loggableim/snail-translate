import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/app_share_service.dart';

class AppShareScreen extends StatelessWidget {
  const AppShareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final share = context.watch<AppShareService>();
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).appShareTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: share.isSharing
                ? _ActiveShare(share: share)
                : _StartShare(share: share),
          ),
        ),
      ),
    );
  }
}

class _StartShare extends StatelessWidget {
  const _StartShare({required this.share});
  final AppShareService share;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.phone_android_rounded,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 20),
        Text(l10n.appShareDirectTitle,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Text(
          l10n.appShareDirectBody,
          textAlign: TextAlign.center,
        ),
        if (share.error != null) ...[
          const SizedBox(height: 16),
          Text(share.error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: share.isPreparing ? null : share.start,
          icon: const Icon(Icons.qr_code_rounded),
          label: Text(share.isPreparing
              ? l10n.appSharePreparingLink
              : l10n.appShareOfferDownload),
        ),
        const SizedBox(height: 12),
        Text(l10n.appShareInstallSourceHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ActiveShare extends StatelessWidget {
  const _ActiveShare({required this.share});
  final AppShareService share;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final url = share.url!;
    return ListView(
      shrinkWrap: true,
      children: [
        Text(l10n.appShareDownloadReady,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 18),
        Center(
            child: QrImageView(
                data: url, size: 250, backgroundColor: Colors.white)),
        const SizedBox(height: 18),
        Text('Snail ${share.version ?? ''} • ${_bytes(share.apkBytes)}',
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
            l10n.appShareExpiresInfo(
                _time(share.expiresAt), share.downloads),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 14),
        Text(share.status,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: share.isTransferring ? share.progress : null),
        if (share.isTransferring || share.transferredBytes > 0) ...[
          const SizedBox(height: 6),
          Text(
              l10n.appShareTransferProgress(_bytes(share.transferredBytes),
                  _bytes(share.apkBytes), '${_bytes(share.bytesPerSecond)}/s'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: Text(l10n.appShareCopyLink),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
            onPressed: share.share,
            icon: const Icon(Icons.share_rounded),
            label: Text(l10n.commonShare)),
        TextButton.icon(
            onPressed: share.stop,
            icon: const Icon(Icons.close_rounded),
            label: Text(l10n.appShareStopDownload)),
      ],
    );
  }

  String _bytes(num? value) =>
      value == null ? '—' : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  String _time(DateTime? value) => value == null
      ? '—'
      : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
