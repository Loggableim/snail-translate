import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Paywall screen — Free vs. Pro comparison.
/// Vorschau: Clerk-Subscription-Flow folgt in einem späteren Update.
class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snail Pro'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                l10n.paywallPreviewBadge,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.workspace_premium, size: 64, color: Colors.amber),
            const SizedBox(height: 16),
            Text(
              l10n.paywallUpgradeTitle,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.paywallUpgradeBody,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // Comparison table
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2),
                    1: FlexColumnWidth(1),
                    2: FlexColumnWidth(1),
                  },
                  children: [
                    _buildHeaderRow(l10n),
                    _buildRow(l10n.paywallRowMonthlyUsage, l10n.paywallFreeMinutes,
                        l10n.paywallUnlimited),
                    _buildRow(l10n.paywallRowLanguages, 'DE/EN/FR/ES',
                        l10n.paywallAllLanguages),
                    _buildRow(l10n.paywallRowSttQuality, l10n.paywallStandard,
                        l10n.paywallPremiumNova2),
                    _buildRow(l10n.paywallRowTtsQuality, l10n.paywallStandard,
                        l10n.paywallNaturalFishAudio),
                    _buildRow(l10n.paywallRowTranslation, 'DeepL Free', 'DeepL Pro'),
                    _buildRow(l10n.paywallRowSupport, l10n.paywallCommunity,
                        l10n.paywallPriority),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),

            // CTA
            ElevatedButton.icon(
              onPressed: () {
                // TODO: Clerk subscription flow
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.paywallUpgradeFlowSoon)),
                );
              },
              icon: const Icon(Icons.upgrade),
              label: Text(l10n.paywallUpgradeNow),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.paywallCancelAnytime,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  TableRow _buildHeaderRow(AppLocalizations l10n) {
    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey, width: 0.5)),
      ),
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(l10n.paywallFree,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(l10n.paywallPro,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.amber),
              textAlign: TextAlign.center),
        ),
      ],
    );
  }

  TableRow _buildRow(String feature, String free, String pro) {
    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey, width: 0.5)),
      ),
      children: [
        Padding(padding: const EdgeInsets.all(8), child: Text(feature)),
        Padding(
            padding: const EdgeInsets.all(8),
            child: Text(free, textAlign: TextAlign.center)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(pro,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.amber)),
        ),
      ],
    );
  }
}
