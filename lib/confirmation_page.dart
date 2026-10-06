import 'package:flutter/material.dart';

import 'confirmation_marker.dart';
import 'ostree_service.dart';
import 'wizard_page.dart';

class ConfirmationPage extends StatefulWidget {
  final PendingConfirmation pending;

  const ConfirmationPage({super.key, required this.pending});

  @override
  State<ConfirmationPage> createState() => _ConfirmationPageState();
}

class _ConfirmationPageState extends State<ConfirmationPage> {
  bool _rollingBack = false;
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();

  Future<void> _keep() async {
    await ConfirmationMarker.clear();
    await ConfirmationMarker.removeAutostart();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const WizardHomePage()),
    );
  }

  Future<void> _confirmRollback() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Roll back now?'),
        content: const Text(
          'This will immediately reboot the machine into the previous system '
          'version. Save any open work first.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Roll back and reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _rollingBack = true);
    // The machine reboots as part of this call returning — clear bookkeeping
    // first so there's nothing stale to confirm once we're back on the
    // known-good deployment.
    await ConfirmationMarker.clear();
    await ConfirmationMarker.removeAutostart();
    await OstreeService.rollback((line) {
      setState(() => _log.add(line));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm Update')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _rollingBack
              ? [
                  const Text('Rolling back and rebooting…', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.all(8),
                      child: ListView.builder(
                        controller: _logScroll,
                        itemCount: _log.length,
                        itemBuilder: (context, i) => Text(
                          _log[i],
                          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ]
              : [
                  Icon(Icons.help_outline, size: 48, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'You installed "${p.packageName}" on '
                    '${p.installedAt.toLocal().toString().split('.').first}.',
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  const Text('The system rebooted into the update. Is everything working correctly?'),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Previous version: ${p.before.version}\n'
                          'Previous image: ${p.before.containerImageRef}'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _keep,
                    icon: const Icon(Icons.check),
                    label: const Text('Yes, keep this update'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _confirmRollback,
                    icon: const Icon(Icons.undo),
                    label: const Text('No, something\'s wrong — roll back'),
                  ),
                ],
        ),
      ),
    );
  }
}
