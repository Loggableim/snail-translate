import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/session_service.dart';
import '../services/snail_audio.dart';
import '../models/snail_contact.dart';

class QrHostScreen extends StatefulWidget {
  const QrHostScreen({super.key});

  @override
  State<QrHostScreen> createState() => _QrHostScreenState();
}

class _QrHostScreenState extends State<QrHostScreen> {
  bool _isCreating = false;
  String? _error;
  SnailContact? _contact;
  bool _headsetChecked = false;
  bool _hasHeadset = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is SnailContact && mounted) setState(() => _contact = args);
    });
    _checkHeadset();
  }

  Future<void> _checkHeadset() async {
    try {
      final audio = SnailAudio();
      final hasHeadset = await audio.isHeadsetConnected();
      if (!mounted) return;
      setState(() {
        _headsetChecked = true;
        _hasHeadset = hasHeadset;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _headsetChecked = true);
    }
  }

  Future<void> _createAndGo() async {
    setState(() {
      _isCreating = true;
      _error = null;
    });
    final session = await context
        .read<SessionService>()
        .createRoom(inviteeId: _contact?.userId);
    if (!mounted) return;

    if (session != null) {
      Navigator.pushReplacementNamed(context, '/session');
    } else {
      setState(() {
        _isCreating = false;
        _error =
            context.read<SessionService>().error ?? 'Fehler beim Erstellen';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Session starten')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _isCreating
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Session wird erstellt...'),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_error != null) ...[
                      const Icon(Icons.error_outline,
                          size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_error!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                    ],
                    // ── Headset warning ──
                    if (_headsetChecked && !_hasHeadset) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.headphones_rounded,
                              size: 20,
                              color: colors.onSurface
                                  .withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Kein Headset erkannt. '
                                'Für beste Audioqualität und Echo-Unterdrückung '
                                'empfehlen wir ein Headset.',
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
                      const SizedBox(height: 20),
                    ],
                    // ── Start button ──
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _headsetChecked ? _createAndGo : null,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          _headsetChecked
                              ? (_contact != null
                                  ? 'Session mit ${_contact!.username} starten'
                                  : 'Session starten')
                              : 'Audio wird geprüft …',
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
                    if (_headsetChecked && _hasHeadset) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded,
                              size: 16, color: Colors.green),
                          const SizedBox(width: 6),
                          Text(
                            'Headset erkannt',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurface
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
