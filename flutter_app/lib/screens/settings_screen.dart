import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/error_logger.dart';
import '../services/session_service.dart';
import '../services/user_identity_service.dart';
import '../services/snail_audio.dart';
import '../services/audio_policy.dart';
import 'error_log_screen.dart';

/// The languages Snail translates between, in the order the chip row shows
/// them. One list feeds both dropdowns and the chips, which used to carry
/// three copies of it.
const _languages = <({String code, String native})>[
  (code: 'de', native: 'Deutsch'),
  (code: 'en', native: 'English'),
  (code: 'fr', native: 'Français'),
  (code: 'es', native: 'Español'),
  (code: 'it', native: 'Italiano'),
  (code: 'ja', native: '日本語'),
  (code: 'ko', native: '한국어'),
  (code: 'zh', native: '中文'),
  (code: 'uk', native: 'Українська'),
];

/// SessionService accepts more codes than the list above documents (a Russian
/// or Turkish phone resolves to one of them on first start), so a value can
/// legitimately arrive that has no chip. Fall back to the bare code instead of
/// leaving the dropdown without a matching item.
String _languageLabel(String code) {
  for (final language in _languages) {
    if (language.code == code) return language.native;
  }
  return code.toUpperCase();
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Settings as a list of collapsed groups. Each group carries a summary of
/// what it currently holds, so the whole screen can be read at a glance and
/// only the section actually being changed needs to be open.
class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.commonSettings), actions: [
        IconButton(
            icon: const Icon(Icons.key),
            tooltip: l10n.settingsByokProviderTooltip,
            onPressed: () => Navigator.pushNamed(context, '/provider-settings'))
      ]),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _languageGroup(l10n, colors),
            const SizedBox(height: 10),
            _supportedLanguagesGroup(l10n, colors),
            const SizedBox(height: 10),
            _audioGroup(l10n, colors),
            const SizedBox(height: 10),
            _identityGroup(l10n, colors),
            const SizedBox(height: 10),
            _SettingsRow(
              icon: Icons.key_rounded,
              color: colors.tertiary,
              title: l10n.settingsOwnProvider,
              subtitle: l10n.settingsOwnProviderSubtitle,
              onTap: () => Navigator.pushNamed(context, '/provider-settings'),
            ),
            const SizedBox(height: 10),
            _errorLogGroup(l10n, colors),
            const SizedBox(height: 10),
            _SettingsRow(
              icon: Icons.info_outline_rounded,
              color: colors.secondary,
              title: 'Snail v0.2.0',
              subtitle: l10n.settingsAppSubtitle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _languageGroup(AppLocalizations l10n, ColorScheme colors) {
    return Consumer<SessionService>(
      builder: (_, session, __) => _SettingsGroup(
        icon: Icons.translate_rounded,
        color: colors.primary,
        title: l10n.settingsMyLanguageSection,
        summary: '${_languageLabel(session.myLanguage)} '
            '→ ${_languageLabel(session.targetLanguage)}',
        children: [
          _LanguageDropdown(
            label: l10n.settingsISpeak,
            value: session.myLanguage,
            onChanged: session.setMyLanguage,
          ),
          const SizedBox(height: 12),
          _LanguageDropdown(
            label: l10n.settingsTranslateInto,
            value: session.targetLanguage,
            onChanged: session.setTargetLanguage,
          ),
        ],
      ),
    );
  }

  Widget _supportedLanguagesGroup(AppLocalizations l10n, ColorScheme colors) {
    return _SettingsGroup(
      icon: Icons.language_rounded,
      color: colors.secondary,
      title: l10n.settingsSupportedLanguagesSection,
      summary: _languages.map((l) => l.code.toUpperCase()).join(' · '),
      children: [
        Text(
          l10n.settingsSupportedLanguagesBody,
          style: TextStyle(
              fontSize: 13, color: colors.onSurface.withValues(alpha: .7)),
        ),
        const SizedBox(height: 12),
        const _LanguageChips(),
      ],
    );
  }

  Widget _audioGroup(AppLocalizations l10n, ColorScheme colors) {
    return Consumer<AudioPolicy>(
      builder: (_, policy, __) => _SettingsGroup(
        icon: Icons.graphic_eq_rounded,
        color: colors.tertiary,
        title: l10n.settingsAudioSection,
        summary: _profileLabel(l10n, policy.profile),
        children: [
          DropdownButtonFormField<AudioPolicyProfile>(
            value: policy.profile,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.settingsAudioEchoProfile,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final profile in AudioPolicyProfile.values)
                DropdownMenuItem(
                  value: profile,
                  child: Text(_profileLabel(l10n, profile)),
                ),
            ],
            onChanged: (value) {
              if (value != null) policy.setProfile(value);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.volume_up_rounded),
            title: Text(l10n.settingsTestSpeaker),
            subtitle: Text(l10n.settingsTestSpeakerHint),
            onTap: () async {
              // Grab the messenger before the await so nothing reaches for a
              // BuildContext once the tone has finished playing.
              final messenger = ScaffoldMessenger.of(context);
              final ok = await SnailAudio().playTestTone();
              if (!mounted) return;
              messenger.showSnackBar(SnackBar(
                content: Text(ok
                    ? l10n.settingsTestToneOutputting
                    : l10n.sessionTestToneFailed),
              ));
            },
          ),
        ],
      ),
    );
  }

  String _profileLabel(AppLocalizations l10n, AudioPolicyProfile profile) =>
      switch (profile) {
        AudioPolicyProfile.auto => l10n.settingsProfileAuto,
        AudioPolicyProfile.headset => l10n.audioRouteHeadset,
        AudioPolicyProfile.speakerEcho => l10n.settingsProfileSpeakerEcho,
        AudioPolicyProfile.longerSpeech => l10n.settingsProfileLongerSentences,
      };

  Widget _identityGroup(AppLocalizations l10n, ColorScheme colors) {
    return Consumer<UserIdentityService>(
      builder: (_, identity, __) => _SettingsGroup(
        icon: Icons.person_rounded,
        color: colors.primary,
        title: l10n.settingsMyIdentitySection,
        summary: identity.identity?.username ?? l10n.settingsSnailUserFallback,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.qr_code_2),
            title: Text(
                identity.identity?.username ?? l10n.settingsSnailUserFallback),
            subtitle:
                Text(identity.identity?.userId ?? l10n.settingsBeingSetUp),
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(l10n.settingsProfileAndUsage),
            subtitle: Text(l10n.settingsProfileAndUsageSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/profile'),
          ),
        ],
      ),
    );
  }

  Widget _errorLogGroup(AppLocalizations l10n, ColorScheme colors) {
    return Consumer<ErrorLogger>(
      builder: (_, logger, __) {
        final count = logger.getLogs().length;
        return _SettingsGroup(
          icon: Icons.bug_report_rounded,
          color: count > 0 ? colors.error : colors.secondary,
          title: l10n.errorLogTitle,
          summary: count > 0
              ? l10n.settingsErrorLogEntryCount(count)
              : l10n.errorLogEmpty,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report),
              title: Text(l10n.settingsShowErrorLog),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ErrorLogScreen())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_outline),
              title: Text(count > 0
                  ? l10n.settingsClearLogWithCount(count)
                  : l10n.settingsClearLog),
              enabled: count > 0,
              onTap: count > 0 ? () => _confirmClearLog(logger, count) : null,
            ),
          ],
        );
      },
    );
  }

  void _confirmClearLog(ErrorLogger logger, int count) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.errorLogClearConfirmTitle),
        content: Text(l10n.settingsClearLogConfirmBody(count)),
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

