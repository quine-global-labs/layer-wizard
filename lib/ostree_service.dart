import 'dart:convert';
import 'dart:io';

class DeploymentInfo {
  final String version;
  final String checksum;
  final String containerImageRef;

  DeploymentInfo({
    required this.version,
    required this.checksum,
    required this.containerImageRef,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'checksum': checksum,
        'containerImageRef': containerImageRef,
      };

  factory DeploymentInfo.fromJson(Map<String, dynamic> json) => DeploymentInfo(
        version: json['version'] as String,
        checksum: json['checksum'] as String,
        containerImageRef: json['containerImageRef'] as String,
      );
}

class OstreeService {
  /// Reads the currently booted deployment via `rpm-ostree status --json`
  /// (unprivileged, read-only).
  static Future<DeploymentInfo> getStatus() async {
    final result = await Process.run('rpm-ostree', ['status', '--json']);
    if (result.exitCode != 0) {
      throw Exception('rpm-ostree status failed: ${result.stderr}');
    }
    final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final deployments = data['deployments'] as List;
    final booted = deployments.cast<Map<String, dynamic>>().firstWhere(
          (d) => d['booted'] == true,
          orElse: () => deployments.first as Map<String, dynamic>,
        );
    return DeploymentInfo(
      version: booted['version'] as String? ?? 'unknown',
      checksum: booted['checksum'] as String? ?? 'unknown',
      containerImageRef: booted['container-image-reference'] as String? ?? 'unknown',
    );
  }

  /// Unprivileged existence check so typos surface before escalating to
  /// pkexec. Matches on exact name or name.arch.
  static Future<bool> checkPackageExists(String name) async {
    final result = await Process.run('dnf', ['repoquery', name]);
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  /// Permanently layers a package via `rpm-ostree install`. Streams combined
  /// stdout+stderr lines. Mirrors pkg_launcher's DnfService.installTransient
  /// pattern (pkexec through the desktop PolicyKit agent).
  static Future<int> installPackage(String name, void Function(String line) onLine) async {
    final process = await Process.start('pkexec', ['rpm-ostree', 'install', '-y', name]);
    process.stdout.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.isNotEmpty) onLine(line);
      }
    });
    process.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.isNotEmpty) onLine(line);
      }
    });
    return process.exitCode;
  }

  /// Rolls back to the previously booted deployment and reboots into it
  /// immediately. Callers must warn the user before calling this: the
  /// screen will go black and the machine will restart as part of this
  /// call returning.
  static Future<int> rollback(void Function(String line) onLine) async {
    final process = await Process.start('pkexec', ['bootc', 'rollback', '--apply']);
    process.stdout.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.isNotEmpty) onLine(line);
      }
    });
    process.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.isNotEmpty) onLine(line);
      }
    });
    return process.exitCode;
  }

  /// Reboots immediately via the desktop PolicyKit agent.
  static Future<void> rebootNow() async {
    await Process.start('pkexec', ['systemctl', 'reboot'], mode: ProcessStartMode.detached);
  }
}
