import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.commonSettings), actions: [
        IconButton(
            icon: const Icon(Icons.key),
            tooltip: l10n.settingsByokProviderTooltip,
            onPressed: () => Navigator.pushNamed(context, '/provider-settings'))
      ]),
      body: ListView(
        children: [
          // ── Meine Sprache ──
          _sectionHeader(l10n.settingsMyLanguageSection),
          Consumer<SessionService>(
            builder: (_, session, __) {
              final current = session.myLanguage;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonFormField<String>(
                  value: current,
                  decoration: InputDecoration(
                    labelText: l10n.settingsISpeak,
                    border: const OutlineInputBorder(),
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
                decoration: InputDecoration(
                    labelText: l10n.settingsTranslateInto,
                    border: const OutlineInputBorder()),
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

          _sectionHeader(l10n.settingsSupportedLanguagesSection),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.settingsSupportedLanguagesBody,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 10),
          const _LanguageChips(),
          const SizedBox(height: 16),

          _sectionHeader(l10n.settingsAudioSection),
          Consumer<AudioPolicy>(
            builder: (_, policy, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<AudioPolicyProfile>(
                value: policy.profile,
                decoration: InputDecoration(
                  labelText: l10n.settingsAudioEchoProfile,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: AudioPolicyProfile.auto,
                    child: Text(l10n.settingsProfileAuto),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.headset,
                    child: Text(l10n.audioRouteHeadset),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.speakerEcho,
                    child: Text(l10n.settingsProfileSpeakerEcho),
                  ),
                  DropdownMenuItem(
                    value: AudioPolicyProfile.longerSpeech,
                    child: Text(l10n.settingsProfileLongerSentences),
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
            title: Text(l10n.settingsTestSpeaker),
            subtitle: Text(l10n.settingsTestSpeakerHint),
            onTap: () async {
              final ok = await SnailAudio().playTestTone();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok
                      ? l10n.settingsTestToneOutputting
                      : l10n.sessionTestToneFailed),
                ));
              }
            },
          ),

          // ── API-Keys ──
          _sectionHeader(l10n.settingsMyIdentitySection),
          Consumer<UserIdentityService>(
            builder: (_, identity, __) => ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: Text(identity.identity?.username ?? l10n.settingsSnailUserFallback),
              subtitle: Text(
                  identity.identity?.userId ?? l10n.settingsBeingSetUp),
              trailing: identity.identity == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: l10n.settingsChangeUsernameTooltip,
                      onPressed: () => _editUsername(context, identity),
                    ),
              onTap: identity.identity == null
                  ? null
                  : () => Navigator.pushNamed(context, '/my-qr'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(l10n.settingsProfileAndUsage),
            subtitle: Text(l10n.settingsProfileAndUsageSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/profile'),
          ),
          _sectionHeader(l10n.settingsByokSection),
          ListTile(
            leading: const Icon(Icons.key),
            title: Text(l10n.settingsOwnProvider),
            subtitle: Text(l10n.settingsOwnProviderSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/provider-settings'),
          ),
          const SizedBox(height: 16),

          // ── Fehlerprotokoll ──
          _sectionHeader(l10n.errorLogTitle),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: Text(l10n.settingsShowErrorLog),
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
                    ? l10n.settingsClearLogWithCount(count)
                    : l10n.settingsClearLog),
                enabled: count > 0,
                onTap: count > 0
                    ? () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(l10n.errorLogClearConfirmTitle),
                            content: Text(
                                l10n.settingsClearLogConfirmBody(count)),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: Text(l10n.commonCancel)),
                              TextButton(
                                onPressed: () {
                                  logger.clearLogs();
                                  Navigator.pop(ctx);
                                },
                                child: Text(l10n.commonDelete,
                                    style: const TextStyle(color: Colors.red)),
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
          _sectionHeader(l10n.settingsAppSection),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Snail v0.2.0'),
            subtitle: Text(l10n.settingsAppSubtitle),
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
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: identity.identity!.username);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsChangeUsernameTitle),
        content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.settingsUsernameLabel)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.commonCancel)),
          FilledButton(
              onPressed: () {
                identity.setUsername(controller.text);
                Navigator.pop(dialogContext);
              },
              child: Text(l10n.commonSave)),
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
