import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'confirmation_marker.dart';
import 'history/history_service.dart';
import 'ostree_service.dart';

enum _ApplyState { idle, running, success, failed }

enum _PackageSource { search, file }

class WizardHomePage extends StatefulWidget {
  const WizardHomePage({super.key});

  @override
  State<WizardHomePage> createState() => _WizardHomePageState();
}

class _WizardHomePageState extends State<WizardHomePage> {
  int _currentStep = 0;
  final _packageController = TextEditingController();

  _PackageSource _packageSource = _PackageSource.search;
  String? _selectedFilePath;
  String? _resolvedFileName;

  Future<DeploymentInfo>? _statusFuture;
  bool _checking = false;
  String? _checkError;
  bool _checkErrorIsEngineFailure = false;
  bool _packageVerified = false;

  /// What actually gets passed to `rpm-ostree install` — a package name or
  /// a local filesystem path, depending on [_packageSource].
  String get _installTarget =>
      _packageSource == _PackageSource.file ? (_selectedFilePath ?? '') : _packageController.text.trim();

  /// What gets shown to the user and recorded in history — the resolved
  /// NEVRA for a local file (readable even after the file is gone), or the
  /// typed name for a search.
  String get _displayName => _packageSource == _PackageSource.file
      ? (_resolvedFileName ?? _selectedFilePath?.split('/').last ?? '')
      : _packageController.text.trim();

  _ApplyState _applyState = _ApplyState.idle;
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();
  DeploymentInfo? _beforeInfo;

  @override
  void initState() {
    super.initState();
    _statusFuture = OstreeService.getStatus();
  }

