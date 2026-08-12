import 'package:flutter/material.dart';

/// Paywall screen — Free vs. Pro comparison.
/// Vorschau: Clerk-Subscription-Flow folgt in einem späteren Update.
class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
              child: const Text(
                'Vorschau',
                style: TextStyle(
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
              'Upgrade auf Snail Pro',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Unbegrenzt übersetzen, alle Sprachen, beste Qualität.',
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
                    _buildHeaderRow(),
                    _buildRow('Monatliche Nutzung', '30 Min', 'Unbegrenzt'),
                    _buildRow('Sprachen', 'DE/EN/FR/ES', 'Alle Sprachen'),
                    _buildRow('STT-Qualität', 'Standard', 'Premium (Nova-2)'),
                    _buildRow(
                        'TTS-Qualität', 'Standard', 'Natürlich (fish.audio)'),
                    _buildRow('Übersetzung', 'DeepL Free', 'DeepL Pro'),
                    _buildRow('Support', 'Community', 'Priorität'),
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
                  const SnackBar(content: Text('Upgrade-Flow folgt in Kürze!')),
                );
              },
              icon: const Icon(Icons.upgrade),
              label: const Text('Jetzt upgraden — 5,49 €/Monat'),
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
              'Jederzeit kündbar. 7 Tage kostenlos testen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  TableRow _buildHeaderRow() {
    return const TableRow(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey, width: 0.5)),
      ),
      children: [
        Padding(
          padding: EdgeInsets.all(8),
          child: Text('', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: EdgeInsets.all(8),
          child: Text('Free',
              style: TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        Padding(
          padding: EdgeInsets.all(8),
          child: Text('Pro',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.amber),
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
