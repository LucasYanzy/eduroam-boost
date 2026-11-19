#!/usr/bin/env python3
"""eduroam-boost: get your Mac off a slow 2.4 GHz access point.

On big campus networks (eduroam and friends) a Mac often sticks to a weak
2.4 GHz access point even when the same AP also offers 5/6 GHz. The very first
hop (laptop -> AP) then costs hundreds of milliseconds, and no VPN or
"accelerator" downstream can fix that. macOS has no band selector, but a Wi-Fi
off/on forces a fresh scan, which usually lands on a faster band.

Commands:
  status      current band / signal / first-hop latency, with a diagnosis (default)
  authorize   one-time Location permission for the helper app (needed by survey / seat)
  survey      every access point of this network: band, signal, channel utilization, clients
  seat        live 5 GHz vs 2.4 GHz signal gap while you move, to find a spot where 5 GHz wins
  diagnose    20 s test: is the bottleneck the Wi-Fi hop or the network upstream?
  boost       reconnect Wi-Fi (up to --tries times) until it is on 5/6 GHz and fast
  watch       sample every --interval s; notify (or --auto reconnect) when it degrades
  report      how often boosting helped, and how long the improvement lasted

Only the Python 3 standard library and built-in macOS tools are used.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime, timedelta

VERSION = "0.2.0"
DATA_DIR = os.environ.get("EDUROAM_BOOST_HOME", os.path.expanduser("~/Library/Logs/eduroam-boost"))
SAMPLES = "samples.jsonl"
BOOSTS = "boosts.jsonl"
MAX_LOG_BYTES = 5 * 1024 * 1024

BAD_GW_MS = 100      # average first-hop latency above this counts as "slow"
BAD_LOSS = 10        # first-hop packet loss (%) above this counts as "slow"
BAD_STREAK = 3       # watch: consecutive bad samples before acting
COOLDOWN = 300       # watch --auto: minimum seconds between automatic reconnects
UPSTREAM = "1.1.1.1"


def _zh():
    lang = os.environ.get("EDUROAM_BOOST_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return lang.lower().startswith("zh")


ZH = _zh()


def t(zh, en):
    return zh if ZH else en


# ---------------------------------------------------------------- system access

def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


def wifi_device():
    out = sh(["networksetup", "-listallhardwareports"], 10)
    m = re.search(r"Hardware Port: (?:Wi-Fi|AirPort)\s*\nDevice: (\S+)", out)
    return m.group(1) if m else "en0"


def band_of(channel):
    channel = channel or ""
    if "6GHz" in channel:
        return "6GHz"
    if "5GHz" in channel:
        return "5GHz"
    if "2GHz" in channel:
        return "2.4GHz"
    return "?"


def _dbm(text, which=0):
    nums = re.findall(r"(-\d+) dBm", text or "")
    return int(nums[which]) if len(nums) > which else None


def parse_link(data):
    """Turn `system_profiler SPAirPortDataType -json` output into a small dict.

    SSIDs/BSSIDs are redacted by macOS without Location permission, so "the same
    network on a faster band" is approximated by: a 5/6 GHz network with the same
    security type (eduroam is WPA2/WPA3 Enterprise).
    """
    try:
        interfaces = data["SPAirPortDataType"][0]["spairport_airport_interfaces"]
    except (KeyError, IndexError, TypeError):
        return None
    for itf in interfaces:
        cur = itf.get("spairport_current_network_information")
        if not cur:
            continue
        channel = cur.get("spairport_network_channel", "")
        security = str(cur.get("spairport_security_mode", ""))
        enterprise = "enterprise" in security
        fast = set()
        for n in itf.get("spairport_airport_other_local_wireless_networks", []) or []:
            ch = n.get("spairport_network_channel", "")
            if band_of(ch) in ("5GHz", "6GHz") and (not enterprise or "enterprise" in str(n.get("spairport_security_mode", ""))):
                fast.add(ch)
        rate = cur.get("spairport_network_rate")
        return {
            "band": band_of(channel),
            "channel": channel,
            "rssi": _dbm(cur.get("spairport_signal_noise")),
            "noise": _dbm(cur.get("spairport_signal_noise"), 1),
            "rate": int(rate) if str(rate).isdigit() else None,
            "enterprise": enterprise,
            "fast_nearby": sorted(fast),
        }
    return None


def read_link():
    out = sh(["system_profiler", "SPAirPortDataType", "-json"], 60)
    try:
        return parse_link(json.loads(out))
    except ValueError:
        return None


def gateway():
    m = re.search(r"gateway: (\S+)", sh(["route", "-n", "get", "default"], 5))
    return m.group(1) if m else None


def parse_ping(out):
    """Return (avg_ms or None, loss_percent)."""
    loss = re.search(r"([\d.]+)% packet loss", out or "")
    avg = re.search(r"= [\d.]+/([\d.]+)/", out or "")
    return (round(float(avg.group(1)), 1) if avg else None), (float(loss.group(1)) if loss else 100.0)


def ping(host, count=10, interval="0.2"):
    if not host:
        return None, 100.0
    return parse_ping(sh(["ping", "-c", str(count), "-i", interval, "-W", "1000", host], count + 15))


def measure(count=10):
    link = read_link()
    avg, loss = ping(gateway(), count)
    return {"ts": datetime.now().isoformat(timespec="seconds"), "link": link, "gw_ms": avg, "gw_loss": loss}


# ---------------------------------------------------------------- judgement

def band_hint(s):
    """Advisory only: on 2.4 GHz while a faster band is visible. Not a reason to reconnect by itself,
    because a weak 5 GHz signal can be worse than a decent 2.4 GHz one (seen in real tests)."""
    link = s.get("link") or {}
    if link.get("band") == "2.4GHz" and link.get("fast_nearby"):
        return t("连在 2.4GHz，附近有 5/6GHz 的同类网络", "on 2.4 GHz while a 5/6 GHz network of the same type is nearby")
    return None


def reasons(s):
    """Why a sample counts as slow (empty list = fine). Only measured symptoms count."""
    out = []
    link = s.get("link")
    if not link:
        return [t("没连上 Wi-Fi", "not connected to Wi-Fi")]
    if s.get("gw_ms") is not None and s["gw_ms"] > BAD_GW_MS:  # no answer at all shows up as 100% loss
        out.append(t(f"到路由器平均 {s['gw_ms']:.0f}ms（>{BAD_GW_MS}）", f"first hop averages {s['gw_ms']:.0f} ms (>{BAD_GW_MS})"))
    if s.get("gw_loss", 0) > BAD_LOSS:
        out.append(t(f"到路由器丢包 {s['gw_loss']:.0f}%", f"{s['gw_loss']:.0f}% packet loss on the first hop"))
    return out


def is_bad(s):
    return bool(reasons(s))


def score(s):
    """Lower is better: first-hop latency + loss penalty + 2.4 GHz penalty."""
    link = s.get("link")
    if not link or s.get("gw_ms") is None:
        return 1e9
    return s["gw_ms"] + s.get("gw_loss", 0) * 20 + (50 if link["band"] == "2.4GHz" else 0)


def describe(s):
    link = s.get("link")
    if not link:
        return t("未连接", "disconnected")
    gw = "—" if s.get("gw_ms") is None else f"{s['gw_ms']:.0f}ms"
    rate = f"{link['rate']}Mbps" if link.get("rate") else "—Mbps"  # macOS reports 0 right after (re)joining
    return f"{link['band']} {link['rssi']}dBm {rate} | " + t(f"路由器 {gw} 丢包 {s['gw_loss']:.0f}%", f"router {gw} loss {s['gw_loss']:.0f}%")


# ---------------------------------------------------------------- storage

def path(name):
    return os.path.join(DATA_DIR, name)


def append(name, obj):
    os.makedirs(DATA_DIR, exist_ok=True)
    p = path(name)
    with open(p, "a") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + "\n")
    if os.path.getsize(p) > MAX_LOG_BYTES:  # keep the newest half
        with open(p) as fh:
            lines = fh.readlines()
        with open(p, "w") as fh:
            fh.writelines(lines[len(lines) // 2:])


def load(name, since=None):
    rows = []
    try:
        with open(path(name)) as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if since is None or datetime.fromisoformat(row["ts"]) >= since:
                    rows.append(row)
    except FileNotFoundError:
        pass
    return rows


# ---------------------------------------------------------------- access-point survey (helper app)
#
# macOS only reveals network names, BSSIDs and the APs' advertised load to apps with Location
# permission, so a tiny helper app (macos-helper/) does the scanning. We talk to it through files.

CLOSE_DB = 4        # a 5/6 GHz AP within this many dB of the current one: macOS may pick it on reconnect
BUSY_PCT = 70       # channel utilization at or above this counts as congested


def helper_app():
    here = os.path.dirname(os.path.realpath(__file__))
    for cand in (os.environ.get("EDUROAM_BOOST_HELPER"), os.path.join(here, "eduroam-boost-helper.app"),
                 os.path.join(here, "build", "eduroam-boost-helper.app")):
        if cand and os.path.isdir(cand):
            return cand
    return None


def helper(command, *extra, timeout=90):
    """Run one helper command and return its JSON output (dict), or None if unavailable."""
    app = helper_app()
    if not app:
        return None
    import tempfile
    fd, out = tempfile.mkstemp(prefix="eduroam-boost-", suffix=".json")
    os.close(fd)
    os.unlink(out)
    try:
        sh(["open", "-n", app, "--args", command, *extra, "--out", out], 15)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(out) and os.path.getsize(out) > 0:
                time.sleep(0.1)
                with open(out) as fh:
                    return json.load(fh)
            time.sleep(0.25)
        return None
    except ValueError:
        return None
    finally:
        if os.path.exists(out):
            os.unlink(out)


def helper_watch(interval=4, duration=600):
    """Yield one scan dict at a time from the helper's streaming mode."""
    app = helper_app()
    if not app:
        return
    import tempfile
    fd, out = tempfile.mkstemp(prefix="eduroam-boost-watch-", suffix=".jsonl")
    os.close(fd)
    os.unlink(out)
    sh(["open", "-n", app, "--args", "watch", "--interval", str(interval), "--duration", str(duration), "--out", out], 15)
    pos = 0
    try:
        deadline = time.time() + duration + 30
        while time.time() < deadline:
            if os.path.exists(out):
                with open(out) as fh:
                    fh.seek(pos)
                    chunk = fh.read()
                    complete = chunk[:chunk.rfind("\n") + 1]
                    pos += len(complete.encode())
                for line in complete.splitlines():
                    try:
                        yield json.loads(line)
                    except ValueError:
                        pass
            time.sleep(0.5)
    finally:
        open(out + ".stop", "w").close()


