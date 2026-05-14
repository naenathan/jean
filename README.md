<div align="center">

# Jean (NixOS Fork)

A personal fork of [coollabsio/jean](https://github.com/coollabsio/jean) with first-class NixOS support and a daily auto-update pipeline.

</div>

## What this fork adds

Upstream Jean targets macOS primarily, with community-tested Linux support on Arch. This fork makes it run cleanly on NixOS by pinning a reproducible build environment with Nix, patching one Linux-portability bug in the Tauri event loop, and shipping a self-updating systemd timer that keeps the locally built binary current with upstream releases.

Concretely:

- `flake.nix` defines a dev shell with the exact webkitgtk, libsoup, GTK, GStreamer, and GSettings dependencies the Tauri webview needs at runtime, plus the right `PKG_CONFIG_PATH` / `LD_LIBRARY_PATH` / `GST_PLUGIN_SYSTEM_PATH_1_0` env so `bun run tauri dev` and `tauri build` both work out of the box
- A small patch in `src-tauri/src/lib.rs` gates the `tauri::RunEvent::Reopen` match arm behind `#[cfg(target_os = "macos")]` since that variant only exists on macOS and breaks the Linux build otherwise
- `scripts/install-local-nixos.sh` builds a `~/.local/bin/jean` wrapper that injects the dev shell's runtime env into the compiled binary, and registers a `.desktop` entry and icon so the app shows up in your launcher and can be pinned to your bar
- `scripts/install-auto-update.sh` installs a systemd user timer that runs `scripts/update-from-release.sh` daily at 8 AM, rebasing the local nix branch onto the latest upstream release tag and rebuilding the binary in place

The everything-just-works goal: pin Jean to your bottom bar once, then keep clicking it. The icon always launches the latest upstream release with the local nix patches applied.

## First-time install on NixOS

Prerequisites: the [Nix package manager](https://nixos.org/download) with flakes enabled, [`gh`](https://cli.github.com/) authenticated to your GitHub account.

```bash
git clone https://github.com/naenathan/jean.git
cd jean

# build the binary once so the wrapper has something to exec
nix develop -c bun install
nix develop -c bun run tauri build --no-bundle

# install wrapper, .desktop entry, and icon
scripts/install-local-nixos.sh

# install the daily auto-update timer
JEAN_REMOTE=upstream scripts/install-auto-update.sh
```

The `--no-bundle` flag skips Tauri's `.deb` / `.rpm` / `.AppImage` packaging step, which hardcodes `/usr/bin/xdg-open` and fails on NixOS where `xdg-open` lives elsewhere. The wrapper at `~/.local/bin/jean` exec's the compiled binary at `src-tauri/target/release/jean` directly, so the bundle artifacts are not needed.

After install, pin Jean to your bar by opening it once from your launcher and right-clicking the bar icon. Future clicks always run the latest build.

### Adding the upstream remote

If you cloned this fork (recommended), the auto-update script needs a remote pointing at coollabsio/jean to fetch release tags from. The clone command above does not set this up automatically:

```bash
git remote add upstream https://github.com/coollabsio/jean.git
git fetch --tags upstream
```

Verify with `git remote -v`. The `install-auto-update.sh` invocation above passes `JEAN_REMOTE=upstream` so the systemd unit's environment block points the timer at the right remote.

## Daily auto-update pipeline

A systemd user timer fires at 08:00 local time (with up to 2 minutes of jitter so multiple machines don't hammer GitHub at the same instant), executing the following steps:

1. `git fetch --tags upstream` to pull any new release tags
2. Look up the latest release via `gh release view --repo coollabsio/jean`
3. If `main` is already based on the latest tag, refresh `flake.lock` via `nix flake update` (commits the bump if anything changed) and exit
4. Otherwise rebase `main` onto the latest tag. On conflict, run `git rebase --abort` so the branch is left exactly as it was, and log the failure for manual resolution
5. Refresh `flake.lock` and commit any change
6. Rebuild the app via `nix develop -c bash -c 'bun install && bun run tauri build --no-bundle'`. The fresh binary lands at `src-tauri/target/release/jean`, which the wrapper picks up on next launch. If the app is currently running, Linux keeps the old executable mapped for the running process and uses the new one on the next launch (no risk of crashing mid-use)

The full source for this pipeline is in `scripts/update-from-release.sh`. It supports several modes for manual invocation:

| Invocation | Behavior |
|---|---|
| `scripts/update-from-release.sh` | Rebase onto latest release, pause for conflict resolution if needed |
| `scripts/update-from-release.sh v0.1.47` | Rebase onto a specific tag instead of the latest |
| `scripts/update-from-release.sh --check` | Report status only, make no changes (exits 3 if behind) |
| `scripts/update-from-release.sh --auto` | Abort cleanly on conflict instead of pausing (used by the timer) |
| `scripts/update-from-release.sh --update-flake` | Also run `nix flake update` and commit the result |
| `scripts/update-from-release.sh --rebuild` | Also `bun install && bun run tauri build --no-bundle` after rebase |

The systemd unit calls it with `--auto --update-flake --rebuild`, the unattended-safe combination.

### Exit codes

The script and service share a small set of distinct exit codes so the log is unambiguous:

| Code | Meaning | Action needed |
|---|---|---|
| 0 | Up to date, or fully updated successfully | None |
| 3 | Out of date (only from `--check` mode) | Run without `--check` to apply |
| 4 | Rebase hit a conflict, branch was aborted and is untouched | Run `scripts/update-from-release.sh` manually and resolve |
| 5 | Rebase succeeded but the build failed (source updated, binary stale) | Check the log, fix the build, run `nix develop -c bash -c 'bun install && bun run tauri build --no-bundle'` |
| other | Error before any state change (dirty tree, network, missing tools) | Check the log |

`SuccessExitStatus=0 4 5` in the unit tells systemd to treat conflict-aborts and build failures as clean exits (the abort itself is the correct behavior), so `systemctl --user status` does not show false-positive failures.

### Where to look

| Thing | Path |
|---|---|
| Service unit | `~/.config/systemd/user/jean-release-check.service` |
| Timer unit | `~/.config/systemd/user/jean-release-check.timer` |
| Daily log | `~/.local/state/jean/release-check.log` |
| Manual rebuild log | `~/.local/state/jean/manual-rebuild.log` (only written by manual `tee` invocations) |
| Wrapper | `~/.local/bin/jean` |
| Desktop entry | `~/.local/share/applications/jean.desktop` |
| Icon | `~/.local/share/icons/hicolor/128x128/apps/jean.png` |

### Useful commands

```bash
# peek at timer state and the most recent log entries
scripts/install-auto-update.sh --status

# run the pipeline right now (does not affect the daily schedule)
systemctl --user start jean-release-check.service

# stream the full unit log including stderr from systemd
journalctl --user -u jean-release-check.service -n 50

# disable auto-update entirely (leaves the log file behind)
scripts/install-auto-update.sh --uninstall
```

### Configuration via env vars

`scripts/install-auto-update.sh` reads three env vars and bakes them into the generated unit file. Re-run the install script after changing any of them:

| Variable | Default | Purpose |
|---|---|---|
| `JEAN_NIX_BRANCH` | `main` | The local branch holding nix patches that gets rebased onto upstream releases. On this fork `main` plays that role; set this if you keep your patches on a different branch |
| `JEAN_REMOTE` | `origin` | The git remote to fetch release tags from. Set to `upstream` if `origin` is your fork |
| `JEAN_TIMER_TIME` | `*-*-* 08:00:00` | When to fire, in systemd `OnCalendar` format. See `man systemd.time` for syntax |

For example, to move the daily run to 6 AM and use a different branch name:

```bash
JEAN_NIX_BRANCH=local/nixos JEAN_TIMER_TIME='*-*-* 06:00:00' scripts/install-auto-update.sh
```

### A note on lingering

User systemd timers only fire while a user session is active. If you want the timer to run even when no one is logged in:

```bash
sudo loginctl enable-linger $USER
```

`Persistent=true` in the timer unit also makes systemd catch up at the next login if a fire was missed (machine asleep, user logged out, etc.), so for a personal workstation you typically do not need lingering.

## Diverging from upstream

The fork carries a small, stable set of patches on top of every upstream release tag:

1. `flake.nix` and `flake.lock`: nix dev shell with all runtime deps
2. The `RunEvent::Reopen` cfg gate in `src-tauri/src/lib.rs` for Linux portability
3. `scripts/install-local-nixos.sh`: wrapper installer
4. `scripts/update-from-release.sh`: the rebase + rebuild pipeline
5. `scripts/install-auto-update.sh`: systemd timer installer
6. This README

These get replayed onto each new upstream release tag via `git rebase`. Conflicts are rare in practice because none of the patches touch upstream's hot paths (the `RunEvent::Reopen` gate is the only one that edits an upstream file, and that arm of the match is rarely changed upstream). When a conflict does happen, the auto-update aborts cleanly and waits for a manual resolution.

## Upstream

For everything else, see the upstream README at [coollabsio/jean](https://github.com/coollabsio/jean) and the project site at [jean.build](https://jean.build). All credit for Jean itself goes to Andras Bacsai and the upstream contributors.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=coollabsio/jean&type=Date)](https://star-history.com/#coollabsio/jean&Date)
