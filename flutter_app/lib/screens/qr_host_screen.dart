import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/session_service.dart';
import '../models/snail_contact.dart';

class QrHostScreen extends StatefulWidget {
  const QrHostScreen({super.key});

  @override
  State<QrHostScreen> createState() => _QrHostScreenState();
}

class _QrHostScreenState extends State<QrHostScreen> {
  bool _isCreating = true;
  String? _error;
  SnailContact? _contact;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is SnailContact && mounted) setState(() => _contact = args);
    });
    _createAndGo();
  }

  Future<void> _createAndGo() async {
    final session = await context
        .read<SessionService>()
        .createRoom(inviteeId: _contact?.userId);
    if (!mounted) return;

    if (session != null) {
      // Navigate directly to session screen — host connects via WebSocket
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
    return Scaffold(
      appBar: AppBar(title: const Text('Session starten')),
      body: Center(
        child: _isCreating
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(_contact == null
                      ? 'Session wird erstellt...'
                      : 'Session für ${_contact!.username} wird erstellt...'),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _isCreating = true;
                        _error = null;
                      });
                      _createAndGo();
                    },
                    child: const Text('Erneut versuchen'),
                  ),
                ],
              ),
      ),
    );
  }
}
