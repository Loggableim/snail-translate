import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/session_service.dart';
import '../models/session.dart';
import '../models/provider_config.dart';
import '../services/user_identity_service.dart';
import '../services/contact_service.dart';
import '../services/transcript_history.dart';
import '../services/provider_config_service.dart';

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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
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
                              l10n.profileQrId(identity.shortId),
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
              title: Text(
                  _quota?.tier == 'paid' ? l10n.profileTierPro : l10n.profileTierFree),
              subtitle: Text('${_quota?.formattedRemainingLocalized(l10n) ?? l10n.commonLoading} · '
                  '${context.watch<ProviderConfigService>().config.provider.displayName}'),
              trailing: _quota?.tier != 'paid'
                  ? TextButton(
                      onPressed: () => Navigator.pushNamed(context, '/paywall'),
                      child: Text(l10n.profileUpgrade),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),

          Consumer<ProviderConfigService>(
            builder: (_, service, __) => Card(
              child: ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: Text(l10n.profileActiveProvider),
                subtitle: Text(service.config.provider.displayName),
              ),
            ),
          ),

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
                      title: Text(l10n.profileTimeUsed),
                      subtitle: Text(_quota?.formattedUsed ?? '0m 0s'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.translate),
                      title: Text(l10n.profileTranslatedSessions),
                      subtitle: Text('$sessionCount'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 32),

          // Reset data (the closest thing to "logout" in a BYOK app with no
          // server account): wipes identity, contacts, history and the
          // provider key after an explicit confirmation.
          OutlinedButton.icon(
            onPressed: () => _confirmResetData(context),
            icon: const Icon(Icons.logout, color: Colors.red),
            label: Text(l10n.profileLogout),
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

  Future<void> _confirmResetData(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.profileLogoutConfirmTitle),
        content: Text(l10n.profileLogoutConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.profileLogoutAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final identity = context.read<UserIdentityService>();
    final contacts = context.read<ContactService>();
    final history = context.read<TranscriptHistory>();
    final providerConfig = context.read<ProviderConfigService>();
    await identity.resetIdentity();
    await contacts.clearAll();
    await history.clearHistory();
    // Re-create the provider default config (wipes the stored BYOK key).
    await providerConfig.save(const ProviderConfig(
      provider: TranslationProvider.fishAudio,
      endpoint: 'wss://api.fish.audio/v1/tts/live',
      model: 's2-pro',
    ));
    if (!context.mounted) return;
    Navigator.popUntil(context, (route) => route.isFirst);
  }
}
