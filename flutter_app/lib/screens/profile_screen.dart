import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/session_service.dart';
import '../models/session.dart';
import '../services/user_identity_service.dart';
import '../services/transcript_history.dart';

/// Profile screen — user info, stats, logout.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Quota? _quota;

  @override
  void initState() {
    super.initState();
    _loadQuota();
  }

  Future<void> _loadQuota() async {
    final quota = await context.read<SessionService>().getQuota();
    if (mounted) setState(() => _quota = quota);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Local identity (stable QR identity, editable display name).
          Consumer<UserIdentityService>(
            builder: (context, identity, _) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        child: Text(
                            identity.username.substring(0, 1).toUpperCase(),
                            style: const TextStyle(fontSize: 24)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              identity.username,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'QR-ID: ${identity.shortId}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Tier
          Card(
            child: ListTile(
              leading: Icon(
                _quota?.tier == 'paid' ? Icons.workspace_premium : Icons.person,
                color: _quota?.tier == 'paid' ? Colors.amber : null,
              ),
              title: Text(_quota?.tier == 'paid' ? 'Pro' : 'Free'),
              subtitle: Text(_quota?.formattedRemaining ?? 'Lädt...'),
              trailing: _quota?.tier != 'paid'
                  ? TextButton(
                      onPressed: () => Navigator.pushNamed(context, '/paywall'),
                      child: const Text('Upgrade'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),

          // Stats
          Consumer<TranscriptHistory>(
            builder: (_, history, __) {
              final sessionCount = history.entries
                  .map((entry) => entry.sessionId)
                  .toSet()
                  .length;
              return Card(
                child: Column(
                  children: [
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: const Text('Genutzte Zeit'),
                  subtitle: Text(_quota?.formattedUsed ?? '0m 0s'),
                ),
                const Divider(height: 1),
                    ListTile(
                  leading: const Icon(Icons.translate),
                  title: const Text('Übersetzte Sessions'),
                      subtitle: Text('$sessionCount'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 32),

          // Logout
          OutlinedButton.icon(
            onPressed: () async {
              if (mounted) {
                Navigator.popUntil(context, (route) => route.isFirst);
              }
            },
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text('Abmelden'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      ),
    );
  }
}
