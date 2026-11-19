#!/usr/bin/env bash
# A/B test: does turning off AWDL (AirDrop / Handoff radio) reduce Wi-Fi latency spikes?
# Alternates AWDL on/off in 4 rounds of 30 s, pinging the default gateway every 0.2 s.
# AWDL is always turned back on at the end, even on Ctrl+C. Needs sudo for `ifconfig awdl0`.
set -euo pipefail

ROUNDS=(on off on off)
COUNT=150                       # 150 x 0.2 s = 30 s per round
OUT_DIR="$HOME/Library/Logs/eduroam-boost"
OUT="$OUT_DIR/awdl-test-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$OUT_DIR"

restore() { sudo ifconfig awdl0 up 2>/dev/null || true; }
trap restore EXIT INT TERM

GW="$(route -n get default | awk '/gateway/{print $2}')"
[ -n "$GW" ] || { echo "no default gateway (not connected?)"; exit 1; }

echo "Gateway $GW. Asking for your password once (to toggle awdl0)…"
sudo -v

{
  echo "# awdl A/B test $(date)  gateway=$GW"
  for i in "${!ROUNDS[@]}"; do
    state="${ROUNDS[$i]}"
    if [ "$state" = off ]; then sudo ifconfig awdl0 down; else sudo ifconfig awdl0 up; fi
    sleep 2
    echo "## round $((i + 1)) awdl=$state"
    ping -c "$COUNT" -i 0.2 "$GW" | grep -E "time=|packet loss" || true
  done
} > "$OUT" 2>&1 &
PID=$!
for i in "${!ROUNDS[@]}"; do echo "  round $((i + 1))/4: AWDL ${ROUNDS[$i]} (30 s)"; sleep 32; done
wait "$PID"
restore

python3 -I - "$OUT" <<'EOF'
import re, sys, statistics
text = open(sys.argv[1]).read()
rounds = re.split(r"^## ", text, flags=re.M)[1:]
agg = {"on": [], "off": []}
lost = {"on": 0, "off": 0}
print(f"\n{'round':<14}{'p50':>7}{'p90':>7}{'p99':>7}{'max':>8}{'>50ms':>7}{'>100ms':>8}{'loss':>7}")
for r in rounds:
    head, body = r.split("\n", 1)
    state = head.split("awdl=")[1].strip()
    ts = [float(x) for x in re.findall(r"time=([\d.]+)", body)]
    loss = re.search(r"([\d.]+)% packet loss", body)
    if not ts:
        continue
    agg[state] += ts
    q = lambda p: sorted(ts)[int(p * (len(ts) - 1))]
    print(f"{head:<14}{q(.5):>7.1f}{q(.9):>7.1f}{q(.99):>7.1f}{max(ts):>8.1f}{sum(t > 50 for t in ts):>7}{sum(t > 100 for t in ts):>8}{(loss.group(1) if loss else '?'):>6}%")
print()
for state in ("on", "off"):
    ts = agg[state]
    if ts:
        q = lambda p: sorted(ts)[int(p * (len(ts) - 1))]
        print(f"AWDL {state:<4} total: n={len(ts)}  p50={q(.5):.1f}  p90={q(.9):.1f}  p99={q(.99):.1f}  max={max(ts):.1f}  spikes>50ms={100 * sum(t > 50 for t in ts) / len(ts):.1f}%")
print(f"\nraw data: {sys.argv[1]}")
EOF
echo "AWDL is back on."