def analyze(scan):
    """Pure function: what does the scan say about the current connection? Returns a dict."""
    if not scan or not (scan.get("current") or {}).get("ssid"):
        return {"verdict": "no_names"}
    cur = scan["current"]
    aps = [n for n in scan.get("networks", []) if n.get("ssid") == cur["ssid"]]
    here = next((n for n in aps if n.get("bssid") == cur.get("bssid")), None)
    fast = [n for n in aps if n.get("band") in ("5GHz", "6GHz")]
    best_fast = max(fast, key=lambda n: n["rssi"], default=None)
    util = ((here or {}).get("load") or {}).get("utilization_pct")
    out = {"ssid": cur["ssid"], "band": cur.get("band"), "rssi": cur.get("rssi"), "channel": cur.get("channel"),
           "util": util, "stations": ((here or {}).get("load") or {}).get("stations"),
           "busy": util is not None and util >= BUSY_PCT, "aps": aps, "best_fast": best_fast, "gap": None}
    if cur.get("band") in ("5GHz", "6GHz"):
        out["verdict"] = "on_fast"
    elif not best_fast:
        out["verdict"] = "no_fast"
    else:
        out["gap"] = best_fast["rssi"] - cur["rssi"]
        out["verdict"] = "fast_close" if out["gap"] >= -CLOSE_DB else "fast_weak"
    return out


