import 'package:flutter/material.dart';

import 'confirmation_marker.dart';
import 'confirmation_page.dart';
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PendingConfirmation?>(
      future: ConfirmationMarker.read(),
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
