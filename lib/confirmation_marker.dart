import 'dart:convert';
import 'dart:io';

import 'ostree_service.dart';

class PendingConfirmation {
  final String packageName;
  final DeploymentInfo before;
  final DateTime installedAt;

  PendingConfirmation({
    required this.packageName,
    required this.before,
    required this.installedAt,
  });
}

class ConfirmationMarker {
  static String get _stateDir => '${Platform.environment['HOME']}/.local/state/layer_wizard';
  static String get _markerPath => '$_stateDir/pending_confirmation.json';
  static String get _autostartPath =>
      '${Platform.environment['HOME']}/.config/autostart/com.ironmagma.layer_wizard.desktop';

  static Future<void> write(String packageName, DeploymentInfo before) async {
    final dir = Directory(_stateDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final json = jsonEncode({
      'packageName': packageName,
      'before': before.toJson(),
      'installedAt': DateTime.now().toIso8601String(),
    });
    await File(_markerPath).writeAsString(json);
  }

  static Future<PendingConfirmation?> read() async {
    final file = File(_markerPath);
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return PendingConfirmation(
        packageName: data['packageName'] as String,
        before: DeploymentInfo.fromJson(data['before'] as Map<String, dynamic>),
        installedAt: DateTime.parse(data['installedAt'] as String),
      );
    } catch (_) {
      // Corrupt/unreadable marker — treat as if nothing is pending rather
      // than getting the user stuck on a confirmation screen we can't render.
      return null;
    }
  }

  static Future<void> clear() async {
    final file = File(_markerPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Installs an autostart entry pointing at the currently-running binary,
  /// so the confirmation screen is shown automatically right after the next
  /// login. Idempotent.
  static Future<void> installAutostart() async {
    final dir = Directory('${Platform.environment['HOME']}/.config/autostart');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final exe = Platform.resolvedExecutable;
    final contents = '''
[Desktop Entry]
Type=Application
Name=Layer Wizard Confirmation
Comment=Confirm a pending permanent package layer
Exec=$exe
X-GNOME-Autostart-enabled=true
NoDisplay=true
''';
    await File(_autostartPath).writeAsString(contents);
  }

  static Future<void> removeAutostart() async {
    final file = File(_autostartPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
