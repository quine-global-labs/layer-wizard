import 'dart:convert';
import 'dart:io';

class DeploymentInfo {
  final String version;
  final String checksum;
  final String containerImageRef;
  final String? baseChecksum;
  final List<String> requestedPackages;
  final bool booted;
  final bool staged;

  DeploymentInfo({
    required this.version,
    required this.checksum,
    required this.containerImageRef,
    this.baseChecksum,
    this.requestedPackages = const [],
    this.booted = false,
    this.staged = false,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'checksum': checksum,
        'containerImageRef': containerImageRef,
        'baseChecksum': baseChecksum,
        'requestedPackages': requestedPackages,
        'booted': booted,
        'staged': staged,
      };

  factory DeploymentInfo.fromJson(Map<String, dynamic> json) => DeploymentInfo(
        version: json['version'] as String,
        checksum: json['checksum'] as String,
        containerImageRef: json['containerImageRef'] as String,
        baseChecksum: json['baseChecksum'] as String?,
        requestedPackages:
            (json['requestedPackages'] as List?)?.cast<String>() ?? const [],
        booted: json['booted'] as bool? ?? false,
        staged: json['staged'] as bool? ?? false,
      );

  static DeploymentInfo _fromStatusJson(Map<String, dynamic> d) => DeploymentInfo(
        version: d['version'] as String? ?? 'unknown',
        checksum: d['checksum'] as String? ?? 'unknown',
        containerImageRef: d['container-image-reference'] as String? ?? 'unknown',
        baseChecksum: d['base-checksum'] as String?,
        requestedPackages: (d['requested-packages'] as List?)?.cast<String>() ?? const [],
        booted: d['booted'] as bool? ?? false,
        staged: d['staged'] as bool? ?? false,
      );
}

class OstreeService {
  /// Reads the currently booted deployment via `rpm-ostree status --json`
  /// (unprivileged, read-only).
  static Future<DeploymentInfo> getStatus() async {
    final deployments = await getAllDeployments();
    return deployments.firstWhere(
      (d) => d.booted,
      orElse: () => deployments.first,
    );
  }

  /// Reads every deployment rpm-ostree currently knows about (booted,
  /// staged, rollback), not just the booted one. Used to reconcile our own
  /// history against reality and to pick up the freshly-staged checksum
  /// right after an install, before any reboot has happened.
  static Future<List<DeploymentInfo>> getAllDeployments() async {
    final result = await Process.run('rpm-ostree', ['status', '--json']);
    if (result.exitCode != 0) {
      throw Exception('rpm-ostree status failed: ${result.stderr}');
    }
    final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final deployments = data['deployments'] as List;
    return deployments
        .cast<Map<String, dynamic>>()
        .map(DeploymentInfo._fromStatusJson)
        .toList();
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
