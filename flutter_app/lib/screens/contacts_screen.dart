import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../services/contact_service.dart';
import '../services/user_identity_service.dart';

/// Status steps for the contact QR scan flow.
enum _ContactScanStep {
  idle,      // Scanner not active
  starting,  // Camera initialising
  scanning,  // Looking for a QR code
  detected,  // QR code found, processing
  error,     // Something went wrong
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  _ContactScanStep _scanStep = _ContactScanStep.idle;

  void _startScanning() {
    setState(() => _scanStep = _ContactScanStep.starting);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scanStep == _ContactScanStep.starting) {
        setState(() => _scanStep = _ContactScanStep.scanning);
      }
    });
  }

  void _stopScanning() {
    setState(() => _scanStep = _ContactScanStep.idle);
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Snail-ID hinzufügen'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'snail://user/...')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Hinzufügen')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || payload == null) return;
    final ok = await context.read<ContactService>().addFromQr(payload);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ungültige Snail-ID')));
    }
  }

  // ── Status helpers ──

  IconData _scanIcon(_ContactScanStep step) => switch (step) {
        _ContactScanStep.idle => Icons.qr_code_scanner,
        _ContactScanStep.starting => Icons.camera_alt_outlined,
        _ContactScanStep.scanning => Icons.qr_code_scanner_rounded,
        _ContactScanStep.detected => Icons.check_circle_outline_rounded,
        _ContactScanStep.error => Icons.error_outline_rounded,
      };

  String _scanLabel(_ContactScanStep step) => switch (step) {
        _ContactScanStep.idle => 'QR-ID scannen',
        _ContactScanStep.starting => 'Kamera wird gestartet …',
        _ContactScanStep.scanning => 'QR-Code suchen …',
        _ContactScanStep.detected => 'Kontakt wird hinzugefügt …',
        _ContactScanStep.error => 'Fehler beim Scannen',
      };

  String? _scanSubtitle(_ContactScanStep step) => switch (step) {
        _ContactScanStep.idle => null,
        _ContactScanStep.starting => 'Bitte warten',
        _ContactScanStep.scanning =>
          'Richte die Kamera auf den Snail-QR-Code des Kontakts',
        _ContactScanStep.detected => 'QR-Code erkannt',
        _ContactScanStep.error => 'Keine gültige Snail-ID erkannt',
      };

  Color _scanColor(_ContactScanStep step, ColorScheme colors) => switch (step) {
        _ContactScanStep.idle => colors.primary,
        _ContactScanStep.starting ||
        _ContactScanStep.scanning =>
          colors.primary,
        _ContactScanStep.detected => Colors.orange,
        _ContactScanStep.error => colors.error,
      };

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactService>();
    final identity = context.watch<UserIdentityService>();
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Kontakte'), actions: [
        IconButton(
            onPressed: _addManually,
            icon: const Icon(Icons.person_add),
            tooltip: 'ID eingeben'),
      ]),
      body: Column(children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: colors.primaryContainer,
              child: Icon(Icons.qr_code_rounded, color: colors.primary),
            ),
            title: const Text('Mein QR-Code',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(identity.username),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/my-qr'),
          ),
        ),
        // ── Status banner (only when scanning) ──
        if (_scanStep != _ContactScanStep.idle)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: _scanColor(_scanStep, colors).withValues(alpha: 0.08),
              border: Border(
                bottom: BorderSide(
                  color: _scanColor(_scanStep, colors).withValues(alpha: 0.15),
                ),
              ),
            ),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Icon(
                    _scanIcon(_scanStep),
                    key: ValueKey(_scanStep),
                    size: 22,
                    color: _scanColor(_scanStep, colors),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _scanLabel(_scanStep),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: _scanColor(_scanStep, colors),
                        ),
                      ),
                      if (_scanSubtitle(_scanStep) != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _scanSubtitle(_scanStep)!,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_scanStep == _ContactScanStep.error)
                  TextButton.icon(
                    onPressed: _startScanning,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Erneut'),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.error,
                    ),
                  ),
                if (_scanStep == _ContactScanStep.scanning)
                  IconButton(
                    onPressed: _stopScanning,
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Scanner schließen',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 36, minHeight: 36),
                  ),
              ],
            ),
          ),
        if (_scanStep != _ContactScanStep.idle)
          SizedBox(
              height: 260,
              child: Stack(children: [
                if (_scanStep == _ContactScanStep.scanning)
                  MobileScanner(onDetect: (capture) async {
                    for (final barcode in capture.barcodes) {
                      final value = barcode.rawValue;
                      if (value == null) continue;
                      setState(
                          () => _scanStep = _ContactScanStep.detected);
                      final ok = await contacts.addFromQr(value);
                      if (ok && mounted) {
                        setState(() => _scanStep = _ContactScanStep.idle);
                      } else if (mounted) {
                        setState(
                            () => _scanStep = _ContactScanStep.error);
                      }
                      if (ok) break;
                    }
                  }),
                Center(
                    child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _scanStep == _ContactScanStep.scanning
                          ? colors.primary
                          : colors.outline.withValues(alpha: 0.3),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                )),
              ])),
        if (_scanStep == _ContactScanStep.idle)
          Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                  onPressed: _startScanning,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('QR-ID scannen'))),
        Expanded(
            child: contacts.contacts.isEmpty
                ? const Center(child: Text('Noch keine Kontakte'))
                : ListView.builder(
                    itemCount: contacts.contacts.length,
                    itemBuilder: (_, index) {
                      final contact = contacts.contacts[index];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(contact.username),
                        subtitle: Text(contact.userId),
                        onTap: () => Navigator.pushNamed(context, '/qr-host',
                            arguments: contact),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'start') {
                              Navigator.pushNamed(context, '/qr-host',
                                  arguments: contact);
                            }
                            if (value == 'delete') contacts.remove(contact);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'start', child: Text('Session starten')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Löschen')),
                          ],
                        ),
                      );
                    })),
      ]),
    );
  }
}
