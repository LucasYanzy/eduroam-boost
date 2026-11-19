#!/usr/bin/env bash
# Remove eduroam-boost from macOS. Add --purge to also delete its logs.
set -euo pipefail
PREFIX="${EDUROAM_BOOST_PREFIX:-$HOME/.local}"
LABEL="io.github.lucasyanzy.eduroam-boost"
AGENTS="${EDUROAM_BOOST_AGENTS:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS/$LABEL.plist"

if [ -z "${EDUROAM_BOOST_DRY_RUN:-}" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi
rm -f "$PLIST" "$PREFIX/bin/eduroam-boost"
rm -rf "$PREFIX/share/eduroam-boost"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/Library/Logs/eduroam-boost"
fi
echo "✓ eduroam-boost removed"
