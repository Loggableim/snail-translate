import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/error_logger.dart';

class ErrorLogScreen extends StatefulWidget {
  const ErrorLogScreen({super.key});
  @override
  State<ErrorLogScreen> createState() => _ErrorLogScreenState();
}

class _ErrorLogScreenState extends State<ErrorLogScreen> {
  bool _detailsVisible = true;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fehlerprotokoll'),
        actions: [
          Consumer<ErrorLogger>(
            builder: (_, logger, __) => IconButton(
              tooltip: 'Logs kopieren',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: logger.getLogs().isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(
                          ClipboardData(text: logger.exportLogs()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Fehlerprotokoll kopiert')));
                      }
                    },
            ),
          ),
          IconButton(
            tooltip:
                _detailsVisible ? 'Details ausblenden' : 'Details einblenden',
            icon: Icon(_detailsVisible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
            onPressed: () => setState(() => _detailsVisible = !_detailsVisible),
          ),
          Consumer<ErrorLogger>(
            builder: (_, logger, __) => PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'clear') {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Protokoll löschen?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Abbrechen')),
                        TextButton(
                          onPressed: () {
                            logger.clearLogs();
                            Navigator.pop(ctx);
                          },
                          child: const Text('Löschen',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'clear', child: Text('Alle löschen')),
              ],
            ),
          ),
        ],
      ),
      body: Consumer<ErrorLogger>(
        builder: (_, logger, __) {
          final logs = logger.getLogs();
          if (logs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, size: 64, color: Colors.green),
                  SizedBox(height: 16),
                  Text('Keine Fehler — alles sauber!',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: logs.length + 1,
            itemBuilder: (_, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.copy_all_rounded),
                    label: const Text('Fehlerlogs kopieren'),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: logger.exportLogs()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Fehlerlogs in Zwischenablage kopiert')),
                        );
                      }
                    },
                  ),
                );
              }
              final entry = logs[index - 1];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ExpansionTile(
                  leading: _providerBadge(entry.provider),
                  title: Text(entry.message,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${entry.provider}/${entry.context} — ${_formatTime(entry.timestamp)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  children: [
                    if (_detailsVisible && entry.stackTrace.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: SelectableText(
                            entry.stackTrace,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 10),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _providerBadge(String provider) {
    final colors = {
      'groq': Colors.orange,
      'deepgram': Colors.purple,
      'openai': Colors.green,
      'fishaudio': Colors.blue,
      'websocket': Colors.teal,
      'audio': Colors.red,
      'api': Colors.indigo,
    };
    final color = colors[provider] ?? Colors.grey;
    return CircleAvatar(
      radius: 14,
      backgroundColor: color.withAlpha(40),
      child: Text(provider[0].toUpperCase(),
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
