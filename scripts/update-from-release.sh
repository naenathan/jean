#!/usr/bin/env bash
#
# Rebase the local nix branch onto the latest upstream Jean release tag.
#
# Usage:
#   scripts/update-from-release.sh                  # rebase onto latest release
#   scripts/update-from-release.sh v0.1.47          # rebase onto a specific tag
#   scripts/update-from-release.sh --update-flake   # also refresh flake.lock
#   scripts/update-from-release.sh --check          # report status, make no changes

set -euo pipefail

NIX_BRANCH="${JEAN_NIX_BRANCH:-nathan/nixos}"
REMOTE="${JEAN_REMOTE:-origin}"
REPO="${JEAN_REPO:-coollabsio/jean}"

target_tag=""
update_flake=0
check_only=0

for arg in "$@"; do
  case "$arg" in
    --update-flake) update_flake=1 ;;
    --check)        check_only=1 ;;
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
  echo "create it first, then re-run:" >&2
  echo "  git checkout -b $NIX_BRANCH" >&2
  echo "  git add flake.nix flake.lock" >&2
  echo "  git commit -m 'nix: add NixOS dev shell'" >&2
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

refresh_flake() {
  if [ ! -f flake.nix ]; then
    echo "no flake.nix in working tree, skipping flake update" >&2
    return
  fi
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

echo
echo "rebasing $NIX_BRANCH onto $target_tag..."
git checkout "$NIX_BRANCH" --quiet
if ! git rebase "$target_tag"; then
  echo >&2
  echo "rebase hit conflicts. resolve them, then:" >&2
  echo "  git rebase --continue" >&2
  echo "  scripts/update-from-release.sh --update-flake  # if you also wanted a flake bump" >&2
  exit 1
fi

if [ "$update_flake" -eq 1 ]; then
  require nix
  refresh_flake
fi

echo
echo "done. smoke-test with:"
echo "  nix develop -c bash -c 'bun install && bun run tauri dev'"
