import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../services/snail_audio.dart';
import '../services/fish_audio_asr_service.dart';
import '../services/session_service.dart';
import '../services/provider_config_service.dart';
import '../models/provider_config.dart';

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
  final _fishAsr = FishAudioAsrService();
  bool _micInitialized = false;
  bool _micAvailable = false;
  _MicTestState _micState = _MicTestState.idle;
  Timer? _recordingTimer;
  StreamSubscription<Uint8List>? _micSubscription;
  final List<Uint8List> _recordedChunks = [];
  int _recordedBytes = 0;
  bool _playingBack = false;
  String? _micError;
  String? _micResult;
  String? _micTranscript;
  Timer? _greetingTimer;
  int _greetingIndex = 0;

  static const _greetings = <({String flag, String text, String code})>[
    (flag: '🇬🇧', text: 'Hello, choose your language.', code: 'en'),
    (flag: '🇩🇪', text: 'Hallo, wähle deine Sprache.', code: 'de'),
    (flag: '🇫🇷', text: 'Bonjour, choisis ta langue.', code: 'fr'),
    (flag: '🇪🇸', text: 'Hola, elige tu idioma.', code: 'es'),
    (flag: '🇮🇹', text: 'Ciao, scegli la tua lingua.', code: 'it'),
    (flag: '🇯🇵', text: 'こんにちは、言語を選んでください。', code: 'ja'),
    (flag: '🇰🇷', text: '안녕하세요, 언어를 선택하세요.', code: 'ko'),
    (flag: '🇨🇳', text: '你好，请选择你的语言。', code: 'zh'),
    (flag: '🇺🇦', text: 'Привіт, оберіть мову.', code: 'uk'),
  ];

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = CurvedAnimation(parent: _fade, curve: Curves.easeIn);
    _fade.forward();
    _greetingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _greetingIndex = (_greetingIndex + 1) % _greetings.length);
    });
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _micSubscription?.cancel();
    _audio.stopCapture();
    _audio.dispose();
    _greetingTimer?.cancel();
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
    final l10n = AppLocalizations.of(context);
    setState(() => _micState = _MicTestState.initializing);
    try {
      final permission = await _audio.requestMicrophonePermission();
      if (!permission) {
        if (!mounted) return;
        _micInitialized = true;
        _micAvailable = false;
        _micError = l10n.welcomeMicPermissionDenied;
        setState(() => _micState = _MicTestState.idle);
        return;
      }
      final ok = await _audio.initialize(sampleRate: 16000);
      if (!mounted) return;
      _micInitialized = true;
      _micAvailable = ok;
      _micError = ok ? null : l10n.welcomeMicUnavailable;
      setState(() => _micState = _MicTestState.idle);
    } catch (_) {
      if (!mounted) return;
      _micInitialized = true;
      _micAvailable = false;
      _micError = l10n.welcomeMicPrepareFailed;
      setState(() => _micState = _MicTestState.idle);
    }
  }

  Future<void> _startRecording() async {
    await _initMic();
    if (!_micAvailable || !mounted) return;
    final l10n = AppLocalizations.of(context);

    _recordedChunks.clear();
    _recordedBytes = 0;
    _micResult = null;
    _micTranscript = null;
    setState(() => _micState = _MicTestState.recording);

    _micSubscription = _audio.audioStream?.listen((chunk) {
      if (_micState == _MicTestState.recording) {
        _recordedChunks.add(chunk);
        _recordedBytes += chunk.length;
      }
    });
    // EventChannel installs its native listener asynchronously. Give it a
    // moment before opening AudioRecord, otherwise the first device buffers
    // can be produced before Flutter is listening.
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final started = await _audio.startCapture();
    if (!started) {
      await _micSubscription?.cancel();
      _micSubscription = null;
      if (!mounted) return;
      setState(() {
        _micState = _MicTestState.idle;
        _micError = l10n.welcomeMicStartFailed;
      });
      return;
    }

    // Record for 3 seconds
    _recordingTimer = Timer(const Duration(seconds: 3), () async {
      await _stopRecording();
    });
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    await _audio.stopCapture();
    // Native capture stops on another thread and may have one final event
    // queued on the main looper. Drain it before cancelling the subscription.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _micSubscription?.cancel();
    _micSubscription = null;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _micState =
          _recordedBytes > 0 ? _MicTestState.recorded : _MicTestState.idle;
      if (_recordedBytes > 0) {
        _micResult = l10n
            .welcomeRecordingReceived((_recordedBytes / 1024).round());
      }
      if (_recordedBytes == 0) {
        _micError = l10n.welcomeNoAudioReceived;
      }
    });
    if (_recordedBytes > 0) {
      await _playRecording();
      await _transcribeRecording();
    }
  }

  Future<void> _transcribeRecording() async {
    final l10n = AppLocalizations.of(context);
    final apiKey = context.read<ProviderConfigService>().config.apiKey.trim();
    if (apiKey.isEmpty || _recordedChunks.isEmpty) {
      if (mounted) {
        setState(() => _micResult = l10n.welcomeNeedKeyForTranscription);
      }
      return;
    }
    final bytes = BytesBuilder(copy: false);
    for (final chunk in _recordedChunks) bytes.add(chunk);
    try {
      final transcript = await _fishAsr.transcribe(
        apiKey: apiKey,
        pcm16: bytes.takeBytes(),
        sampleRate: 16000,
        language: context.read<SessionService>().myLanguage,
      );
      if (!mounted) return;
      setState(() {
        _micTranscript =
            transcript.isEmpty ? l10n.welcomeNoSpeechDetected : transcript;
        _micResult = l10n.welcomeTranscriptionSuccess;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _micResult =
          l10n.welcomeTranscriptionFailed(_shortError(error)));
    }
  }

  String _shortError(Object error) {
    final text = error.toString().replaceFirst(RegExp(r'^Exception: '), '');
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  Future<void> _playRecording() async {
    if (_recordedChunks.isEmpty || _playingBack) return;
    _playingBack = true;
    setState(() => _micState = _MicTestState.playing);
    final bytes = BytesBuilder(copy: false);
    for (final chunk in _recordedChunks) bytes.add(chunk);
    final pcm = bytes.takeBytes();
    await _audio.playPcm16(pcm, sampleRate: 16000, output: AudioOutput.speaker);
    _playingBack = false;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _micState = _MicTestState.recorded;
      _micResult = l10n.welcomePlaybackSuccess((pcm.length / 1024).round());
    });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                    const SizedBox(width: 8),
                    _PageDot(active: _currentPage == 2),
                    const SizedBox(width: 8),
                    _PageDot(active: _currentPage == 3),
                    const SizedBox(width: 8),
                    _PageDot(active: _currentPage == 4),
                  ],
                ),
              ),
              // ── Pages ──
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    // ── Page 0: language selection ──
                    _LanguageSplash(
                      greetings: _greetings,
                      greetingIndex: _greetingIndex,
                      onLanguageSelected: (code) async {
                        await context
                            .read<SessionService>()
                            .setMyLanguage(code);
                        if (mounted) setState(() {});
                      },
                      selectedLanguage:
                          context.watch<SessionService>().myLanguage,
                      onContinue: () => _goToPage(1),
                    ),
                    _ProviderKeyWelcome(onContinue: () => _goToPage(2)),
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
                              l10n.welcomeAppTagline,
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
                              child: Column(
                                children: [
                                  _FeatureRow(
                                    icon: Icons.mic_rounded,
                                    color: AppTheme.lilac,
                                    text: l10n.welcomeFeatureSpeak,
                                  ),
                                  const SizedBox(height: 14),
                                  _FeatureRow(
                                    icon: Icons.translate_rounded,
                                    color: AppTheme.mint,
                                    text: l10n.welcomeFeatureTranslate,
                                  ),
                                  const SizedBox(height: 14),
                                  _FeatureRow(
                                    icon: Icons.headphones_rounded,
                                    color: AppTheme.deepMint,
                                    text: l10n.welcomeFeatureHear,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            // ── Language confirmation ──
                            _LanguageConfirmation(),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: FilledButton.icon(
                                onPressed: () => _goToPage(3),
                                icon: const Icon(Icons.arrow_forward_rounded),
                                label: Text(
                                  l10n.commonNext,
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
                                label: Text(
                                  l10n.welcomeIHaveCode,
                                  style: const TextStyle(
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
                              l10n.welcomeNoAccountNeeded,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color:
                                        colors.onSurface.withValues(alpha: 0.5),
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
                            l10n.welcomeMicTestTitle,
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
                                    l10n.welcomeMicExplanation,
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
                                  color:
                                      colors.onSurface.withValues(alpha: 0.7),
                                ),
                          ),
                          if (_micResult != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _micResult!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (_micTranscript != null) ...[
                            const SizedBox(height: 10),
                            SelectableText(
                              l10n.welcomeTranscriptLabel(_micTranscript!),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
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
                                child: Text(l10n.commonSkip),
                              ),
                            ],
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                    // ── Page 3: Speaking direction tutorial ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 16),
                            Icon(
                              Icons.swap_horiz_rounded,
                              size: 64,
                              color: colors.primary,
                            ),
                            const SizedBox(height: 24),
                            Text(
                              l10n.welcomeHowItWorksTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              l10n.welcomeHowItWorksSubtitle,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    color:
                                        colors.onSurface.withValues(alpha: 0.7),
                                  ),
                            ),
                            const SizedBox(height: 24),
                            // ── Visual flow ──
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
                              child: Column(
                                children: [
                                  // Person A speaks
                                  _TutorialStep(
                                    icon: Icons.person_rounded,
                                    color: AppTheme.lilac,
                                    label: l10n.welcomePersonA,
                                    detail: l10n.welcomePersonASpeaks,
                                    arrow: Icons.arrow_downward_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  // Translation
                                  _TutorialStep(
                                    icon: Icons.translate_rounded,
                                    color: AppTheme.mint,
                                    label: 'Snail',
                                    detail: l10n.welcomeSnailTranslatesLive,
                                    arrow: Icons.arrow_downward_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  // Person B hears
                                  _TutorialStep(
                                    icon: Icons.headphones_rounded,
                                    color: AppTheme.deepMint,
                                    label: l10n.welcomePersonB,
                                    detail: l10n.welcomePersonBHears,
                                    arrow: Icons.arrow_upward_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  // And back
                                  _TutorialStep(
                                    icon: Icons.swap_horiz_rounded,
                                    color: colors.primary,
                                    label: l10n.welcomeAndBack,
                                    detail: l10n.welcomeBothDirections,
                                    arrow: null,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            // ── Tip ──
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.lightbulb_outline_rounded,
                                    size: 20,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      l10n.welcomeTip,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colors.onSurface
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            // ── Finish button ──
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: FilledButton.icon(
                                onPressed: _finish,
                                icon: const Icon(Icons.check_rounded),
                                label: Text(
                                  l10n.welcomeLetsGo,
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
                            const SizedBox(height: 16),
                          ],
                        ),
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
    if (_micError != null && _micState == _MicTestState.idle) return _micError!;
    final l10n = AppLocalizations.of(context);
    return switch (_micState) {
      _MicTestState.idle => l10n.welcomeMicStateIdle,
      _MicTestState.initializing => l10n.welcomeMicStateInitializing,
      _MicTestState.recording => l10n.welcomeMicStateRecording,
      _MicTestState.recorded => l10n.welcomeMicStateRecorded,
      _MicTestState.playing => l10n.welcomeMicStatePlaying,
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
        color:
            active ? colors.primary : colors.onSurface.withValues(alpha: 0.2),
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
      _MicTestState.initializing => (
          Icons.mic_rounded,
          widget.colors.onSurface.withValues(alpha: 0.4)
        ),
      _MicTestState.recording => (Icons.mic_rounded, Colors.red),
      _MicTestState.recorded => (Icons.check_circle_rounded, Colors.green),
      _MicTestState.playing => (Icons.volume_up_rounded, widget.colors.primary),
      _MicTestState.idle => (
          Icons.mic_none_rounded,
          widget.colors.onSurface.withValues(alpha: 0.4)
        ),
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
    final l10n = AppLocalizations.of(context);
    return switch (state) {
      _MicTestState.idle || _MicTestState.initializing => SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed:
                state == _MicTestState.initializing ? null : onStartRecording,
            icon: const Icon(Icons.mic_rounded),
            label: Text(
              state == _MicTestState.initializing
                  ? l10n.welcomePreparing
                  : l10n.welcomeStartRecording,
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
            label: Text(
              l10n.welcomeRecordingInProgress,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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
                  label: Text(
                    l10n.welcomePlaybackAction,
                    style: const TextStyle(
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
                  label: Text(
                    l10n.commonDone,
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
            label: Text(
              l10n.welcomePlayingEllipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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

/// Shows the auto-detected language and lets the user confirm or change it.
class _LanguageSplash extends StatelessWidget {
  const _LanguageSplash({
    required this.greetings,
    required this.greetingIndex,
    required this.selectedLanguage,
    required this.onLanguageSelected,
    required this.onContinue,
  });

  final List<({String flag, String text, String code})> greetings;
  final int greetingIndex;
  final String selectedLanguage;
  final Future<void> Function(String code) onLanguageSelected;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final greeting = greetings[greetingIndex];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Image.asset('assets/branding/snail-logo.png',
                width: 132, height: 132, fit: BoxFit.cover),
          ),
          const SizedBox(height: 28),
          Text('Snail',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w800, color: colors.primary)),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: Text('${greeting.flag}  ${greeting.text}',
                key: ValueKey(greetingIndex),
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 28),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: greetings
                .map((language) => ChoiceChip(
                      label: Text(language.flag),
                      selected: selectedLanguage == language.code,
                      tooltip: language.code.toUpperCase(),
                      onSelected: (_) => onLanguageSelected(language.code),
                    ))
                .toList(),
          ),
          const SizedBox(height: 30),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              onPressed: onContinue,
              child: Text(l10n.commonNext,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderKeyWelcome extends StatefulWidget {
  const _ProviderKeyWelcome({required this.onContinue});

  final VoidCallback onContinue;

  @override
  State<_ProviderKeyWelcome> createState() => _ProviderKeyWelcomeState();
}

class _ProviderKeyWelcomeState extends State<_ProviderKeyWelcome> {
  late final TextEditingController _key;
  ProviderConfig _config = const ProviderConfig(
    provider: TranslationProvider.fishAudio,
    endpoint: 'wss://api.fish.audio/v1/tts/live',
    model: 's2-pro',
  );
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    try {
      _config =
          Provider.of<ProviderConfigService>(context, listen: false).config;
    } catch (_) {
      // The onboarding widget is also usable in isolation (e.g. previews/tests).
    }
    _key = TextEditingController(text: _config.apiKey);
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveAndContinue() async {
    setState(() => _saving = true);
    final current = _config;
    final updated = ProviderConfig(
      provider: TranslationProvider.fishAudio,
      endpoint: 'wss://api.fish.audio/v1/tts/live',
      model: 's2-pro',
      apiKey: _key.text.trim(),
      voiceId: current.voiceId,
      latencyMode: current.latencyMode,
      temperature: current.temperature,
      topP: current.topP,
      speed: current.speed,
      translationEndpoint: current.translationEndpoint,
      translationModel: current.translationModel,
    );
    _config = updated;
    try {
      await Provider.of<ProviderConfigService>(context, listen: false)
          .save(updated);
    } catch (_) {
      // Keep onboarding functional when embedded without the app providers.
    }
    if (mounted) {
      setState(() => _saving = false);
      widget.onContinue();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.key_rounded, size: 64, color: colors.primary),
        const SizedBox(height: 20),
        Text(l10n.welcomeFishSetupTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(l10n.welcomeFishSetupBody, textAlign: TextAlign.center),
        const SizedBox(height: 22),
        TextField(
          controller: _key,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: l10n.welcomeFishApiKeyLabel,
            hintText: 'sk-fish-…',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () =>
              Navigator.of(context).pushNamed('/provider-settings'),
          icon: const Icon(Icons.tune_rounded),
          label: Text(l10n.welcomeUseOtherProvider),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            onPressed: _saving ? null : _saveAndContinue,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.commonNext,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

class _LanguageConfirmation extends StatelessWidget {
  const _LanguageConfirmation();

  static const _languages = <({String code, String name, String native})>[
    (code: 'de', name: 'Deutsch', native: 'Deutsch'),
    (code: 'en', name: 'English', native: 'English'),
    (code: 'fr', name: 'Français', native: 'Français'),
    (code: 'es', name: 'Español', native: 'Español'),
    (code: 'it', name: 'Italiano', native: 'Italiano'),
    (code: 'ja', name: 'Japanese', native: '日本語'),
    (code: 'ko', name: 'Korean', native: '한국어'),
    (code: 'zh', name: 'Chinese', native: '中文'),
    (code: 'uk', name: 'Ukrainian', native: 'Українська'),
  ];

  static String _nativeName(String code) =>
      _languages.firstWhere((l) => l.code == code).native;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionService>();
    final colors = Theme.of(context).colorScheme;
    final detectedLang = session.myLanguage;
    final detectedName = _nativeName(detectedLang);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.language_rounded, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                l10n.welcomeYourLanguage,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      detectedName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      detectedLang.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.primary.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.welcomeAutoDetected,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _showLanguagePicker(context, session),
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(l10n.welcomeChange),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Future<void> _showLanguagePicker(
      BuildContext context, SessionService session) async {
    final l10n = AppLocalizations.of(context);
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.welcomeChooseLanguage),
        children: _languages.map((lang) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, lang.code),
            child: Row(
              children: [
                Text(lang.native,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text(lang.code.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    )),
                const Spacer(),
                if (lang.code == session.myLanguage)
                  Icon(Icons.check_rounded,
                      size: 20, color: Theme.of(ctx).colorScheme.primary),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected != null && context.mounted) {
      await session.setMyLanguage(selected);
    }
  }
}

/// A single step in the speaking direction tutorial flow.
class _TutorialStep extends StatelessWidget {
  const _TutorialStep({
    required this.icon,
    required this.color,
    required this.label,
    required this.detail,
    this.arrow,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String detail;
  final IconData? arrow;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              Text(
                detail,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        if (arrow != null)
          Icon(arrow, size: 20, color: color.withValues(alpha: 0.5)),
      ],
    );
  }
}