def explain(a):
    """One or two human sentences for an analysis."""
    v = a["verdict"]
    if v == "no_names":
        return t("看不到热点详情：先运行 eduroam-boost authorize 授权定位（只用来读取热点名称和负载）。",
                 "Access-point details hidden: run `eduroam-boost authorize` once (Location is only used to read AP names and load).")
    busy = t(f"当前信道占用 {a['util']}%", f"current channel {a['util']}% busy") if a.get("util") is not None else ""
    if v == "on_fast":
        return t(f"已经在 {a['band']} 上了。", f"Already on {a['band']}.") + (f" {busy}" if busy else "")
    if v == "no_fast":
        return t("附近没有这个网络的 5/6GHz 热点，换频段这条路走不通。", "No 5/6 GHz AP of this network nearby; switching bands is not an option here.")
    bf = a["best_fast"]
    load = (bf.get("load") or {})
    bf_desc = f"{bf['band']} ch{bf['channel']} {bf['rssi']}dBm" + (t(f"，占用 {load['utilization_pct']}%", f", {load['utilization_pct']}% busy") if "utilization_pct" in load else "")
    if v == "fast_close":
        return t(f"{bf_desc}，只比现在弱 {-a['gap']} dB：重连很可能换过去，运行 eduroam-boost boost。",
                 f"{bf_desc}, only {-a['gap']} dB weaker: a reconnect will likely switch to it. Run `eduroam-boost boost`.") + (f" ({busy})" if busy else "")
    return t(f"{bf_desc}，比现在弱 {-a['gap']} dB：重连 Mac 也不会换过去。用 eduroam-boost seat 找一个 5GHz 更强的位置。",
             f"{bf_desc}, {-a['gap']} dB weaker: macOS won't switch to it. Use `eduroam-boost seat` to find a spot where it is stronger.") + (f" ({busy})" if busy else "")


