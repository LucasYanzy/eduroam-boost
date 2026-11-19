#!/usr/bin/env python3
"""wifiboost: 把 Mac 从慢的 2.4GHz 热点“踢”到 5GHz/6GHz 上。

eduroam 慢，多半是 Mac 黏在了信号弱的 2.4GHz 热点上不肯换（sticky client），
连路由器这一跳就要几百毫秒。macOS 不能手动选频段，但断开重连会让它重新扫描，
常常就能换到同一台 AP 的 5GHz/6GHz。这个工具自动做这件事，并且量化前后对比。

用法:
  python3 wifiboost.py            # 看当前状况，给出诊断
  python3 wifiboost.py boost      # 重连 Wi-Fi，最多试 3 次，直到上了 5/6GHz 且延迟变好
  python3 wifiboost.py watch      # 常驻：一旦又掉回 2.4GHz 或变卡就弹通知提醒
  python3 wifiboost.py watch --auto  # 常驻并自动重连（重连会断网几秒，进行中的下载/Codex 会中断）
"""
import json
import re
import subprocess
import sys
import time

IFACE = "en0"
BAD_GW_MS = 100      # 到路由器平均超过这个就算卡
COOLDOWN = 300       # watch --auto 两次自动重连之间至少隔多少秒


def sh(cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


def link():
    """当前频段、信号、速率，以及周围有没有 5/6GHz 的企业网络（eduroam 一般是 WPA2 企业级）。"""
    try:
        data = json.loads(sh(["system_profiler", "SPAirPortDataType", "-json"], 60))
    except Exception:
        return None
    for itf in data["SPAirPortDataType"][0].get("spairport_airport_interfaces", []):
        cur = itf.get("spairport_current_network_information")
        if not cur:
            continue
        ch = cur.get("spairport_network_channel", "")
        sig = cur.get("spairport_signal_noise", "")
        band = "6GHz" if "6GHz" in ch else "5GHz" if "5GHz" in ch else "2.4GHz" if "2GHz" in ch else "?"
        rssi = int(re.search(r"(-\d+) dBm", sig).group(1)) if re.search(r"(-\d+) dBm", sig) else None
        enterprise = "enterprise" in str(cur.get("spairport_security_mode", ""))
        fast_nearby = sorted({
            n.get("spairport_network_channel", "")
            for n in itf.get("spairport_airport_other_local_wireless_networks", [])
            if ("5GHz" in n.get("spairport_network_channel", "") or "6GHz" in n.get("spairport_network_channel", ""))
            and (not enterprise or "enterprise" in str(n.get("spairport_security_mode", "")))
        })
        return {"band": band, "channel": ch, "rssi": rssi, "rate": cur.get("spairport_network_rate"),
                "fast_nearby": fast_nearby}
    return None


def gateway():
    m = re.search(r"gateway: (\S+)", sh(["route", "-n", "get", "default"], 5))
    return m.group(1) if m else None


def gw_latency(n=10):
    gw = gateway()
    if not gw:
        return None, 100.0
    out = sh(["ping", "-c", str(n), "-i", "0.2", "-W", "1000", gw], 30)
    loss = re.search(r"([\d.]+)% packet loss", out)
    avg = re.search(r"= [\d.]+/([\d.]+)/", out)
    return (float(avg.group(1)) if avg else None), (float(loss.group(1)) if loss else 100.0)


def status(quiet=False):
    l = link()
    avg, loss = gw_latency()
    if not quiet:
        if not l:
            print("没连上 Wi-Fi")
            return None
        print(f"频段 {l['band']}  信道 {l['channel']}  信号 {l['rssi']} dBm  速率 {l['rate']} Mbps")
        print(f"到路由器: 平均 {avg if avg is not None else '—'} ms，丢包 {loss:.0f}%")
        if l["fast_nearby"]:
            print(f"附近可用的 5/6GHz 同类网络信道: {', '.join(l['fast_nearby'])}")
    return l, avg, loss


def is_bad(l, avg, loss):
    if not l:
        return True
    slow_band = l["band"] == "2.4GHz" and l["fast_nearby"]
    return slow_band or (avg is not None and avg > BAD_GW_MS) or loss > 10


def reconnect():
    subprocess.run(["networksetup", "-setairportpower", IFACE, "off"])
    time.sleep(3)
    subprocess.run(["networksetup", "-setairportpower", IFACE, "on"])
    # eduroam 的 802.1X 认证要几秒，等到能 ping 通路由器
    for _ in range(40):
        time.sleep(1)
        gw = gateway()
        if gw and "1 packets received" in sh(["ping", "-c", "1", "-W", "1000", gw], 5):
            return True
    return False


def score(l, avg, loss):
    """越小越好：主要看到路由器的延迟和丢包，2.4GHz 额外罚分。"""
    if not l or avg is None:
        return 1e9
    return avg + loss * 20 + (50 if l["band"] == "2.4GHz" else 0)


def boost(tries=3):
    print("== 重连前 ==")
    before = status()
    if before and not is_bad(*before):
        print("\n现在已经不错了，不需要重连。")
        return
    best = score(*before) if before else 1e9
    for i in range(1, tries + 1):
        print(f"\n== 第 {i} 次重连 Wi-Fi（会断网几秒）==")
        if not reconnect():
            print("40 秒内没连回来，再试一次")
            continue
        time.sleep(2)
        now = status()
        s = score(*now) if now else 1e9
        if now and not is_bad(*now):
            print(f"\n✅ 好了：{now[0]['band']}，到路由器 {now[1]} ms（重连前 {before[1] if before else '—'} ms）")
            return
        best = min(best, s)
    print("\n试了几次还是在 2.4GHz 或者很卡：这个位置 5GHz 信号太弱，Mac 宁可连 2.4GHz。")
    print("软件能做的到此为止了——换个离 AP 近的位置、用手机热点、或者插网线会有用。")


def notify(msg):
    subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "Wi-Fi 变慢了"'])


def watch(auto=False):
    print(f"开始监控（每 30 秒检查一次，{'自动重连' if auto else '只提醒不重连'}），Ctrl+C 停止")
    bad_streak, last_fix = 0, 0
    while True:
        st = status(quiet=True)
        bad = st is None or is_bad(*st)
        bad_streak = bad_streak + 1 if bad else 0
        l, avg, loss = st if st else (None, None, 100)
        stamp = time.strftime("%H:%M:%S")
        print(f"{stamp} {l['band'] if l else '断开'} {l['rssi'] if l else ''}dBm 路由器 {avg}ms 丢包 {loss:.0f}% {'⚠️' if bad else ''}", flush=True)
        if bad_streak >= 3:  # 连续 3 次（约 1.5 分钟）都差才动手，避免误判
            if auto and time.time() - last_fix > COOLDOWN:
                print(f"{stamp} 连续变差，自动重连", flush=True)
                reconnect()
                last_fix = time.time()
            elif not auto:
                notify("连在慢的 2.4GHz 或延迟很高，运行 wifiboost.py boost 换个热点")
            bad_streak = 0
        time.sleep(30)


if __name__ == "__main__":
    args = sys.argv[1:]
    try:
        if not args:
            st = status()
            if st and is_bad(*st):
                print("\n诊断: 连接很差，建议运行  python3 wifiboost.py boost")
            elif st:
                print("\n诊断: 当前连接正常")
        elif args[0] == "boost":
            boost()
        elif args[0] == "watch":
            watch(auto="--auto" in args)
        else:
            print(__doc__)
    except KeyboardInterrupt:
        print("\n已停止")
