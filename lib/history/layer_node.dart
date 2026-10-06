/// One row in the `nodes` table: a single ostree deployment checksum we know
/// about, and what we believe produced it. `checksum` is the same string
/// `rpm-ostree status --json` / `ostree log` use, so a row can always be
/// cross-referenced against the live system rather than trusted blindly.
class LayerNode {
  final int id;
  final String checksum;
  final String? baseChecksum;
  final int? parentId;
  final String action; // 'install' | 'uninstall' | 'rollback' | 'detected'
  final String? packageName;
  final String? version;
  final String? containerImageRef;
  final List<String> requestedPackages;
  final String source; // 'layer_wizard' | 'detected'
  final DateTime createdAt;
  final DateTime? appliedAt;
  final String? notes;

  LayerNode({
    required this.id,
    required this.checksum,
    this.baseChecksum,
    this.parentId,
    required this.action,
    this.packageName,
    this.version,
    this.containerImageRef,
    this.requestedPackages = const [],
    required this.source,
    required this.createdAt,
    this.appliedAt,
    this.notes,
  });
}