def survey():
    return analyze(helper("scan")) if helper_app() else None


# ---------------------------------------------------------------- actions

def reconnect(device, wait=40):
    """Wi-Fi off -> on, then wait until the default gateway answers (802.1X takes a few seconds)."""
    sh(["networksetup", "-setairportpower", device, "off"], 15)
    time.sleep(3)
    sh(["networksetup", "-setairportpower", device, "on"], 15)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(1)
        avg, _ = ping(gateway(), 1)
        if avg is not None:
            return True
    return False


def notify(title, msg):
    msg = msg.replace('"', "'")
    sh(["osascript", "-e", f'display notification "{msg}" with title "{title}"'], 10)


def do_boost(tries=3, force=False, trigger="manual", verbose=True, use_survey=True):
    say = print if verbose else (lambda *a, **k: None)
    device = wifi_device()
    before = measure()
    say(t("重连前: ", "before: ") + describe(before))
    an = survey() if use_survey else None
    if an and an["verdict"] != "no_names":
        say(t("热点: ", "APs:   ") + explain(an))
    if an and an["verdict"] == "fast_weak" and not force:
        say(t("不重连：重连了也还是这台 2.4GHz（加 --force 仍可强制）。", "Not reconnecting: it would land on the same 2.4 GHz AP (use --force anyway)."))
        return before, before, False
    want_fast = bool(an and an["verdict"] == "fast_close")
    worth = is_bad(before) or (want_fast and an["busy"])
    if not force and not worth:
        say(t("现在已经不错了，不需要重连（加 --force 强制）。", "Already good, nothing to do (use --force to reconnect anyway)."))
        return before, before, True

    def good(s):
        return not is_bad(s) and (not want_fast or (s.get("link") or {}).get("band") in ("5GHz", "6GHz"))

    best = before
    attempts = 0
    for i in range(1, tries + 1):
        attempts = i
        say(t(f"第 {i} 次重连 Wi-Fi（会断网几秒）…", f"reconnect #{i} (Wi-Fi drops for a few seconds)…"), flush=True)
        if not reconnect(device):
            say(t("  40 秒内没连回来", "  did not come back within 40 s"))
            continue
        time.sleep(2)
        after = measure()
        say("  " + describe(after))
        if score(after) < score(best):
            best = after
        if good(after):
            break
    ok = good(best)
    append(BOOSTS, {"ts": before["ts"], "trigger": trigger, "tries": attempts, "success": ok, "before": before, "after": best})
    if ok:
        say(t(f"成功: {describe(best)}", f"done: {describe(best)}"))
    elif want_fast and not is_bad(best):
        say(t("没换到 5/6GHz（Mac 还是选了信号更强的 2.4GHz），延迟本身还可以。用 eduroam-boost seat 找个 5GHz 更强的位置。",
              "Did not switch to 5/6 GHz (macOS kept the stronger 2.4 GHz AP); latency is OK. Use `eduroam-boost seat` to find a better spot."))
    else:
        say(t("还是慢：这里 5GHz 信号太弱或 AP 太挤，软件帮不上了。用 eduroam-boost seat 找位置、用手机热点或插网线。",
              "Still slow: the faster band is too weak here or the AP is overloaded. Try `eduroam-boost seat`, tethering, or Ethernet."))
    return before, best, ok


