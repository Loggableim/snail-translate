import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/session_service.dart';

Future<void> _showCodeDialog(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Session-Code eingeben'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Gib den Session-Code deines Gesprächspartners ein.',
            style: TextStyle(fontSize: 14),
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
              hintText: 'snail-XXXX',
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
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Beitreten'),
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
          context.read<SessionService>().error ?? 'Beitritt fehlgeschlagen',
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
            Text('Schnellzugriff',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.qr_code_rounded,
                      label: 'Session starten',
                      color: colors.primary,
                      onTap: () => Navigator.pushNamed(context, '/qr-host'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.qr_code_scanner_rounded,
                      label: 'Beitreten',
                      color: colors.secondary,
                      onTap: () => Navigator.pushNamed(context, '/join'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.keyboard_rounded,
                      label: 'Code eingeben',
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
                      label: 'Messenger',
                      color: colors.primary,
                      onTap: () => Navigator.pushNamed(context, '/chat'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.people_alt_rounded,
                      label: 'Kontakte',
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
                title: const Text('App direkt teilen',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle:
                    const Text('APK per QR-Code im lokalen Netzwerk anbieten'),
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
                    title: const Text('Übersetzungsverlauf',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Frühere Gespräche ansehen'),
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
                  child: const Text('LIVE',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 11)))
            ]),
            SizedBox(height: compact ? 10 : 28),
            Text('Schnellübersetzer',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 21 : 25,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            if (!compact)
              const Text('Ein Gerät. Zwei Mikrofone. Sofort verständlich.',
                  style: TextStyle(color: Colors.white70, fontSize: 15)),
            SizedBox(height: compact ? 10 : 20),
            Row(children: [
              Text('Jetzt starten',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18)
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
