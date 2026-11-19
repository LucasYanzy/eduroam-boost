#!/usr/bin/env bash
# eduroam-boost installer for macOS.
#   curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/install.sh | bash
#   ./install.sh [--watch | --watch-auto | --no-watch]
#
#   --watch       also start a background watcher at login that notifies you when Wi-Fi degrades
#   --watch-auto  same, but it reconnects automatically (drops Wi-Fi for a few seconds each time)
#   --no-watch    command only (default when not interactive)
#
# Environment overrides (used by the tests): EDUROAM_BOOST_PREFIX, EDUROAM_BOOST_RAW,
# EDUROAM_BOOST_DRY_RUN=1 (write files but do not touch launchd).
set -euo pipefail

RAW="${EDUROAM_BOOST_RAW:-https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main}"
PREFIX="${EDUROAM_BOOST_PREFIX:-$HOME/.local}"
SHARE="$PREFIX/share/eduroam-boost"
BIN="$PREFIX/bin"
LABEL="io.github.lucasyanzy.eduroam-boost"
AGENTS="${EDUROAM_BOOST_AGENTS:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS/$LABEL.plist"
LOGS="$HOME/Library/Logs/eduroam-boost"
WATCH="ask"

for arg in "$@"; do
  case "$arg" in
    --watch) WATCH="notify" ;;
    --watch-auto) WATCH="auto" ;;
    --no-watch) WATCH="none" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { say "eduroam-boost: this installer is for macOS. Windows: see windows/install.ps1; iPhone/Android: see README."; exit 1; }

PY="$(command -v python3 || true)"
if [ -z "$PY" ] || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
  say "Python 3.8+ is required. Run: xcode-select --install   (then re-run this installer)"
  exit 1
fi

mkdir -p "$SHARE" "$BIN"

SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/eduroam_boost.py" ]; then
  cp "$SRC_DIR/eduroam_boost.py" "$SHARE/eduroam_boost.py"
else
  curl -fsSL "$RAW/eduroam_boost.py" -o "$SHARE/eduroam_boost.py.tmp"
  mv "$SHARE/eduroam_boost.py.tmp" "$SHARE/eduroam_boost.py"
fi
"$PY" -m py_compile "$SHARE/eduroam_boost.py"

# Helper app for survey / seat (needs swiftc from the Xcode Command Line Tools, which python3 needs anyway)
if [ -z "${EDUROAM_BOOST_SKIP_HELPER:-}" ] && command -v swiftc >/dev/null 2>&1; then
  HSRC="$(mktemp -d)"
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/macos-helper/main.swift" ]; then
    cp "$SRC_DIR/macos-helper/main.swift" "$SRC_DIR/macos-helper/build.sh" "$HSRC/"
  else
    curl -fsSL "$RAW/macos-helper/main.swift" -o "$HSRC/main.swift"
    curl -fsSL "$RAW/macos-helper/build.sh" -o "$HSRC/build.sh"
  fi
  if bash "$HSRC/build.sh" "$SHARE" >/dev/null 2>"$HSRC/build.log"; then
    say "✓ helper app built (run 'eduroam-boost authorize' once to enable survey / seat)"
  else
    say "  helper app build failed; survey / seat unavailable (see $HSRC/build.log)"
  fi
else
  say "  swiftc not found: survey / seat unavailable (install with: xcode-select --install)"
fi

cat > "$BIN/eduroam-boost" <<EOF
#!/bin/sh
exec "$PY" "$SHARE/eduroam_boost.py" "\$@"
EOF
chmod +x "$BIN/eduroam-boost"
say "✓ installed: $BIN/eduroam-boost"

if [ "$WATCH" = "ask" ]; then
  WATCH="none"
  if [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
    printf 'Start a background watcher at login? [n] no / [y] notify me / [a] auto-reconnect: ' > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in y|Y) WATCH="notify" ;; a|A) WATCH="auto" ;; esac
  fi
fi

if [ "$WATCH" != "none" ]; then
  mkdir -p "$AGENTS" "$LOGS"
  AUTO_ARG=""
  [ "$WATCH" = "auto" ] && AUTO_ARG="<string>--auto</string>"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$SHARE/eduroam_boost.py</string>
    <string>watch</string>
    $AUTO_ARG
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOGS/watch.log</string>
  <key>StandardErrorPath</key><string>$LOGS/watch.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
  if [ -z "${EDUROAM_BOOST_DRY_RUN:-}" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
  say "✓ background watcher ($WATCH) starts at login; log: $LOGS/watch.log"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "  add to your shell:  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
say "Try:  eduroam-boost status      (uninstall: curl -fsSL $RAW/uninstall.sh | bash)"
