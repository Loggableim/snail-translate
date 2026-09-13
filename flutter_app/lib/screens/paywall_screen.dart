import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Static upgrade screen behind the Profile "Upgrade" button.
///
/// The billing flow is not wired up yet (see `paywallUpgradeFlowSoon` in the
/// arb files), so the purchase button is intentionally disabled. The screen
/// exists so the route never crashes and the pricing promise stays visible.
class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileUpgrade)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.workspace_premium_rounded,
              size: 72, color: colors.primary),
          const SizedBox(height: 16),
          Text(
            l10n.paywallUpgradeTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.paywallUpgradeBody,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(
                    color: colors.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 24),
          _PaywallRow(
            icon: Icons.timer_outlined,
            label: l10n.paywallRowMonthlyUsage,
            free: l10n.paywallFreeMinutes,
            pro: l10n.paywallUnlimited,
          ),
          _PaywallRow(
            icon: Icons.language_rounded,
            label: l10n.paywallRowLanguages,
            free: l10n.paywallStandard,
            pro: l10n.paywallAllLanguages,
          ),
          _PaywallRow(
            icon: Icons.support_agent_rounded,
            label: l10n.paywallRowSupport,
            free: l10n.paywallCommunity,
            pro: l10n.paywallPriority,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              // No billing backend yet: the flow is announced, not sold.
              onPressed: null,
              icon: const Icon(Icons.upgrade_rounded),
              label: Text(l10n.paywallUpgradeNow),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.paywallUpgradeFlowSoon,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.paywallCancelAnytime,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

class _PaywallRow extends StatelessWidget {
  const _PaywallRow({
    required this.icon,
    required this.label,
    required this.free,
    required this.pro,
  });

  final IconData icon;
  final String label;
  final String free;
  final String pro;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text('${l10n.paywallFree}: $free',
                      style: TextStyle(
                          fontSize: 13,
                          color:
                              colors.onSurface.withValues(alpha: 0.6)))),
              Expanded(
                  child: Text('${l10n.paywallPro}: $pro',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          ],
        ),
      ),
    );
  }
}