#!/usr/bin/env bash
#
# Rebase the local nix branch onto the latest upstream Jean release tag.
#
# Usage:
#   scripts/update-from-release.sh                  # rebase onto latest release
#   scripts/update-from-release.sh v0.1.47          # rebase onto a specific tag
#   scripts/update-from-release.sh --update-flake   # also refresh flake.lock
#   scripts/update-from-release.sh --check          # report status, make no changes
#   scripts/update-from-release.sh --auto           # unattended: abort on conflict instead of pausing
#   scripts/update-from-release.sh --rebuild        # also `bun run tauri build` if we rebased

set -euo pipefail

NIX_BRANCH="${JEAN_NIX_BRANCH:-main}"
REMOTE="${JEAN_REMOTE:-origin}"
REPO="${JEAN_REPO:-coollabsio/jean}"

target_tag=""
update_flake=0
check_only=0
auto_mode=0
rebuild=0

for arg in "$@"; do
  case "$arg" in
    --update-flake) update_flake=1 ;;
    --check)        check_only=1 ;;
    --auto)         auto_mode=1 ;;
    --rebuild)      rebuild=1 ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    v*) target_tag="$arg" ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}
require git
require gh

refresh_flake() {
  if [ ! -f flake.nix ]; then
    echo "no flake.nix in working tree, skipping flake update" >&2
    return
  fi
  require nix
  echo
  echo "refreshing flake.lock..."
  nix flake update
  if [ -n "$(git status --porcelain flake.lock)" ]; then
    git add flake.lock
    git commit -m "nix: refresh flake.lock"
  else
    echo "flake.lock already up to date"
  fi
}

rebuild_app() {
  require nix
  echo
  echo "rebuilding app (bun install + tauri build --no-bundle)..."
  # Run inside the dev shell so PKG_CONFIG_PATH / LD_LIBRARY_PATH / GST_PLUGIN_PATH
  # match what the shellHook sets up.
  # --no-bundle: skip .deb/.rpm/.AppImage packaging. Tauri's bundler hardcodes
  # /usr/bin/xdg-open which doesn't exist on NixOS, and we don't need the
  # artifacts — the ~/.local/bin/jean wrapper exec's the binary directly.
  if ! nix develop -c bash -c 'bun install && bun run tauri build --no-bundle'; then
    echo >&2
    echo "rebuild failed. source is updated but the binary at" >&2
    echo "  src-tauri/target/release/jean" >&2
    echo "is still the previous version. fix the build, then re-run:" >&2
    echo "  nix develop -c bash -c 'bun install && bun run tauri build'" >&2
    return 1
  fi
  if [ ! -x src-tauri/target/release/jean ]; then
    echo "build succeeded but expected binary not found at src-tauri/target/release/jean" >&2
    return 1
  fi
  echo "rebuild done. next launch of ~/.local/bin/jean will use the new binary."
}

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty; commit or stash first" >&2
  git status --short >&2
  exit 1
fi

echo "fetching tags from $REMOTE..."
git fetch --tags "$REMOTE" --quiet

if [ -z "$target_tag" ]; then
  target_tag=$(gh release view --repo "$REPO" --json tagName -q .tagName)
fi

if ! git rev-parse --verify --quiet "refs/tags/$target_tag" >/dev/null; then
  echo "tag not found locally: $target_tag" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "refs/heads/$NIX_BRANCH" >/dev/null; then
  echo "branch not found: $NIX_BRANCH" >&2
  exit 1
fi

target_sha=$(git rev-parse "$target_tag")
branch_base=$(git merge-base "$NIX_BRANCH" "$target_tag" 2>/dev/null || echo "")

echo
echo "  branch:  $NIX_BRANCH"
echo "  target:  $target_tag ($(git rev-parse --short "$target_sha"))"
if [ -n "$branch_base" ]; then
  echo "  base:    $(git rev-parse --short "$branch_base")"
fi

if [ "$branch_base" = "$target_sha" ]; then
  echo
  echo "already up to date with $target_tag"
  if [ "$update_flake" -eq 1 ] && [ "$check_only" -eq 0 ]; then
    git checkout "$NIX_BRANCH" --quiet
    refresh_flake
  fi
  exit 0
fi

if [ "$check_only" -eq 1 ]; then
  echo
  echo "out of date — run without --check to rebase"
  exit 3
fi

echo
echo "rebasing $NIX_BRANCH onto $target_tag..."
git checkout "$NIX_BRANCH" --quiet
if ! git rebase "$target_tag"; then
  if [ "$auto_mode" -eq 1 ]; then
    echo >&2
    echo "rebase hit conflicts; aborting (auto mode)." >&2
    git rebase --abort
    echo "branch left untouched. resolve manually with:" >&2
    echo "  scripts/update-from-release.sh" >&2
    exit 4
  fi
  echo >&2
  echo "rebase hit conflicts. resolve them, then:" >&2
  echo "  git rebase --continue" >&2
  echo "  scripts/update-from-release.sh --update-flake  # if you also wanted a flake bump" >&2
  exit 1
fi

if [ "$update_flake" -eq 1 ]; then
  refresh_flake
fi

rebuild_failed=0
if [ "$rebuild" -eq 1 ]; then
  if ! rebuild_app; then
    rebuild_failed=1
  fi
fi

if [ "$rebuild_failed" -eq 1 ]; then
  # Distinct exit code so systemd can log "rebuilt failed" without conflating
  # with a successful update or a conflict abort.
  exit 5
fi

echo
if [ "$rebuild" -eq 1 ]; then
  echo "done. click the bottom bar icon to launch the new build."
else
  echo "done. smoke-test with:"
  echo "  nix develop -c bash -c 'bun install && bun run tauri dev'"
fi
