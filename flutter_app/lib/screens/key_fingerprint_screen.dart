import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/audio_service.dart';
import '../services/key_fingerprint.dart';

/// Shows the safety number for the current conversation.
///
/// The relay hands each side the other's public key, and nothing in that
/// exchange proves the key really belongs to the peer — a malicious relay
/// could hand out its own key to both sides and read everything. Comparing
/// this number over a channel the relay does not control (reading it aloud,
/// or looking at the other screen) is the only defence that does not require
/// trusting the relay.
class KeyFingerprintScreen extends StatelessWidget {
  const KeyFingerprintScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fingerprint = context.watch<AudioService>().keyFingerprint;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.fingerprintTitle)),
      body: fingerprint == null
          ? _NoPeerState(l10n: l10n)
          : _FingerprintBody(fingerprint: fingerprint, l10n: l10n),
    );
  }
}

class _NoPeerState extends StatelessWidget {
  const _NoPeerState({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 72),
          const SizedBox(height: 16),
          Text(l10n.fingerprintNoPeer, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _FingerprintBody extends StatelessWidget {
  const _FingerprintBody({required this.fingerprint, required this.l10n});

  final KeyFingerprint fingerprint;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = fingerprint.digits.split(' ');
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.verified_user_outlined,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text(l10n.fingerprintHeadline,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(l10n.fingerprintExplain, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        // The number itself: large, monospaced and grouped so two people can
        // read it aloud without losing their place.
        Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              for (var row = 0; row < 4; row++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (var column = 0; column < 3; column++)
                        // Flexible so a narrow screen or a large font scale
                        // shrinks the digits instead of overflowing the row.
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              groups[row * 3 + column],
                              style: const TextStyle(
                                fontSize: 20,
                                fontFeatures: [FontFeature.tabularFigures()],
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: fingerprint.digits));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.fingerprintCopied)));
          },
          icon: const Icon(Icons.copy_all_outlined),
          label: Text(l10n.fingerprintCopy),
        ),
        const SizedBox(height: 28),
        _Checklist(l10n: l10n),
      ],
    );
  }
}

/// What matching and differing numbers mean, stated plainly.
class _Checklist extends StatelessWidget {
  const _Checklist({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Line(
        icon: Icons.check_circle_outline,
        color: Colors.greenAccent,
        text: l10n.fingerprintMatchMeaning,
      ),
      const SizedBox(height: 12),
      _Line(
        icon: Icons.report_gmailerrorred_outlined,
        color: theme.colorScheme.error,
        text: l10n.fingerprintMismatchMeaning,
      ),
    ]);
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ]);
  }
}
