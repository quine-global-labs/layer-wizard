import 'package:flutter/material.dart';

import 'confirmation_marker.dart';
import 'confirmation_page.dart';
import 'history/history_service.dart';
import 'wizard_page.dart';

void main() {
  runApp(const LayerWizardApp());
}

class LayerWizardApp extends StatelessWidget {
  const LayerWizardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Layer Wizard',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const _StartupRouter(),
    );
  }
}

/// Checks for a pending post-reboot confirmation before deciding which
/// screen to show first.
class _StartupRouter extends StatelessWidget {
  const _StartupRouter();

  /// Reconciles our layer history against the live `rpm-ostree status`
  /// before anything else — catches rollbacks, reboots into our own
  /// installs, and any manual changes made outside the app — then checks
  /// for a pending post-reboot confirmation.
  Future<PendingConfirmation?> _startup() async {
    await HistoryService.instance.reconcile();
    return ConfirmationMarker.read();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PendingConfirmation?>(
      future: _startup(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final pending = snapshot.data;
        if (pending != null) {
          return ConfirmationPage(pending: pending);
        }
        return const WizardHomePage();
      },
    );
  }
}
