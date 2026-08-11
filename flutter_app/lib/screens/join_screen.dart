import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/session_service.dart';
import '../services/contact_service.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _codeController = TextEditingController();
  bool _isScanning = true;
  bool _isJoining = false;
  String? _error;

  Future<void> _joinRoom(String roomId) async {
    setState(() {
      _isJoining = true;
      _error = null;
    });
    final session = await context.read<SessionService>().joinRoom(roomId);
    if (mounted && session != null) {
      Navigator.pushReplacementNamed(context, '/session');
    } else if (mounted) {
      setState(() {
        _isJoining = false;
        _error =
            context.read<SessionService>().error ?? 'Beitritt fehlgeschlagen';
      });
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (!_isScanning) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null) {
        if (value.startsWith('snail://user/')) {
          setState(() => _isScanning = false);
          _saveContactQr(value);
          return;
        }
        final roomId = _roomIdFromQr(value);
        if (roomId != null) {
          setState(() => _isScanning = false);
          _joinRoom(roomId);
          return;
        }
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
        _isScanning = true;
        _error = 'Ungültige Snail-Identität';
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final availableHeight = MediaQuery.sizeOf(context).height;
    if (landscape && !_isJoining) {
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
      body: _isJoining
          ? const Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Trete Session bei...')
                ]))
          : LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isScanning)
                    SizedBox(
                      height: landscape ? 230 : availableHeight * .48,
                      child: Stack(
                        children: [
                          MobileScanner(onDetect: _onDetect),
                          Center(
                            child: Container(
                              width: 250,
                              height: 250,
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    width: 2),
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(
                    height: landscape ? 360 : availableHeight * .52,
                    child: Padding(
                      padding: EdgeInsets.all(landscape ? 12 : 24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Oder Code eingeben:',
                              style: Theme.of(context).textTheme.titleMedium),
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
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () {
                              final code = _codeController.text.trim();
                              if (code.isNotEmpty) _joinRoom(code);
                            },
                            icon: const Icon(Icons.login),
                            label: const Text('Beitreten'),
                            style: ElevatedButton.styleFrom(
                                minimumSize: const Size(200, 48)),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(_error!,
                                style: const TextStyle(color: Colors.red)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              )),
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
              onPressed: _isJoining
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
