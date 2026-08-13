import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../services/session_service.dart';

Future<void> _showCodeDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.homeCodeDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.homeCodeDialogBody,
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 24,
              letterSpacing: 4,
            ),
            decoration: InputDecoration(
              hintText: l10n.homeCodeDialogHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(l10n.commonJoin),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty || !context.mounted) return;

  // Navigate to join screen with the code pre-filled
  final session = await context.read<SessionService>().joinRoom(result);
  if (context.mounted && session != null) {
    Navigator.pushReplacementNamed(context, '/session');
  } else if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.read<SessionService>().error ?? l10n.homeJoinFailed,
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = context.watch<ThemeProvider>();
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          _SnailLogo(size: 30),
          const SizedBox(width: 8),
          const Text('Snail', style: TextStyle(fontWeight: FontWeight.w800))
        ]),
        actions: [
          IconButton(
              onPressed: theme.toggle,
              icon: Icon(theme.isDark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined)),
          IconButton(
              onPressed: () => Navigator.pushNamed(context, '/settings'),
              icon: const Icon(Icons.tune_rounded)),
        ],
      ),
      body: ListView(
          padding: EdgeInsets.fromLTRB(20, compact ? 4 : 8, 20, 28),
          children: [
            _HeroCard(
                compact: compact,
                onTap: () => Navigator.pushNamed(context, '/standalone')),
            SizedBox(height: compact ? 12 : 24),
            Text(l10n.homeQuickAccess,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.qr_code_rounded,
                      label: l10n.homeStartSession,
                      color: colors.primary,
                      onTap: () => Navigator.pushNamed(context, '/qr-host'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.qr_code_scanner_rounded,
                      label: l10n.commonJoin,
                      color: colors.secondary,
                      onTap: () => Navigator.pushNamed(context, '/join'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.keyboard_rounded,
                      label: l10n.homeEnterCode,
                      color: colors.tertiary,
                      onTap: () => _showCodeDialog(context))),
              const SizedBox(width: 12),
              const Spacer(),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.chat_bubble_rounded,
                      label: l10n.homeMessenger,
                      color: colors.primary,
                      onTap: () => Navigator.pushNamed(context, '/chat'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.people_alt_rounded,
                      label: l10n.homeContacts,
                      color: colors.secondary,
                      onTap: () => Navigator.pushNamed(context, '/contacts'))),
            ]),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  child: Icon(Icons.share_rounded, color: colors.primary),
                ),
                title: Text(l10n.homeShareApp,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(l10n.homeShareAppSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pushNamed(context, '/app-share'),
              ),
            ),
            const SizedBox(height: 24),
            Card(
                child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    leading: CircleAvatar(
                        backgroundColor: colors.primaryContainer,
                        child:
                            Icon(Icons.history_rounded, color: colors.primary)),
                    title: Text(l10n.homeHistoryTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(l10n.homeHistorySubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pushNamed(context, '/history'))),
          ]),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final VoidCallback onTap;
  final bool compact;
  const _HeroCard({required this.onTap, required this.compact});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          padding: EdgeInsets.all(compact ? 16 : 24),
          decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                colors.primary,
                Color.alphaBlend(
                    colors.secondary.withValues(alpha: .35), colors.primary)
              ]),
              borderRadius: BorderRadius.circular(28)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const _SnailLogo(size: 44),
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(l10n.homeLiveBadge,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 11)))
            ]),
            SizedBox(height: compact ? 10 : 28),
            Text(l10n.homeQuickTranslator,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 21 : 25,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            if (!compact)
              Text(l10n.homeQuickTranslatorSubtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
            SizedBox(height: compact ? 10 : 20),
            Row(children: [
              Text(l10n.homeStartNow,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_rounded,
                  color: Colors.white, size: 18)
            ]),
          ]),
        ));
  }
}

class _SnailLogo extends StatelessWidget {
  const _SnailLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .24),
        child: Image.asset(
          'assets/branding/snail-logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      );
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
      child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: color.withValues(alpha: .13),
                            borderRadius: BorderRadius.circular(14)),
                        child: Icon(icon, color: color)),
                    const SizedBox(height: 14),
                    Text(label,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Icon(Icons.arrow_outward_rounded, size: 16)
                  ]))));
}
