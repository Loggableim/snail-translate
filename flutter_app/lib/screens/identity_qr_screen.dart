import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../l10n/app_localizations.dart';
import '../services/user_identity_service.dart';

class IdentityQrScreen extends StatelessWidget {
  const IdentityQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.identityQrTitle)),
      body: Consumer<UserIdentityService>(
        builder: (_, identity, __) {
          final data = identity.qrPayload;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final qrColor = isDark ? Colors.white : Colors.black;
          final qrBackground =
              isDark ? Theme.of(context).colorScheme.surface : Colors.white;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(identity.identity!.username,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(l10n.identityQrScanHint,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: qrBackground,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: QrImageView(
                        data: data,
                        size: 232,
                        backgroundColor: qrBackground,
                        eyeStyle: QrEyeStyle(color: qrColor),
                        dataModuleStyle: QrDataModuleStyle(color: qrColor),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SelectableText(identity.identity!.userId,
                      style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
