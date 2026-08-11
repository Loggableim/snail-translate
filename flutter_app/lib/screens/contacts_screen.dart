import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../services/contact_service.dart';
import '../services/user_identity_service.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  bool _scanning = false;

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

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactService>();
    final identity = context.watch<UserIdentityService>();
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
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(Icons.qr_code_rounded,
                  color: Theme.of(context).colorScheme.primary),
            ),
            title: const Text('Mein QR-Code',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(identity.username),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/my-qr'),
          ),
        ),
        if (_scanning)
          SizedBox(
              height: 260,
              child: Stack(children: [
                MobileScanner(onDetect: (capture) async {
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value == null) continue;
                    final ok = await contacts.addFromQr(value);
                    if (ok && mounted) setState(() => _scanning = false);
                    if (ok) break;
                  }
                }),
                Center(
                    child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(16)))),
              ])),
        if (!_scanning)
          Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                  onPressed: () => setState(() => _scanning = true),
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
