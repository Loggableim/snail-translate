import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/session_service.dart';
import '../services/contact_service.dart';

/// Status steps for the QR scan → join flow.
enum _JoinStep {
  starting,   // Camera initialising
  scanning,   // Looking for a QR code
  detected,   // QR code found, processing
  joining,    // Connecting to session
  error,      // Something went wrong
}

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _codeController = TextEditingController();
  _JoinStep _step = _JoinStep.starting;
  String? _error;
  String? _detectedCode;

  @override
  void initState() {
    super.initState();
    // After first frame, mark camera as ready → scanning
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _step = _JoinStep.scanning);
    });
  }

  Future<void> _joinRoom(String roomId) async {
    setState(() {
      _step = _JoinStep.joining;
      _error = null;
    });
    final session = await context.read<SessionService>().joinRoom(roomId);
    if (mounted && session != null) {
      // Success — navigation happens, no need to update step
      Navigator.pushReplacementNamed(context, '/session');
    } else if (mounted) {
      setState(() {
        _step = _JoinStep.error;
        _error =
            context.read<SessionService>().error ?? 'Beitritt fehlgeschlagen';
      });
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_step != _JoinStep.scanning) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      if (value.startsWith('snail://user/')) {
        setState(() {
          _step = _JoinStep.detected;
          _detectedCode = 'Kontakt';
        });
        _saveContactQr(value);
        return;
      }
      final roomId = _roomIdFromQr(value);
      if (roomId != null) {
        setState(() {
          _step = _JoinStep.detected;
          _detectedCode = roomId;
        });
        _joinRoom(roomId);
        return;
      }
    }
  }

  /// Accept the compact current QR (`snail-AAYV`) and the former URI forms,
  /// but never stop scanning for a value that is not an exact room code.
  String? _roomIdFromQr(String value) {
    final trimmed = value.trim();
    String candidate = trimmed;
    if (trimmed.toLowerCase().startsWith('snail:')) {
      candidate = trimmed.substring(6).split('?').first;
    } else if (trimmed.contains('room=')) {
      candidate = Uri.tryParse(trimmed)?.queryParameters['room'] ?? '';
    }
    candidate = candidate.trim().toUpperCase();
    return RegExp(r'^snail-[A-Z2-9]{4}$', caseSensitive: false)
            .hasMatch(candidate)
        ? candidate
        : null;
  }

  Future<void> _saveContactQr(String value) async {
    final saved = await context.read<ContactService>().addFromQr(value);
    if (!mounted) return;
    if (saved) {
      Navigator.pushReplacementNamed(context, '/contacts');
    } else {
      setState(() {
        _step = _JoinStep.error;
        _error = 'Ungültige Snail-Identität';
      });
    }
  }

  void _retry() {
    setState(() {
      _step = _JoinStep.scanning;
      _error = null;
      _detectedCode = null;
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  // ── Status step helpers ──

  IconData _stepIcon(_JoinStep step) => switch (step) {
        _JoinStep.starting => Icons.camera_alt_outlined,
        _JoinStep.scanning => Icons.qr_code_scanner_rounded,
        _JoinStep.detected => Icons.check_circle_outline_rounded,
        _JoinStep.joining => Icons.sync_rounded,
        _JoinStep.error => Icons.error_outline_rounded,
      };

  String _stepLabel(_JoinStep step) => switch (step) {
        _JoinStep.starting => 'Kamera wird gestartet …',
        _JoinStep.scanning => 'QR-Code suchen …',
        _JoinStep.detected => 'QR-Code erkannt!',
        _JoinStep.joining => 'Session wird beigetreten …',
        _JoinStep.error => 'Fehler',
      };

  String? _stepSubtitle(_JoinStep step) => switch (step) {
        _JoinStep.starting => 'Bitte warten',
        _JoinStep.scanning =>
          'Richte die Kamera auf den Snail-QR-Code deines Gesprächspartners',
        _JoinStep.detected =>
          _detectedCode != null ? 'Code: $_detectedCode' : 'Wird verarbeitet …',
        _JoinStep.joining => 'Verbindung wird aufgebaut',
        _JoinStep.error => _error ?? 'Unbekannter Fehler',
      };

  Color _stepColor(_JoinStep step, ColorScheme colors) => switch (step) {
        _JoinStep.starting ||
        _JoinStep.scanning =>
          colors.primary,
        _JoinStep.detected ||
        _JoinStep.joining =>
          Colors.orange,
        _JoinStep.error => colors.error,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final availableHeight = MediaQuery.sizeOf(context).height;

    if (landscape && _step != _JoinStep.joining) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session beitreten')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: _landscapeCodeForm(context),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Session beitreten')),
      body: _step == _JoinStep.joining
          ? const Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Trete Session bei...')
                ]))
          : Column(
              children: [
                // ── Scrollable content ──
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Scanner area ──
                        if (_step == _JoinStep.starting ||
                            _step == _JoinStep.scanning)
                          SizedBox(
                            height: landscape ? 230 : availableHeight * .48,
                            child: Stack(
                              children: [
                                if (_step != _JoinStep.starting)
                                  MobileScanner(onDetect: _onDetect),
                                Center(
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 400),
                                    width: 220,
                                    height: 220,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: _step == _JoinStep.scanning
                                            ? colors.primary
                                            : colors.outline
                                                .withValues(alpha: 0.3),
                                        width: 2,
                                      ),
                                      borderRadius:
                                          BorderRadius.circular(16),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // ── Manual code entry ──
                        SizedBox(
                          height: landscape ? 360 : availableHeight * .52,
                          child: Padding(
                            padding: EdgeInsets.all(landscape ? 12 : 24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('Oder Code eingeben:',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _codeController,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 24,
                                      letterSpacing: 4),
                                  decoration: InputDecoration(
                                    hintText: 'snail-XXXX',
                                    border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  onPressed: _step == _JoinStep.joining
                                      ? null
                                      : () {
                                          final code =
                                              _codeController.text.trim();
                                          if (code.isNotEmpty) {
                                            _joinRoom(code);
                                          }
                                        },
                                  icon: const Icon(Icons.login),
                                  label: const Text('Beitreten'),
                                  style: ElevatedButton.styleFrom(
                                      minimumSize: const Size(200, 48)),
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 12),
                                  Text(_error!,
                                      style: const TextStyle(
                                          color: Colors.red)),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      // ── Status indicator (fixed at bottom) ──
      bottomNavigationBar: _StatusBanner(
        key: const Key('status_banner'),
        step: _step,
        icon: _stepIcon(_step),
        label: _stepLabel(_step),
        subtitle: _stepSubtitle(_step),
        color: _stepColor(_step, colors),
        onRetry: _step == _JoinStep.error ? _retry : null,
      ),
    );
  }

  Widget _landscapeCodeForm(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Oder Code eingeben:',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 18),
            TextField(
              controller: _codeController,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 24, letterSpacing: 4),
              decoration: InputDecoration(
                hintText: 'snail-XXXX',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: _step == _JoinStep.joining
                  ? null
                  : () {
                      final code = _codeController.text.trim();
                      if (code.isNotEmpty) _joinRoom(code);
                    },
              icon: const Icon(Icons.login),
              label: const Text('Beitreten'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(240, 52)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact status banner showing the current scan/join step.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    super.key,
    required this.step,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    this.onRetry,
  });

  final _JoinStep step;
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 56,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: color.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: color,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Erneut'),
              style: TextButton.styleFrom(foregroundColor: color),
            ),
        ],
      ),
    );
  }
}
