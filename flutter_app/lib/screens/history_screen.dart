import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/transcript_history.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verlauf'),
        actions: [
          Consumer<TranscriptHistory>(
            builder: (_, history, __) => history.entries.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.delete_sweep),
                    tooltip: 'Alle löschen',
                    onPressed: () => _confirmClearAll(context, history),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Consumer<TranscriptHistory>(
        builder: (_, history, __) {
          if (history.entries.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Keine Transkripte',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: history.entries.length,
            itemBuilder: (_, index) {
              final entry = history.entries[index];
              return Dismissible(
                key: Key(entry.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (_) => _confirmDelete(context),
                onDismissed: (_) => history.deleteEntry(entry.id),
                child: Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.originalText,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          entry.translatedText,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _langChip(entry.sourceLang),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_forward,
                                size: 14, color: Colors.grey),
                            const SizedBox(width: 4),
                            _langChip(entry.targetLang),
                            const SizedBox(width: 6),
                            _providerChip(entry.provider),
                            const Spacer(),
                            Text(
                              _formatTime(entry.timestamp),
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _langChip(String lang) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(lang.toUpperCase(),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  Widget _providerChip(String provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(provider,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}.${dt.month}. ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _confirmClearAll(BuildContext context, TranscriptHistory history) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle löschen?'),
        content: const Text('Möchtest du wirklich alle Transkripte löschen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () {
              history.clearHistory();
              Navigator.pop(ctx);
            },
            child: const Text('Löschen', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Löschen?'),
        content: const Text('Diesen Eintrag löschen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
