# Layer Wizard

A GUI installer wizard for permanently layering an RPM package onto a
bootc/image-based (read-only root) Linux system via `rpm-ostree install`,
with a guided reboot step and a one-click rollback if the result looks wrong.

Built for Universal Blue / Fedora bootc systems, where plain `dnf install`
refuses to run (the root filesystem is read-only) and the persistent
mechanism is `rpm-ostree install <pkg>`, which stages a new deployment that
only takes effect after a reboot.

## What it does

1. **Welcome** — shows the currently booted version/image.
2. **Package** — enter a package name; "Check" confirms it resolves
   (`dnf repoquery`) before anything privileged happens.
3. **Confirm** — review the package and what's about to happen.
4. **Apply** — runs `pkexec rpm-ostree install -y <package>`, with the
   PolicyKit password prompt and a live streamed log. On success, offers
   **Reboot Now** / **Reboot Later**.
5. After rebooting, the app **launches itself automatically** and asks:
   "Is everything working correctly?" — **Yes, keep this update**, or
   **No, something's wrong — roll back**, which runs
   `pkexec bootc rollback --apply` (reboots immediately into the previous
   deployment).

## How the post-reboot check works

This system has no `greenboot` and no automated bad-boot detection
(`systemd-bless-boot.service` exists but isn't wired up to anything here) —
so the rollback offer is **self-reported**, not automatic. Two pieces make
that work:

- **Autostart entry.** Right after a successful install,
  `ConfirmationMarker.installAutostart()` (`lib/confirmation_marker.dart`)
  writes `~/.config/autostart/com.ironmagma.layer_wizard.desktop`, with
  `Exec=` pointing at the currently-running binary
  (`Platform.resolvedExecutable`). KDE's session runs everything in
  `~/.config/autostart/` on login, which is what makes the app reappear on
  its own right after the reboot — you don't have to remember to open it.

- **The check itself runs on every launch, not just via autostart.**
  `lib/main.dart`'s `_StartupRouter` calls `ConfirmationMarker.read()` before
  deciding what to show:

  ```dart
  future: ConfirmationMarker.read(),
  builder: (context, snapshot) {
    final pending = snapshot.data;
    if (pending != null) return ConfirmationPage(pending: pending);
    return const WizardHomePage();
  }
  ```

  `read()` just checks whether
  `~/.local/state/layer_wizard/pending_confirmation.json` exists and parses
  it. That file is written by the wizard right after a successful install
  (`ConfirmationMarker.write(...)` in `lib/wizard_page.dart`), and deleted —
  along with the autostart entry — as soon as you click **Keep** or
  **Roll back** in `lib/confirmation_page.dart`.

  Running the check unconditionally at startup (rather than only when
  launched via autostart) is deliberate: if autostart doesn't fire for some
  reason, or you dismiss it and reopen the app later, you still land on the
  confirmation screen instead of that pending state getting silently
  dropped.

## Project layout

- `lib/ostree_service.dart` — all privileged/unprivileged shelling out:
  `rpm-ostree status --json`, `dnf repoquery`, `pkexec rpm-ostree install`,
  `pkexec bootc rollback --apply`, `pkexec systemctl reboot`.
- `lib/confirmation_marker.dart` — the pending-confirmation marker file and
  autostart `.desktop` entry (write/read/clear, install/remove).
- `lib/wizard_page.dart` — the install wizard (`Stepper`-based).
- `lib/confirmation_page.dart` — the post-reboot "did this work?" screen.
- `lib/main.dart` — startup routing between the two.

Privilege escalation follows the same pattern as the sibling
[`dnf-package-store`](https://github.com/quine-global-labs/dnf-package-store)
app: `pkexec` through the desktop PolicyKit agent, with stdout/stderr
streamed line-by-line into the UI.

## Building

```
flutter build linux
```

Produces `build/linux/x64/release/bundle/layer_wizard`.
