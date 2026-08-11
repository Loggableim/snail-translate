import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_share_service.dart';

class AppShareScreen extends StatelessWidget {
  const AppShareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final share = context.watch<AppShareService>();
    return Scaffold(
      appBar: AppBar(title: const Text('App direkt teilen')),
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
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.phone_android_rounded,
              size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          Text('Direkt von diesem Gerät',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(
            'Der HTTPS-Link wird über Cloudflare vermittelt. Die APK bleibt auf diesem Gerät und wird erst beim Download direkt übertragen.',
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
            label: Text(share.isPreparing ? 'Link wird vorbereitet …' : 'Download anbieten'),
          ),
          const SizedBox(height: 12),
          Text(
              'Der Empfänger muss Android erlauben, Apps aus dieser Quelle zu installieren.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _ActiveShare extends StatelessWidget {
  const _ActiveShare({required this.share});
  final AppShareService share;

  @override
  Widget build(BuildContext context) {
    final url = share.url!;
    return ListView(
      shrinkWrap: true,
      children: [
        Text('Download bereit',
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
            'Läuft bis ${_time(share.expiresAt)} • ${share.downloads} Downloads',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 14),
        Text(share.status, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: share.isTransferring ? share.progress : null),
        if (share.isTransferring || share.transferredBytes > 0) ...[
          const SizedBox(height: 6),
          Text('${_bytes(share.transferredBytes)} von ${_bytes(share.apkBytes)} • ${_bytes(share.bytesPerSecond)}/s', textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Link kopiert')));
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Link kopieren'),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
            onPressed: share.share,
            icon: const Icon(Icons.share_rounded),
            label: const Text('Teilen')),
        TextButton.icon(
            onPressed: share.stop,
            icon: const Icon(Icons.close_rounded),
            label: const Text('Download beenden')),
      ],
    );
  }

  String _bytes(num? value) =>
      value == null ? '—' : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  String _time(DateTime? value) => value == null
      ? '—'
      : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
