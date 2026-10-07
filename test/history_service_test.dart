import 'package:flutter_test/flutter_test.dart';
import 'package:layer_wizard/history/history_db.dart';
import 'package:layer_wizard/history/history_service.dart';
import 'package:layer_wizard/ostree_service.dart';

DeploymentInfo _deployment({
  required String checksum,
  bool booted = false,
  bool staged = false,
  String version = 'v1',
  List<String> requestedPackages = const [],
}) {
  return DeploymentInfo(
    version: version,
    checksum: checksum,
    containerImageRef: 'ostree-image-signed:docker://ghcr.io/ublue-os/aurora:stable',
    requestedPackages: requestedPackages,
    booted: booted,
    staged: staged,
  );
}

void main() {
  final history = HistoryService.instance;

  setUp(() {
    HistoryDb.resetForTesting();
  });

  test('first reconcile bootstraps a root node and both pointers', () async {
    final a = _deployment(checksum: 'aaa', booted: true);

    final current = await history.reconcile(deployments: [a]);

    expect(current.checksum, 'aaa');
    expect(current.parentId, isNull);
    expect(current.source, 'detected');

    final safe = await history.getLastKnownSafe();
    expect(safe?.checksum, 'aaa');
  });

  test('reconcile is idempotent for an already-known checksum', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    await history.reconcile(deployments: [a]);

    await history.reconcile(deployments: [a]);
    await history.reconcile(deployments: [a]);

    final all = await history.getAllNodes();
    expect(all, hasLength(1));
  });

  test('recordInstall adds a child of current without moving current', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    final root = await history.reconcile(deployments: [a]);

    final staged = _deployment(checksum: 'bbb', staged: true, requestedPackages: ['vim']);
    final node = await history.recordInstall(packageName: 'vim', staged: staged);

    expect(node.parentId, root.id);
    expect(node.action, 'install');
    expect(node.source, 'layer_wizard');
    expect(node.packageName, 'vim');

    final current = await history.getCurrent();
    expect(current?.id, root.id, reason: 'current must not move until the staged deployment is booted');
  });

  test('rebooting into a staged install moves current without a duplicate row', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    await history.reconcile(deployments: [a]);

    final staged = _deployment(checksum: 'bbb', staged: true, requestedPackages: ['vim']);
    final installed = await history.recordInstall(packageName: 'vim', staged: staged);

    final bootedAfterReboot = _deployment(checksum: 'bbb', booted: true, requestedPackages: ['vim']);
    final current = await history.reconcile(deployments: [bootedAfterReboot]);

    expect(current.id, installed.id);
    final all = await history.getAllNodes();
    expect(all, hasLength(2), reason: 'no new row — same checksum as the staged install');
  });

  test('a manual change (unknown checksum) is recorded as detected, parented on current', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    final root = await history.reconcile(deployments: [a]);

    final manual = _deployment(checksum: 'ccc', booted: true, requestedPackages: ['htop']);
    final current = await history.reconcile(deployments: [manual]);

    expect(current.checksum, 'ccc');
    expect(current.source, 'detected');
    expect(current.parentId, root.id);

    final all = await history.getAllNodes();
    expect(all, hasLength(2));
  });

  test('markCurrentAsSafe moves last_known_safe to the current node', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    await history.reconcile(deployments: [a]);

    final b = _deployment(checksum: 'bbb', booted: true);
    await history.reconcile(deployments: [b]);

    expect((await history.getLastKnownSafe())?.checksum, 'aaa');

    await history.markCurrentAsSafe();

    expect((await history.getLastKnownSafe())?.checksum, 'bbb');
  });

  test('getChainToCurrent walks root to current in order', () async {
    final a = _deployment(checksum: 'aaa', booted: true);
    await history.reconcile(deployments: [a]);

    final staged = _deployment(checksum: 'bbb', staged: true, requestedPackages: ['vim']);
    await history.recordInstall(packageName: 'vim', staged: staged);

    final bootedAfterReboot = _deployment(checksum: 'bbb', booted: true, requestedPackages: ['vim']);
    await history.reconcile(deployments: [bootedAfterReboot]);

    final chain = await history.getChainToCurrent();

    expect(chain.map((n) => n.checksum), ['aaa', 'bbb']);
  });
}
