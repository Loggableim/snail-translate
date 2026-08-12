import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../services/snail_audio.dart';

/// One-time guided onboarding shown on first app launch.
///
/// Two steps:
/// 1. Core value proposition — what Snail does
/// 2. Microphone test — record a short sample and hear it played back
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
  final _pageController = PageController();
  int _currentPage = 0;

  // ── Microphone test state ──
  final _audio = SnailAudio();
  bool _micInitialized = false;
  bool _micAvailable = false;
  _MicTestState _micState = _MicTestState.idle;
  Timer? _recordingTimer;
  StreamSubscription<Uint8List>? _micSubscription;
  final List<Uint8List> _recordedChunks = [];
  bool _playingBack = false;

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
    _recordingTimer?.cancel();
    _micSubscription?.cancel();
    _audio.stopCapture();
    _audio.dispose();
    _pageController.dispose();
    _fade.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await WelcomeScreen.markShown();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/');
  }

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  // ── Microphone test ──

  Future<void> _initMic() async {
    if (_micInitialized) return;
    setState(() => _micState = _MicTestState.initializing);
    try {
      final ok = await _audio.initialize(sampleRate: 16000);
      if (!mounted) return;
      _micInitialized = true;
      _micAvailable = ok;
      setState(() => _micState = _MicTestState.idle);
    } catch (_) {
      if (!mounted) return;
      _micInitialized = true;
      _micAvailable = false;
      setState(() => _micState = _MicTestState.idle);
    }
  }

  Future<void> _startRecording() async {
    await _initMic();
    if (!_micAvailable || !mounted) return;

    _recordedChunks.clear();
    setState(() => _micState = _MicTestState.recording);

    _micSubscription = _audio.audioStream?.listen((chunk) {
      if (_micState == _MicTestState.recording) {
        _recordedChunks.add(chunk);
      }
    });

    await _audio.startCapture();

    // Record for 3 seconds
    _recordingTimer = Timer(const Duration(seconds: 3), () async {
      await _stopRecording();
    });
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    await _micSubscription?.cancel();
    _micSubscription = null;
    await _audio.stopCapture();
    if (!mounted) return;
    setState(() => _micState = _MicTestState.recorded);
  }

  Future<void> _playRecording() async {
    if (_recordedChunks.isEmpty || _playingBack) return;
    _playingBack = true;
    setState(() => _micState = _MicTestState.playing);
    for (final chunk in _recordedChunks) {
      if (!mounted) break;
      await _audio.playPcm16(chunk, sampleRate: 16000);
    }
    _playingBack = false;
    if (!mounted) return;
    setState(() => _micState = _MicTestState.recorded);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: FadeTransition(
          opacity: _opacity,
          child: Column(
            children: [
              // ── Page indicator ──
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PageDot(active: _currentPage == 0),
                    const SizedBox(width: 8),
                    _PageDot(active: _currentPage == 1),
                  ],
                ),
              ),
              // ── Pages ──
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (page) =>
                      setState(() => _currentPage = page),
                  children: [
                    // ── Page 1: Value proposition ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 16),
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
                          Text(
                            'Snail',
                            style: Theme.of(context)
                                .textTheme
                                .headlineLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: colors.primary,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Echtzeit-Sprachübersetzung\nfür zwei Personen.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onSurface,
                                ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? colors.surfaceContainerHighest
                                      .withValues(alpha: 0.5)
                                  : colors.primaryContainer
                                      .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Column(
                              children: [
                                _FeatureRow(
                                  icon: Icons.mic_rounded,
                                  color: AppTheme.lilac,
                                  text: 'Sprich in deiner Sprache',
                                ),
                                SizedBox(height: 14),
                                _FeatureRow(
                                  icon: Icons.translate_rounded,
                                  color: AppTheme.mint,
                                  text: 'Snail übersetzt live',
                                ),
                                SizedBox(height: 14),
                                _FeatureRow(
                                  icon: Icons.headphones_rounded,
                                  color: AppTheme.deepMint,
                                  text:
                                      'Dein Gegenüber hört die Übersetzung',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox.shrink(),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: FilledButton.icon(
                              onPressed: () => _goToPage(1),
                              icon: const Icon(Icons.arrow_forward_rounded),
                              label: const Text(
                                'Weiter',
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
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await WelcomeScreen.markShown();
                                if (!context.mounted) return;
                                Navigator.of(context)
                                    .pushReplacementNamed('/join');
                              },
                              icon: const Icon(Icons.login_rounded, size: 20),
                              label: const Text(
                                'Ich habe einen Code',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Kein Konto nötig. '
                            'Deine Daten bleiben auf deinem Gerät.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: colors.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                      ),
                    ),
                    // ── Page 2: Microphone test ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox.shrink(),
                          // ── Mic icon with state ──
                          _MicIcon(state: _micState, colors: colors),
                          const SizedBox(height: 24),
                          Text(
                            'Mikrofon testen',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 12),
                          // ── Permission explanation ──
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? colors.surfaceContainerHighest
                                      .withValues(alpha: 0.4)
                                  : colors.primaryContainer
                                      .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 20,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Snail braucht dein Mikrofon, um deine '
                                    'Sprache live zu übersetzen. '
                                    'Deine Stimme wird nur während einer '
                                    'aktiven Session aufgenommen. '
                                    'Nichts wird dauerhaft gespeichert.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.onSurface
                                          .withValues(alpha: 0.75),
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _micStateDescription(),
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  color: colors.onSurface
                                      .withValues(alpha: 0.7),
                                ),
                          ),
                          const SizedBox.shrink(),
                          // ── Action buttons ──
                          _MicActionButton(
                            state: _micState,
                            onStartRecording: _startRecording,
                            onPlayRecording: _playRecording,
                            onFinish: _finish,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              TextButton(
                                onPressed: _finish,
                                child: const Text('Überspringen'),
                              ),
                            ],
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _micStateDescription() {
    return switch (_micState) {
      _MicTestState.idle =>
        'Sprich kurz etwas in dein Mikrofon, '
            'damit du sicher bist, dass alles funktioniert.',
      _MicTestState.initializing => 'Mikrofon wird vorbereitet …',
      _MicTestState.recording =>
        'Aufnahme läuft — sprich jetzt! (3 Sekunden)',
      _MicTestState.recorded =>
        'Aufnahme gespeichert. Hör sie dir an oder fahre fort.',
      _MicTestState.playing => 'Aufnahme wird abgespielt …',
    };
  }
}

// ── Mic test state enum ──

enum _MicTestState { idle, initializing, recording, recorded, playing }

// ── Page dot indicator ──

class _PageDot extends StatelessWidget {
  const _PageDot({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: active ? 24 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active
            ? colors.primary
            : colors.onSurface.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

// ── Mic icon with state animation ──

class _MicIcon extends StatefulWidget {
  const _MicIcon({required this.state, required this.colors});
  final _MicTestState state;
  final ColorScheme colors;

  @override
  State<_MicIcon> createState() => _MicIconState();
}

class _MicIconState extends State<_MicIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(_MicIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state == _MicTestState.recording) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.reset();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (widget.state) {
      _MicTestState.initializing => (Icons.mic_rounded,
          widget.colors.onSurface.withValues(alpha: 0.4)),
      _MicTestState.recording => (Icons.mic_rounded, Colors.red),
      _MicTestState.recorded => (Icons.check_circle_rounded, Colors.green),
      _MicTestState.playing => (Icons.volume_up_rounded, widget.colors.primary),
      _MicTestState.idle => (Icons.mic_none_rounded,
          widget.colors.onSurface.withValues(alpha: 0.4)),
    };

    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 44),
      ),
    );
  }
}

// ── Action button for mic test page ──

class _MicActionButton extends StatelessWidget {
  const _MicActionButton({
    required this.state,
    required this.onStartRecording,
    required this.onPlayRecording,
    required this.onFinish,
  });

  final _MicTestState state;
  final VoidCallback onStartRecording;
  final VoidCallback onPlayRecording;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      _MicTestState.idle ||
      _MicTestState.initializing =>
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed:
                state == _MicTestState.initializing ? null : onStartRecording,
            icon: const Icon(Icons.mic_rounded),
            label: Text(
              state == _MicTestState.initializing
                  ? 'Wird vorbereitet …'
                  : 'Aufnahme starten',
              style: const TextStyle(
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
      _MicTestState.recording => SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: const Text(
              'Aufnahme läuft …',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
      _MicTestState.recorded => Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: onPlayRecording,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text(
                    'Abspielen',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: onFinish,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text(
                    'Fertig',
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
            ),
          ],
        ),
      _MicTestState.playing => SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: const Text(
              'Wiedergabe …',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
    };
  }
}

// ── Feature row (shared) ──

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
