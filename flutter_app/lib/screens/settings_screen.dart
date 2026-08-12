import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/error_logger.dart';
import '../services/session_service.dart';
import '../services/user_identity_service.dart';
import '../services/snail_audio.dart';
import '../services/audio_policy.dart';
import 'error_log_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen'), actions: [
        IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'BYOK-Provider',
            onPressed: () => Navigator.pushNamed(context, '/provider-settings'))
      ]),
      body: ListView(
        children: [
          // ── Meine Sprache ──
          _sectionHeader('Meine Sprache'),
          Consumer<SessionService>(
            builder: (_, session, __) {
              final current = session.myLanguage;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonFormField<String>(
                  value: current,
                  decoration: const InputDecoration(
                    labelText: 'Ich spreche',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'fr', child: Text('Français')),
                    DropdownMenuItem(value: 'es', child: Text('Español')),
                    DropdownMenuItem(value: 'it', child: Text('Italiano')),
                    DropdownMenuItem(value: 'ja', child: Text('日本語')),
                    DropdownMenuItem(value: 'ko', child: Text('한국어')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'uk', child: Text('Українська')),
                  ],
                  onChanged: (lang) {
                    if (lang != null) session.setMyLanguage(lang);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Consumer<SessionService>(
            builder: (_, session, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                value: session.targetLanguage,
                decoration: const InputDecoration(
                    labelText: 'Übersetzen in', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'fr', child: Text('Français')),
                  DropdownMenuItem(value: 'es', child: Text('Español')),
                  DropdownMenuItem(value: 'it', child: Text('Italiano')),
                  DropdownMenuItem(value: 'ja', child: Text('日本語')),
                  DropdownMenuItem(value: 'ko', child: Text('한국어')),
                  DropdownMenuItem(value: 'zh', child: Text('中文')),
                  DropdownMenuItem(value: 'uk', child: Text('Українська')),
                ],
                onChanged: (lang) {
                  if (lang != null) session.setTargetLanguage(lang);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),

          _sectionHeader('Unterstützte Sprachen'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Snail übersetzt live zwischen diesen Sprachen. '
              'Weitere Sprachen folgen mit kommenden Updates.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 10),
          const _LanguageChips(),
          const SizedBox(height: 16),

          _sectionHeader('Audio'),
          Consumer<AudioPolicy>(
            builder: (_, policy, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<AudioPolicyProfile>(
                value: policy.profile,
                decoration: const InputDecoration(
                  labelText: 'Audio- und Echo-Profil',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: AudioPolicyProfile.auto,
                    child: Text('Automatisch'),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.headset,
                    child: Text('Headset'),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.speakerEcho,
                    child: Text('Lautsprecher / Echo'),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.longerSpeech,
                    child: Text('Längere Sätze'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) policy.setProfile(value);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.volume_up_rounded),
            title: const Text('Lautsprecher testen'),
            subtitle: const Text('Spielt lokal einen kurzen Testton ab. Keine Aufnahme und kein API-Aufruf.'),
            onTap: () async {
              final ok = await SnailAudio().playTestTone();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok ? 'Testton wird über den Lautsprecher ausgegeben' : 'Testton konnte nicht gestartet werden'),
                ));
              }
            },
          ),

          // ── API-Keys ──
          _sectionHeader('Meine Identität'),
          Consumer<UserIdentityService>(
            builder: (_, identity, __) => ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: Text(identity.identity?.username ?? 'Snail User'),
              subtitle: Text(identity.identity?.userId ?? 'wird eingerichtet'),
              trailing: identity.identity == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Username ändern',
                      onPressed: () => _editUsername(context, identity),
                    ),
              onTap: identity.identity == null
                  ? null
                  : () => Navigator.pushNamed(context, '/my-qr'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Profil und Nutzung'),
            subtitle: const Text('Identität, Kontingent und Sitzungsverlauf'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/profile'),
          ),
          _sectionHeader('BYOK-Übersetzung'),
          ListTile(
            leading: Icon(Icons.key),
            title: Text('Eigener Provider'),
            subtitle: Text(
                'Ollama lokal/private URL oder günstiges OpenAI-Modell. Schlüssel werden zur Laufzeit konfiguriert.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/provider-settings'),
          ),
          const SizedBox(height: 16),

          // ── Fehlerprotokoll ──
          _sectionHeader('Fehlerprotokoll'),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('Fehlerprotokoll anzeigen'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ErrorLogScreen())),
          ),
          Consumer<ErrorLogger>(
            builder: (_, logger, __) {
              final count = logger.getLogs().length;
              return ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(count > 0
                    ? 'Protokoll löschen ($count Einträge)'
                    : 'Protokoll löschen'),
                enabled: count > 0,
                onTap: count > 0
                    ? () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Protokoll löschen?'),
                            content:
                                Text('$count Einträge unwiderruflich löschen?'),
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
                    : null,
              );
            },
          ),
          const SizedBox(height: 32),

          // ── App-Info ──
          _sectionHeader('App'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Snail v0.2.0'),
            subtitle: Text('Echtzeit-Konversationsübersetzer'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Future<void> _editUsername(
      BuildContext context, UserIdentityService identity) async {
    final controller = TextEditingController(text: identity.identity!.username);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Username ändern'),
        content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Username')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () {
                identity.setUsername(controller.text);
                Navigator.pop(dialogContext);
              },
              child: const Text('Speichern')),
        ],
      ),
    );
    controller.dispose();
  }
}

class _LanguageChips extends StatelessWidget {
  const _LanguageChips();

  static const _languages = <({String code, String name, String native})>[
    (code: 'de', name: 'Deutsch', native: 'Deutsch'),
    (code: 'en', name: 'English', native: 'English'),
    (code: 'fr', name: 'Français', native: 'Français'),
    (code: 'es', name: 'Español', native: 'Español'),
    (code: 'it', name: 'Italiano', native: 'Italiano'),
    (code: 'ja', name: 'Japanese', native: '日本語'),
    (code: 'ko', name: 'Korean', native: '한국어'),
    (code: 'zh', name: 'Chinese', native: '中文'),
    (code: 'uk', name: 'Ukrainian', native: 'Українська'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _languages.map((lang) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  lang.native,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  lang.code.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurface.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