# ---------------------------------------------------------------- commands

def cmd_status(args):
    s = measure()
    link = s["link"]
    if not link:
        print(t("没连上 Wi-Fi", "Not connected to Wi-Fi"))
        return 1
    print(t("频段", "Band") + f"     {link['band']}   {link['channel']}")
    print(t("信号", "Signal") + f"   {link['rssi']} dBm" + (t(f"（噪声 {link['noise']} dBm）", f" (noise {link['noise']} dBm)") if link["noise"] else ""))
    print(t("速率", "Rate") + f"     {link['rate'] or '—'} Mbps")
    gw = "—" if s["gw_ms"] is None else f"{s['gw_ms']:.0f} ms"
    print(t("到路由器", "Router") + f" {gw}, " + t(f"丢包 {s['gw_loss']:.0f}%", f"loss {s['gw_loss']:.0f}%"))
    if link["fast_nearby"]:
        print(t("附近 5/6GHz 同类网络: ", "Faster same-type networks nearby: ") + ", ".join(link["fast_nearby"]))
    a = survey()
    if a and a["verdict"] != "no_names":
        here = t(f"这台 AP: 信道占用 {a['util']}%，{a['stations']} 台设备", f"This AP: {a['util']}% channel busy, {a['stations']} clients") if a.get("util") is not None else ""
        if here:
            print(here)
        print(t("热点: ", "APs: ") + explain(a))
    r = reasons(s)
    hint = band_hint(s)
    if r:
        print("\n" + t("诊断: 连接差 — ", "Diagnosis: slow — ") + "; ".join(r + ([hint] if hint else [])))
        if a and a["verdict"] == "fast_weak":
            print(t("建议: eduroam-boost seat（这里重连换不到 5GHz）", "Try:  eduroam-boost seat (reconnecting won't reach 5 GHz here)"))
        else:
            print(t("建议: eduroam-boost boost", "Try:  eduroam-boost boost"))
    elif hint:
        print("\n" + t(f"诊断: 延迟正常（{hint}，但现在不需要处理）", f"Diagnosis: fine ({hint}, but nothing to fix right now)"))
    else:
        print("\n" + t("诊断: 正常", "Diagnosis: fine"))
    if args.json:
        print(json.dumps(s, ensure_ascii=False))
    return 0


