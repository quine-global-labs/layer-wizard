import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../ostree_service.dart';
import 'history_db.dart';
import 'layer_node.dart';

/// Our own append-only record of what's been layered onto the root
/// filesystem, since rpm-ostree/ostree only retain a couple of deployments
/// and prune the rest.
///
/// Every row is keyed on the ostree deployment `checksum` — the same string
/// `rpm-ostree status --json` reports — so [reconcile] can always tell
/// whether the currently-booted checksum is one we already know about (our
/// own install, or a previously-seen rollback target) or a brand new one
/// (a manual `rpm-ostree`/`bootc` change made outside this app, or an
/// upstream image update). Unknown checksums are recorded as `detected`
/// nodes rather than silently ignored, so the tree stays a true picture of
/// the running system instead of just "what Layer Wizard did".
class HistoryService {
  static final HistoryService instance = HistoryService._();
  HistoryService._();

  Database get _db => HistoryDb.database();

  /// Compares the live `rpm-ostree status` against our DB and brings
  /// `current` (and, on first run, `last_known_safe`) up to date. Safe to
  /// call on every launch — a no-op if nothing has changed since last time.
  ///
  /// [deployments] overrides the live query — tests pass a fixed list so
  /// they don't depend on `rpm-ostree` actually being present/accurate.
  Future<LayerNode> reconcile({List<DeploymentInfo>? deployments}) async {
    final db = _db;
    final deps = deployments ?? await OstreeService.getAllDeployments();
    final booted = deps.firstWhere(
      (d) => d.booted,
      orElse: () => deps.first,
    );

    LayerNode node;
    final existing = _findByChecksum(db, booted.checksum);
    if (existing == null) {
      final parent = await getCurrent();
      _insertNode(
        db,
        checksum: booted.checksum,
        baseChecksum: booted.baseChecksum,
        parentId: parent?.id,
        action: 'detected',
        version: booted.version,
        containerImageRef: booted.containerImageRef,
        requestedPackages: booted.requestedPackages,
        source: 'detected',
        appliedAt: DateTime.now(),
      );
      node = _findByChecksum(db, booted.checksum)!;
    } else {
      if (existing.appliedAt == null) {
        db.execute(
          'UPDATE nodes SET applied_at = ? WHERE id = ?',
          [DateTime.now().toIso8601String(), existing.id],
        );
      }
      node = _findByChecksum(db, booted.checksum)!;
    }

    _setPointer(db, 'current', node.id);
    if (await getLastKnownSafe() == null) {
      _setPointer(db, 'last_known_safe', node.id);
    }
    return node;
  }

  /// Records a Layer Wizard-initiated install. Called right after
  /// `rpm-ostree install` succeeds, while the new checksum is still only
  /// *staged* — `current` deliberately doesn't move until [reconcile] sees
  /// it actually booted.
  Future<LayerNode> recordInstall({
    required String packageName,
    required DeploymentInfo staged,
  }) async {
    final db = _db;
    final existing = _findByChecksum(db, staged.checksum);
    if (existing != null) return existing;

    var parent = await getCurrent();
    parent ??= await reconcile();

    _insertNode(
      db,
      checksum: staged.checksum,
      baseChecksum: staged.baseChecksum,
      parentId: parent.id,
      action: 'install',
      packageName: packageName,
      version: staged.version,
      containerImageRef: staged.containerImageRef,
      requestedPackages: staged.requestedPackages,
      source: 'layer_wizard',
    );
    return _findByChecksum(db, staged.checksum)!;
  }

  /// Moves `last_known_safe` to wherever `current` points. Called when the
  /// user confirms a post-reboot update is working.
  Future<void> markCurrentAsSafe() async {
    final current = await getCurrent();
    if (current == null) return;
    _setPointer(_db, 'last_known_safe', current.id);
  }

  Future<LayerNode?> getCurrent() => _getPointer('current');
  Future<LayerNode?> getLastKnownSafe() => _getPointer('last_known_safe');

  /// Root-to-current path through the tree, by walking `parent_id`.
  Future<List<LayerNode>> getChainToCurrent() async => _chainTo(await getCurrent());

  Future<List<LayerNode>> getAllNodes() async {
    final rs = _db.select('SELECT * FROM nodes ORDER BY id');
    return rs.map(_nodeFromRow).toList();
  }

  Future<List<LayerNode>> _chainTo(LayerNode? node) async {
    final db = _db;
    final chain = <LayerNode>[];
    var cur = node;
    while (cur != null) {
      chain.add(cur);
      final parentId = cur.parentId;
      if (parentId == null) break;
      final rs = db.select('SELECT * FROM nodes WHERE id = ?', [parentId]);
      cur = rs.isEmpty ? null : _nodeFromRow(rs.first);
    }
    return chain.reversed.toList();
  }

  Future<LayerNode?> _getPointer(String name) async {
    final rs = _db.select(
      'SELECT nodes.* FROM pointers JOIN nodes ON nodes.id = pointers.node_id WHERE pointers.name = ?',
      [name],
    );
    if (rs.isEmpty) return null;
    return _nodeFromRow(rs.first);
  }

  void _setPointer(Database db, String name, int nodeId) {
    db.execute(
      'INSERT INTO pointers (name, node_id) VALUES (?, ?) '
      'ON CONFLICT(name) DO UPDATE SET node_id = excluded.node_id',
      [name, nodeId],
    );
  }

  LayerNode? _findByChecksum(Database db, String checksum) {
    final rs = db.select('SELECT * FROM nodes WHERE checksum = ?', [checksum]);
    if (rs.isEmpty) return null;
    return _nodeFromRow(rs.first);
  }

  int _insertNode(
    Database db, {
    required String checksum,
    String? baseChecksum,
    int? parentId,
    required String action,
    String? packageName,
    String? version,
    String? containerImageRef,
    List<String> requestedPackages = const [],
    required String source,
    DateTime? appliedAt,
    String? notes,
  }) {
    db.execute(
      '''
      INSERT INTO nodes (
        checksum, base_checksum, parent_id, action, package_name, version,
        container_image_ref, requested_packages, source, created_at, applied_at, notes
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        checksum,
        baseChecksum,
        parentId,
        action,
        packageName,
        version,
        containerImageRef,
        jsonEncode(requestedPackages),
        source,
        DateTime.now().toIso8601String(),
        appliedAt?.toIso8601String(),
        notes,
      ],
    );
    return db.lastInsertRowId;
  }

  LayerNode _nodeFromRow(Row row) {
    final requestedRaw = row['requested_packages'] as String?;
    return LayerNode(
      id: row['id'] as int,
      checksum: row['checksum'] as String,
      baseChecksum: row['base_checksum'] as String?,
      parentId: row['parent_id'] as int?,
      action: row['action'] as String,
      packageName: row['package_name'] as String?,
      version: row['version'] as String?,
      containerImageRef: row['container_image_ref'] as String?,
      requestedPackages:
          requestedRaw == null ? const [] : (jsonDecode(requestedRaw) as List).cast<String>(),
      source: row['source'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      appliedAt: row['applied_at'] == null ? null : DateTime.parse(row['applied_at'] as String),
      notes: row['notes'] as String?,
    );
  }
}
