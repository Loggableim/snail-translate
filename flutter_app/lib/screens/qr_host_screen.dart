import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/session_service.dart';
import '../services/snail_audio.dart';
import '../models/snail_contact.dart';

/// Status of the connection test.
enum _ConnTestState { idle, testing, success, failed }

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
  _ConnTestState _connTest = _ConnTestState.idle;
  String? _connError;

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

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _connTest = _ConnTestState.testing;
      _connError = null;
    });
    try {
      final quota = await context.read<SessionService>().getQuota();
      if (!mounted) return;
      setState(() {
        _connTest = quota != null
            ? _ConnTestState.success
            : _ConnTestState.failed;
        if (quota == null) _connError = l10n.qrHostNoServerResponse;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connTest = _ConnTestState.failed;
        _connError = l10n.qrHostConnectionError(e.toString());
      });
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
        _error = context.read<SessionService>().error ??
            AppLocalizations.of(context).qrHostCreateFailed;
      });
    }
  }

  // ── Connection test helpers ──

  IconData _connIcon(_ConnTestState state) => switch (state) {
        _ConnTestState.idle => Icons.wifi_find_rounded,
        _ConnTestState.testing => Icons.sync_rounded,
        _ConnTestState.success => Icons.check_circle_rounded,
        _ConnTestState.failed => Icons.error_outline_rounded,
      };

  Color _connColor(_ConnTestState state, ColorScheme colors) => switch (state) {
        _ConnTestState.idle => colors.primary,
        _ConnTestState.testing => Colors.orange,
        _ConnTestState.success => Colors.green,
        _ConnTestState.failed => colors.error,
      };

  String _connLabel(_ConnTestState state, AppLocalizations l10n) =>
      switch (state) {
        _ConnTestState.idle => l10n.qrHostTestConnection,
        _ConnTestState.testing => l10n.qrHostTestingConnection,
        _ConnTestState.success => l10n.qrHostServerReachable,
        _ConnTestState.failed => l10n.qrHostConnectionFailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeStartSession)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _isCreating
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(l10n.qrHostCreatingSession),
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
                                l10n.qrHostNoHeadsetWarning,
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
                    // ── Connection test ──
                    if (_headsetChecked) ...[
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _connTest == _ConnTestState.testing
                              ? null
                              : _testConnection,
                          icon: _connTest == _ConnTestState.testing
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _connColor(_connTest, colors),
                                  ),
                                )
                              : Icon(
                                  _connIcon(_connTest),
                                  size: 20,
                                  color: _connColor(_connTest, colors),
                                ),
                          label: Text(
                            _connLabel(_connTest, l10n),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _connColor(_connTest, colors),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _connColor(_connTest, colors),
                            side: BorderSide(
                              color: _connColor(_connTest, colors)
                                  .withValues(alpha: 0.4),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      if (_connTest == _ConnTestState.failed &&
                          _connError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _connError!,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.error.withValues(alpha: 0.8),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 16),
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
                                  ? l10n.qrHostStartSessionWith(
                                      _contact!.username)
                                  : l10n.homeStartSession)
                              : l10n.qrHostCheckingAudio,
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
                          const Icon(Icons.check_circle_rounded,
                              size: 16, color: Colors.green),
                          const SizedBox(width: 6),
                          Text(
                            l10n.qrHostHeadsetDetected,
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
