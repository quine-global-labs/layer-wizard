import 'dart:convert';
import 'dart:io';

/// Thrown when `dnf` itself fails to run (e.g. a plugin that's enabled in
/// config but missing on disk) rather than genuinely finding no match.
/// Distinct from "package not found" so the UI can tell a broken search
/// engine apart from a bad package name.
class PackageEngineException implements Exception {
  final String stderr;
  PackageEngineException(this.stderr);

  @override
  String toString() => stderr.isEmpty ? 'dnf failed to run' : stderr;
}

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
  /// pkexec. Matches on exact name or name.arch, then falls back to
  /// `--whatprovides` so virtual names like "vim" (satisfied by
  /// vim-enhanced etc., never a package themselves) check out the same way
  /// `rpm-ostree install` would actually resolve them. A nonzero exit means
  /// dnf itself failed to run (e.g. a broken plugin) rather than "not
  /// found", so that's thrown instead of silently reported as false.
  static Future<bool> checkPackageExists(String name) async {
    final byName = await Process.run('dnf', ['repoquery', name]);
    if (byName.exitCode != 0) {
      throw PackageEngineException((byName.stderr as String).trim());
    }
    if ((byName.stdout as String).trim().isNotEmpty) return true;

    final byProvides = await Process.run('dnf', ['repoquery', '--whatprovides', name]);
    if (byProvides.exitCode != 0) {
      throw PackageEngineException((byProvides.stderr as String).trim());
    }
    return (byProvides.stdout as String).trim().isNotEmpty;
  }

  /// Verifies a local RPM file and resolves it to the NEVRA name
  /// `rpm-ostree install` will actually layer. Unlike [checkPackageExists],
  /// a query failure here really does mean "not a usable package" (a
  /// corrupt download, wrong file type, etc.) rather than a broken search
  /// engine, so this throws a plain [Exception] instead of
  /// [PackageEngineException] — the caller doesn't need to distinguish an
  /// engine failure for file-based installs.
  static Future<String> inspectLocalRpm(String path) async {
    if (!await File(path).exists()) {
      throw Exception('No file found at "$path".');
    }
    final result = await Process.run(
      'rpm',
      ['-qp', '--queryformat', '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}', path],
    );
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      throw Exception(stderr.isEmpty ? 'Not a valid RPM package.' : stderr);
    }
    return (result.stdout as String).trim();
  }

  /// Permanently layers a package via `rpm-ostree install`. [target] is
  /// either a repo package name or a local filesystem path to an RPM —
  /// `rpm-ostree install` accepts both. Streams combined stdout+stderr
  /// lines. Mirrors pkg_launcher's DnfService.installTransient pattern
  /// (pkexec through the desktop PolicyKit agent).
  static Future<int> installPackage(String target, void Function(String line) onLine) async {
    final process = await Process.start('pkexec', ['rpm-ostree', 'install', '-y', target]);
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