/// A collapsible settings section: icon, title, a one-line summary of its
/// current state, and the controls themselves once opened.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.icon,
    required this.color,
    required this.title,
    required this.summary,
    required this.children,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String summary;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      color: _tintedSurface(theme, color),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: _tintedBorder(theme, color)),
      ),
      child: Theme(
        // The tile draws its own dividers on top of the card border otherwise.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<String>(title),
          leading: _IconChip(icon: icon, color: color),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                color: colors.onSurface.withValues(alpha: .65)),
          ),
          // Top padding matters: without it the first field's floating label
          // is clipped by the tile above it.
          childrenPadding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// A settings entry with nothing to unfold — it either navigates somewhere or
/// just states a fact.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: _tintedSurface(theme, color),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: _tintedBorder(theme, color)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: _IconChip(icon: icon, color: color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                color:
                    theme.colorScheme.onSurface.withValues(alpha: .65))),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .20 : .13),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

Color _tintedSurface(ThemeData theme, Color accent) => Color.alphaBlend(
    accent.withValues(alpha: theme.brightness == Brightness.dark ? .10 : .06),
    theme.colorScheme.surface);

Color _tintedBorder(ThemeData theme, Color accent) =>
    accent.withValues(alpha: theme.brightness == Brightness.dark ? .26 : .18);

class _LanguageDropdown extends StatelessWidget {
  const _LanguageDropdown({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final known = _languages.any((l) => l.code == value);
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        // Keeps the field valid when the session resolved to a language the
        // chip row does not list.
        if (!known)
          DropdownMenuItem(value: value, child: Text(_languageLabel(value))),
        for (final language in _languages)
          DropdownMenuItem(
              value: language.code, child: Text(language.native)),
      ],
      onChanged: (code) {
        if (code != null) onChanged(code);
      },
    );
  }
}

class _LanguageChips extends StatelessWidget {
  const _LanguageChips();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
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
    );
  }
}