  Future<void> _checkPackage() async {
    if (_packageSource == _PackageSource.file) {
      final path = _selectedFilePath;
      if (path == null) return;
      setState(() {
        _checking = true;
        _checkError = null;
        _checkErrorIsEngineFailure = false;
        _packageVerified = false;
      });
      try {
        final resolved = await OstreeService.inspectLocalRpm(path);
        setState(() {
          _resolvedFileName = resolved;
          _packageVerified = true;
        });
      } catch (e) {
        setState(() => _checkError = e.toString());
      } finally {
        setState(() => _checking = false);
      }
      return;
    }

    final name = _packageController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _checking = true;
      _checkError = null;
      _checkErrorIsEngineFailure = false;
      _packageVerified = false;
    });
    try {
      final exists = await OstreeService.checkPackageExists(name);
      setState(() {
        _packageVerified = exists;
        _checkError = exists ? null : 'No package named "$name" was found.';
      });
    } on PackageEngineException catch (e) {
      setState(() {
        _checkErrorIsEngineFailure = true;
        _checkError = 'Package search isn\'t working right now, so this '
            'can\'t be verified: $e';
      });
    } catch (e) {
      setState(() => _checkError = e.toString());
    } finally {
      setState(() => _checking = false);
    }
  }

  Future<void> _pickFile() async {
    final downloads = '${Platform.environment['HOME']}/Downloads';
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['rpm'],
      initialDirectory: await Directory(downloads).exists() ? downloads : null,
    );
    final path = file?.path;
    if (path == null) return;
    setState(() {
      _selectedFilePath = path;
      _resolvedFileName = null;
      _packageVerified = false;
      _checkError = null;
    });
    await _checkPackage();
  }

  void _setPackageSource(_PackageSource source) {
    if (source == _packageSource) return;
    setState(() {
      _packageSource = source;
      _packageVerified = false;
      _checkError = null;
      _checkErrorIsEngineFailure = false;
      _selectedFilePath = null;
      _resolvedFileName = null;
      _packageController.clear();
    });
  }

  Future<void> _startInstall() async {
    final target = _installTarget;
    final displayName = _displayName;
    setState(() {
      _applyState = _ApplyState.running;
      _log.clear();
    });
    try {
      _beforeInfo = await OstreeService.getStatus();
      final exitCode = await OstreeService.installPackage(target, (line) {
        setState(() => _log.add(line));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScroll.hasClients) {
            _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
          }
        });
      });
      if (exitCode == 0) {
        await ConfirmationMarker.write(displayName, _beforeInfo!);
        await ConfirmationMarker.installAutostart();
        final deployments = await OstreeService.getAllDeployments();
        final staged = deployments.firstWhere(
          (d) => d.staged,
          orElse: () => deployments.firstWhere((d) => !d.booted, orElse: () => deployments.first),
        );
        await HistoryService.instance.recordInstall(packageName: displayName, staged: staged);
        setState(() => _applyState = _ApplyState.success);
      } else {
        setState(() => _applyState = _ApplyState.failed);
      }
    } catch (e) {
      setState(() {
        _log.add('Error: $e');
        _applyState = _ApplyState.failed;
      });
    }
  }

  void _onStepContinue() {
    if (_currentStep == 1) {
      if (!_packageVerified) return;
    }
    if (_currentStep == 2) {
      setState(() => _currentStep = 3);
      _startInstall();
      return;
    }
    if (_currentStep < 2) {
      setState(() => _currentStep += 1);
    }
  }

  void _onStepCancel() {
    if (_currentStep > 0 && _applyState == _ApplyState.idle) {
      setState(() => _currentStep -= 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Layer Wizard')),
      body: Stepper(
        type: StepperType.horizontal,
        currentStep: _currentStep,
        onStepContinue: _applyState == _ApplyState.idle ? _onStepContinue : null,
        onStepCancel: _applyState == _ApplyState.idle ? _onStepCancel : null,
        controlsBuilder: (context, details) {
          if (_currentStep == 3) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _currentStep == 1 && !_packageVerified ? null : details.onStepContinue,
                  child: Text(_currentStep == 2 ? 'Install' : 'Continue'),
                ),
                const SizedBox(width: 8),
                if (_currentStep > 0)
                  TextButton(onPressed: details.onStepCancel, child: const Text('Back')),
              ],
            ),
          );
        },
        steps: [
          Step(
            title: const Text('Welcome'),
            isActive: _currentStep >= 0,
            content: _buildWelcome(),
          ),
          Step(
            title: const Text('Package'),
            isActive: _currentStep >= 1,
            content: _buildPackageStep(),
          ),
          Step(
            title: const Text('Confirm'),
            isActive: _currentStep >= 2,
            content: _buildConfirmStep(),
          ),
          Step(
            title: const Text('Apply'),
            isActive: _currentStep >= 3,
            content: _buildApplyStep(),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcome() {
    return FutureBuilder<DeploymentInfo>(
      future: _statusFuture,
      builder: (context, snapshot) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently adds a package to your system image via '
              '"rpm-ostree install". Unlike a transient install, it survives '
              'a reboot — but it only takes effect after you restart.',
            ),
            const SizedBox(height: 12),
            if (snapshot.hasData)
              Text('Currently running: ${snapshot.data!.version}\n'
                  '${snapshot.data!.containerImageRef}')
            else if (snapshot.hasError)
              Text('Could not read system status: ${snapshot.error}')
            else
              const CircularProgressIndicator(),
          ],
        );
      },
    );
  }

  Widget _buildPackageStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_PackageSource>(
          segments: const [
            ButtonSegment(
              value: _PackageSource.search,
              label: Text('Search by name'),
              icon: Icon(Icons.search),
            ),
            ButtonSegment(
              value: _PackageSource.file,
              label: Text('Local file (.rpm)'),
              icon: Icon(Icons.insert_drive_file_outlined),
            ),
          ],
          selected: {_packageSource},
          onSelectionChanged: (s) => _setPackageSource(s.first),
        ),
        const SizedBox(height: 12),
        if (_packageSource == _PackageSource.search) _buildSearchInput() else _buildFileInput(),
        if (_checkError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _checkErrorIsEngineFailure ? Icons.warning_amber : Icons.info_outline,
                  color: Theme.of(context).colorScheme.error,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_checkError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSearchInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _packageController,
          decoration: const InputDecoration(
            labelText: 'Package name',
            hintText: 'e.g. calligra-words',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _packageVerified = false),
          onSubmitted: (_) => _checkPackage(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(
              onPressed: _checking ? null : _checkPackage,
              child: _checking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Check'),
            ),
            const SizedBox(width: 12),
            if (_packageVerified)
              const Row(children: [Icon(Icons.check_circle, color: Colors.green), SizedBox(width: 4), Text('Found')]),
          ],
        ),
      ],
    );
  }

  Widget _buildFileInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _checking ? null : _pickFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose .rpm file…'),
            ),
            const SizedBox(width: 12),
            if (_checking) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            if (_packageVerified)
              const Row(children: [Icon(Icons.check_circle, color: Colors.green), SizedBox(width: 4), Text('Valid RPM')]),
          ],
        ),
        if (_selectedFilePath != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_selectedFilePath!, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }

  Widget _buildConfirmStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _packageSource == _PackageSource.file ? 'File: $_displayName' : 'Package: $_displayName',
          style: const TextStyle(fontSize: 16),
        ),
        if (_packageSource == _PackageSource.file && _selectedFilePath != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_selectedFilePath!, style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        const Text(
          'You will be prompted for your password via the system\'s '
          'PolicyKit dialog. Afterward, a restart will be required before '
          'the package becomes usable.',
        ),
      ],
    );
  }

  Widget _buildApplyStep() {
    switch (_applyState) {
      case _ApplyState.idle:
        return const Text('Waiting to start…');
      case _ApplyState.running:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            SizedBox(height: 240, child: _buildLog()),
          ],
        );
      case _ApplyState.success:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Restart required to use "$_displayName".'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => OstreeService.rebootNow(),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reboot Now'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => setState(() {
                    _currentStep = 0;
                    _applyState = _ApplyState.idle;
                    _packageController.clear();
                    _packageVerified = false;
                    _selectedFilePath = null;
                    _resolvedFileName = null;
                    _packageSource = _PackageSource.search;
                    _statusFuture = OstreeService.getStatus();
                  }),
                  child: const Text('Reboot Later'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(height: 180, child: _buildLog()),
          ],
        );
      case _ApplyState.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.error, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                const Text('Install failed. Nothing was changed — no restart needed.'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(height: 180, child: _buildLog()),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => setState(() => _applyState = _ApplyState.idle),
              child: const Text('Try Again'),
            ),
          ],
        );
    }
  }

  Widget _buildLog() {
    return Container(
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
    );
  }
}
