import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// One-time welcome screen shown on first app launch.
/// Explains Snail's core value proposition before the user
/// reaches the home screen.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  static const _shownKey = 'snail_welcome_shown';

  /// Returns true if the welcome screen has already been shown.
  static Future<bool> hasBeenShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_shownKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Marks the welcome screen as shown so it never appears again.
  static Future<void> markShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_shownKey, true);
    } catch (_) {
      // Best-effort: if persistence fails, show again next launch.
    }
  }

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = CurvedAnimation(parent: _fade, curve: Curves.easeIn);
    _fade.forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await WelcomeScreen.markShown();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: FadeTransition(
          opacity: _opacity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                // ── Logo ──
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/branding/snail-logo.png',
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 32),
                // ── Headline ──
                Text(
                  'Snail',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colors.primary,
                      ),
                ),
                const SizedBox(height: 12),
                // ── Core value proposition ──
                Text(
                  'Echtzeit-Sprachübersetzung\nfür zwei Personen.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.onSurface,
                      ),
                ),
                const SizedBox(height: 20),
                // ── Explanation ──
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark
                        ? colors.surfaceContainerHighest.withValues(alpha: 0.5)
                        : colors.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    children: [
                      _FeatureRow(
                        icon: Icons.mic_rounded,
                        color: colors.primary,
                        text: 'Sprich in deiner Sprache',
                      ),
                      const SizedBox(height: 14),
                      _FeatureRow(
                        icon: Icons.translate_rounded,
                        color: colors.secondary,
                        text: 'Snail übersetzt live',
                      ),
                      const SizedBox(height: 14),
                      _FeatureRow(
                        icon: Icons.headphones_rounded,
                        color: AppTheme.mint,
                        text: 'Dein Gegenüber hört die Übersetzung',
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                // ── CTA ──
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _finish,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text(
                      'Los geht\'s',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Kein Konto nötig. Deine Daten bleiben auf deinem Gerät.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurface.withValues(alpha: 0.5),
                      ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }
}