def cmd_diagnose(args):
    gw = gateway()
    print(t(f"同时测 20 秒：路由器 {gw} 和外网 {UPSTREAM} …", f"Testing for 20 s: router {gw} and upstream {UPSTREAM} …"), flush=True)
    procs = [subprocess.Popen(["ping", "-c", "20", "-i", "1", "-W", "1000", h], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
             for h in (gw, UPSTREAM) if h]
    outs = [p.communicate(timeout=60)[0] for p in procs]
    (g_avg, g_loss), (u_avg, u_loss) = (parse_ping(outs[0]) if gw else (None, 100.0)), parse_ping(outs[-1])
    print(t("路由器", "router  ") + f" avg {g_avg} ms, loss {g_loss:.0f}%")
    print(t("外网  ", "upstream") + f" avg {u_avg} ms, loss {u_loss:.0f}%")
    if g_avg is None or g_avg > 50 or g_loss > 5:
        print(t("结论: 瓶颈是 Wi-Fi 这一跳 → boost 有用。", "Verdict: the Wi-Fi hop is the bottleneck → boost can help."))
    elif u_avg is None or u_loss > 5 or u_avg - g_avg > 150:
        print(t("结论: Wi-Fi 正常，慢在学校出口/运营商 → boost 帮不上。", "Verdict: Wi-Fi is fine, the network upstream is slow → boost won't help."))
    else:
        print(t("结论: 网络正常。", "Verdict: network looks fine."))
    return 0


def cmd_boost(args):
    _, _, ok = do_boost(args.tries, args.force)
    return 0 if ok else 2


def cmd_watch(args):
    print(t(f"开始监控：每 {args.interval} 秒一次，{'自动重连' if args.auto else '只提醒'}。日志: {DATA_DIR}",
            f"Watching every {args.interval} s ({'auto-reconnect' if args.auto else 'notify only'}). Logs: {DATA_DIR}"), flush=True)
    streak, last_fix = 0, 0.0
    while True:
        s = measure(5)
        bad = is_bad(s)
        append(SAMPLES, {**s, "bad": bad})
        print(s["ts"][11:], describe(s), "⚠️" if bad else "", flush=True)
        streak = streak + 1 if bad else 0
        if streak >= BAD_STREAK:
            streak = 0
            if args.auto and time.time() - last_fix > COOLDOWN:
                last_fix = time.time()
                do_boost(args.tries, trigger="auto", verbose=False)
            elif not args.auto:
                notify("eduroam-boost", t("Wi-Fi 变慢了（" + "；".join(reasons(s)) + "）。运行 eduroam-boost boost",
                                          "Wi-Fi is slow (" + "; ".join(reasons(s)) + "). Run: eduroam-boost boost"))
        time.sleep(args.interval)


def summarize(samples, boosts):
    """Pure function so it can be unit tested. Returns a dict of stats."""
    out = {"samples": len(samples), "bands": {}, "latency": {}, "boosts": [], "bad_share": None}
    if samples:
        for s in samples:
            b = (s.get("link") or {}).get("band", "offline")
            out["bands"][b] = out["bands"].get(b, 0) + 1
            if s.get("gw_ms") is not None:
                out["latency"].setdefault(b, []).append(s["gw_ms"])
        out["latency"] = {b: {"median": statistics.median(v), "p90": sorted(v)[int(0.9 * (len(v) - 1))]} for b, v in out["latency"].items()}
        out["bad_share"] = sum(1 for s in samples if s.get("bad")) / len(samples)
    for b in boosts:
        start = datetime.fromisoformat(b["ts"])
        later = [s for s in samples if datetime.fromisoformat(s["ts"]) > start + timedelta(seconds=30)]
        lasted, held = None, None
        if b.get("success") and later:
            fallback = next((s for s in later if s.get("bad")), None)
            if fallback:
                lasted, held = (datetime.fromisoformat(fallback["ts"]) - start).total_seconds() / 60, False
            else:
                lasted, held = (datetime.fromisoformat(later[-1]["ts"]) - start).total_seconds() / 60, True
        out["boosts"].append({
            "ts": b["ts"], "trigger": b.get("trigger"), "success": b.get("success"), "tries": b.get("tries"),
            "before": b["before"].get("gw_ms"), "after": b["after"].get("gw_ms"),
            "band_before": (b["before"].get("link") or {}).get("band"), "band_after": (b["after"].get("link") or {}).get("band"),
            "lasted_min": None if lasted is None else round(lasted, 1), "still_good": held,
        })
    return out


def cmd_report(args):
    since = datetime.now() - timedelta(hours=args.hours)
    r = summarize(load(SAMPLES, since), load(BOOSTS, since))
    print(t(f"最近 {args.hours} 小时", f"Last {args.hours} h"))
    if r["samples"]:
        total = r["samples"]
        bands = ", ".join(f"{b} {100 * n / total:.0f}%" for b, n in sorted(r["bands"].items(), key=lambda x: -x[1]))
        print(t(f"  监控样本 {total} 个；频段占比: {bands}；连接差的时间 {100 * r['bad_share']:.0f}%",
                f"  {total} samples; time per band: {bands}; slow {100 * r['bad_share']:.0f}% of the time"))
        for b, v in r["latency"].items():
            print(t(f"  {b} 到路由器: 中位数 {v['median']:.0f}ms，90% 分位 {v['p90']:.0f}ms",
                    f"  {b} first hop: median {v['median']:.0f} ms, p90 {v['p90']:.0f} ms"))
    else:
        print(t("  没有监控数据（运行 eduroam-boost watch，或安装时开启后台监控）", "  no watch data (run `eduroam-boost watch` or enable it at install)"))
    if not r["boosts"]:
        print(t("  没有 boost 记录", "  no boosts recorded"))
        return 0
    wins = sum(1 for b in r["boosts"] if b["success"])
    print(t(f"  boost {len(r['boosts'])} 次，成功 {wins} 次", f"  {len(r['boosts'])} boosts, {wins} succeeded"))
    for b in r["boosts"][-10:]:
        line = f"   {b['ts'][5:16]} [{b['trigger']}] {b['band_before']} {b['before']}ms → {b['band_after']} {b['after']}ms"
        if b["lasted_min"] is not None:
            line += t(f"  保持 {b['lasted_min']} 分钟{'（至今）' if b['still_good'] else '后又变差'}",
                      f"  held {b['lasted_min']} min{' (so far)' if b['still_good'] else ' before degrading'}")
        print(line + ("" if b["success"] else t("  ❌ 未改善", "  ❌ no improvement")))
    return 0


def cmd_authorize(args):
    if not helper_app():
        print(t("没找到辅助 App。重新运行安装脚本（需要 Xcode 命令行工具：xcode-select --install）。",
                "Helper app not found. Re-run the installer (needs Xcode Command Line Tools: xcode-select --install)."))
        return 1
    print(t("会弹出定位授权窗口，请点「允许」。只用来读取热点名称和负载，不读取位置。",
            "A Location prompt will appear; click Allow. It is only used to read AP names and load, never your location."), flush=True)
    r = helper("authorize", timeout=200) or {}
    if r.get("location") == "authorized":
        print(t("已授权。现在可以用 eduroam-boost survey 和 seat 了。", "Authorized. `eduroam-boost survey` and `seat` are ready."))
        return 0
    print(t("没有授权。可以在「系统设置 → 隐私与安全性 → 定位服务」里打开 eduroam-boost。",
            "Not authorized. You can enable eduroam-boost in System Settings → Privacy & Security → Location Services."))
    return 3


def ap_row(n, current_bssid=None):
    load = n.get("load") or {}
    util = f"{load['utilization_pct']}%" if "utilization_pct" in load else "—"
    sta = str(load["stations"]) if "stations" in load else "—"
    mark = t("  ← 当前", "  ← current") if current_bssid and n.get("bssid") == current_bssid else ""
    return f"  {n['band']:>6} {n['channel']:>4} {str(n['width_mhz']) + 'MHz':>7} {n['rssi']:>5} dBm {util:>6} {sta:>5}{mark}"


def cmd_survey(args):
    if not helper_app():
        return cmd_authorize(args)
    scan = helper("scan")
    a = analyze(scan)
    if a["verdict"] == "no_names":
        print(explain(a))
        return 3
    cur = scan["current"]
    rows = a["aps"] if not args.all else [n for n in scan["networks"] if n.get("ssid")]
    print(t(f"网络 {a['ssid']}：附近 {len(a['aps'])} 个热点", f"Network {a['ssid']}: {len(a['aps'])} access points nearby"))
    print(t("    频段 信道    带宽    信号       占用  设备", "    band   ch   width  signal      busy   sta"))
    for n in sorted(rows, key=lambda n: (n.get("ssid") != a["ssid"], -n["rssi"])):
        prefix = "" if n.get("ssid") == a["ssid"] else f"  [{n['ssid']}]"
        print(ap_row(n, cur.get("bssid")) + prefix)
    print("\n" + explain(a))
    if args.json:
        print(json.dumps(a, ensure_ascii=False))
    return 0


def seat_line(a, width=20):
    """Pure function: one status line for seat mode."""
    if a["verdict"] == "no_names":
        return explain(a)
    if a["verdict"] == "on_fast":
        util = f" {a['util']}%" if a.get("util") is not None else ""
        return t(f"已在 {a['band']} ({a['rssi']}dBm{util})，就是这里", f"on {a['band']} ({a['rssi']}dBm{util}), this spot works")
    if a["verdict"] == "no_fast":
        return t(f"2.4GHz {a['rssi']}dBm，附近看不到 5/6GHz", f"2.4GHz {a['rssi']}dBm, no 5/6 GHz in range")
    gap = a["gap"]
    filled = max(0, min(width, round((gap + 15) / 20 * width)))      # -15 dB .. +5 dB
    bar = "█" * filled + "·" * (width - filled)
    bf = a["best_fast"]
    head = f"2.4GHz {a['rssi']} | {bf['band']} ch{bf['channel']} {bf['rssi']} | {gap:+d} dB [{bar}] "
    if gap >= 0:
        return head + t("5GHz 够强了，运行 eduroam-boost boost", "5 GHz is strong enough: run eduroam-boost boost")
    if gap >= -CLOSE_DB:
        return head + t(f"接近了，再强 {-gap} dB 更稳", f"close; {-gap} dB more to be sure")
    return head + t(f"还差 {-gap} dB，往 AP 方向挪", f"{-gap} dB short; move towards the AP")


def cmd_seat(args):
    if not helper_app():
        return cmd_authorize(args)
    print(t("找座位模式：拿着电脑慢慢换位置，看 5GHz 和 2.4GHz 的信号差。Ctrl+C 结束。",
            "Seat finder: move around with the laptop and watch the 5 GHz vs 2.4 GHz gap. Ctrl+C to stop."), flush=True)
    for scan in helper_watch(args.interval, args.minutes * 60):
        a = analyze(scan)
        print(datetime.now().strftime("%H:%M:%S ") + seat_line(a), flush=True)
        if a["verdict"] == "no_names":
            return 3
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="eduroam-boost", description=__doc__.split("\n\n")[0])
    p.add_argument("--version", action="version", version=VERSION)
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("status")
    s.add_argument("--json", action="store_true")
    sub.add_parser("diagnose")
    b = sub.add_parser("boost")
    b.add_argument("--tries", type=int, default=3)
    b.add_argument("--force", action="store_true")
    w = sub.add_parser("watch")
    w.add_argument("--interval", type=int, default=30)
    w.add_argument("--auto", action="store_true")
    w.add_argument("--tries", type=int, default=2)
    sub.add_parser("authorize")
    sv = sub.add_parser("survey")
    sv.add_argument("--all", action="store_true")
    sv.add_argument("--json", action="store_true")
    st = sub.add_parser("seat")
    st.add_argument("--interval", type=int, default=4)
    st.add_argument("--minutes", type=int, default=10)
    r = sub.add_parser("report")
    r.add_argument("--hours", type=float, default=24)
    args = p.parse_args(argv)
    if sys.platform != "darwin":
        print(t("这个命令行工具只支持 macOS；iPhone/Android 见 README。", "This CLI is macOS-only; see the README for iPhone/Android."))
        return 1
    handlers = {"status": cmd_status, "diagnose": cmd_diagnose, "boost": cmd_boost, "watch": cmd_watch, "report": cmd_report,
                "authorize": cmd_authorize, "survey": cmd_survey, "seat": cmd_seat}
    if not args.cmd:
        args = p.parse_args(["status"])
    try:
        return handlers[args.cmd](args)
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())
