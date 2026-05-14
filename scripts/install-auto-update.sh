#!/usr/bin/env bash
# Install a systemd user timer that runs scripts/update-from-release.sh daily at 8 AM.
# This is the NixOS equivalent of registering a cron job.
#
# Usage: scripts/install-auto-update.sh                # install or refresh
#        scripts/install-auto-update.sh --uninstall    # remove timer + service
#        scripts/install-auto-update.sh --status       # show timer state and recent log
#
# Env overrides (set before running):
#   JEAN_NIX_BRANCH   branch holding your local nix patches (default: main)
#   JEAN_REMOTE       git remote to fetch release tags from (default: origin;
#                     set to "upstream" if origin points at your fork)
#   JEAN_TIMER_TIME   when to fire, systemd OnCalendar format (default: *-*-* 08:00:00)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SCRIPT="$REPO_DIR/scripts/update-from-release.sh"

UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/jean-release-check.service"
TIMER="$UNIT_DIR/jean-release-check.timer"
STATE_DIR="$HOME/.local/state/jean"
LOG_FILE="$STATE_DIR/release-check.log"

NIX_BRANCH="${JEAN_NIX_BRANCH:-main}"
REMOTE="${JEAN_REMOTE:-origin}"
ON_CALENDAR="${JEAN_TIMER_TIME:-*-*-* 08:00:00}"

mode="install"
for arg in "${@:-}"; do
  case "$arg" in
    --uninstall) mode="uninstall" ;;
    --status)    mode="status" ;;
    "")          ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
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

case "$mode" in
  status)
    require systemctl
    echo "=== timer ==="
    systemctl --user list-timers jean-release-check.timer --no-pager 2>/dev/null \
      || echo "(timer not installed)"
    echo
    echo "=== last 20 log lines ($LOG_FILE) ==="
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
    exit 0
    ;;

  uninstall)
    require systemctl
    systemctl --user disable --now jean-release-check.timer 2>/dev/null || true
    rm -f "$SERVICE" "$TIMER"
    systemctl --user daemon-reload
    echo "removed:"
    echo "  $SERVICE"
    echo "  $TIMER"
    echo "(log file at $LOG_FILE left in place; rm -f it yourself if you want)"
    exit 0
    ;;
esac

# --- install ---

require systemctl
require git
require gh

if [[ ! -x "$UPDATE_SCRIPT" ]]; then
  echo "error: $UPDATE_SCRIPT not found or not executable." >&2
  echo "       run from a checkout of the Jean repo." >&2
  exit 1
fi

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "error: no systemd --user session detected." >&2
  echo "       are you logged in via a session manager (gdm/sddm/sshd with PAM)?" >&2
  exit 1
fi

mkdir -p "$UNIT_DIR" "$STATE_DIR"

echo "==> writing $SERVICE"
cat > "$SERVICE" <<EOF
[Unit]
Description=Auto-update Jean: rebase to latest release, refresh flake, rebuild app
Documentation=https://github.com/coollabsio/jean

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=JEAN_NIX_BRANCH=$NIX_BRANCH
Environment=JEAN_REMOTE=$REMOTE
# --auto         : abort cleanly on rebase conflict (never leaves repo mid-rebase)
# --update-flake : also run \`nix flake update\` and commit the result
# --rebuild      : \`bun install && bun run tauri build --no-bundle\` after successful rebase
# Exit codes:
#   0 = success or already up to date (no rebuild needed)
#   4 = conflict, rebase aborted, branch untouched
#   5 = rebase OK but build failed (source updated, binary stale)
#   other = error before any state change
ExecStart=/usr/bin/env bash -c '$UPDATE_SCRIPT --auto --update-flake --rebuild >> $LOG_FILE 2>&1; rc=\$?; echo "[\$(date -Iseconds)] exit=\$rc" >> $LOG_FILE; exit \$rc'
SuccessExitStatus=0 4 5
# Builds can take a while on a cold cache; budget for it.
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle
EOF

echo "==> writing $TIMER"
cat > "$TIMER" <<EOF
[Unit]
Description=Daily auto-update of Jean from upstream release tag

[Timer]
OnCalendar=$ON_CALENDAR
# Catch up at next login if the machine was off when the timer should have fired.
Persistent=true
# Stagger so the timer doesn't fire at exactly the same instant every day.
RandomizedDelaySec=120
Unit=jean-release-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> reloading systemd user units and enabling timer"
systemctl --user daemon-reload
systemctl --user enable --now jean-release-check.timer >/dev/null

echo
echo "installed."
echo "  service:  $SERVICE"
echo "  timer:    $TIMER"
echo "  log:      $LOG_FILE"
echo "  schedule: $ON_CALENDAR  (±120s jitter)"
echo "  branch:   $NIX_BRANCH"
echo "  remote:   $REMOTE"
echo

# --- sanity checks ---

if ! git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$NIX_BRANCH" >/dev/null; then
  echo "warning: branch '$NIX_BRANCH' does not exist yet."
  echo "         the timer will run but bail out with 'branch not found' until you create it:"
  echo
  echo "         git -C $REPO_DIR checkout -b $NIX_BRANCH"
  echo "         # then stage your local nix patches and commit"
  echo
fi

linger=$(loginctl show-user "$USER" 2>/dev/null | sed -n 's/^Linger=//p' || echo "")
if [[ "$linger" != "yes" ]]; then
  echo "note: lingering is disabled. user timers only fire while you have an active session."
  echo "      to run even when no session is open:"
  echo
  echo "      sudo loginctl enable-linger \$USER"
  echo
fi

next=$(systemctl --user list-timers jean-release-check.timer --no-pager 2>/dev/null \
       | awk 'NR==2 { for (i=1;i<=4;i++) printf "%s ", $i; print "" }' \
       || echo "")
if [[ -n "$next" ]]; then
  echo "next run: $next"
fi
echo
echo "useful commands:"
echo "  scripts/install-auto-update.sh --status   # peek at timer + log"
echo "  systemctl --user start jean-release-check.service  # run it now"
echo "  journalctl --user -u jean-release-check.service -n 50"
echo "  scripts/install-auto-update.sh --uninstall"
