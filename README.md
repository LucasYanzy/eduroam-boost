# eduroam-boost

**校园 Wi-Fi（eduroam 等）很慢？多半是你的设备黏在了一个弱的 2.4GHz 热点上。** eduroam-boost 帮你把它“踢”到 5/6GHz 上，并用数据告诉你有没有用、效果能维持多久。

[English](#english) · [安装](#安装) · [原理](#原理) · [iPhone](#iphone--ipad) · [安卓](#安卓) · [常见问题](#常见问题)

```
$ eduroam-boost status
频段     2.4GHz   6 (2GHz, 20MHz)
信号     -73 dBm（噪声 -94 dBm）
速率     24 Mbps
到路由器 546 ms, 丢包 10%
附近 5/6GHz 同类网络: 157 (5GHz, 40MHz)

诊断: 连接差 — 连在 2.4GHz，但附近有 5/6GHz 的同类网络; 到路由器平均 546ms（>100）
建议: eduroam-boost boost
```

## 支持情况

| 平台 | 怎么加速 | 一键安装 | 状态 |
|---|---|---|---|
| **macOS** | 自动重连 Wi-Fi，直到换到 5/6GHz；后台监控，变差时提醒或自动处理 | `curl … \| bash` | ✅ 自动测试通过；真机效果数据见下方「实测」 |
| **Windows** | 把网卡驱动的「首选频带」设为 5GHz（重启后也有效），外加重连和后台监控 | `irm … \| iex` | 🧪 实验性：解析逻辑有自动测试，尚未在真机上验证 |
| **iPhone / iPad** | 快捷指令：一键关开 Wi-Fi，触发重新选热点 | 下载快捷指令文件 | 🧪 实验性 |
| **安卓** | 系统不允许 App 开关 Wi-Fi，只能手动处理，见下文 | — | 📄 只有说明 |

## 安装

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/install.sh | bash
```

安装时会问要不要开启**后台监控**（开机自动运行）：
- `y` 只提醒：连续约 1.5 分钟都很差时，弹系统通知
- `a` 自动处理：直接帮你重连（每次断网几秒，两次之间至少隔 5 分钟）

也可以用参数直接指定：`… | bash -s -- --watch` / `--watch-auto` / `--no-watch`。

需要 Python 3.8+（macOS 自带；如果提示没有，先运行 `xcode-select --install`）。只用到 Python 标准库和 macOS 自带命令，不需要管理员权限。

### Windows（实验性）

在 PowerShell 里运行：

```powershell
irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/install.ps1 | iex
```

安装时会问：要不要开后台监控（登录时自动运行），以及要不要现在把网卡设成**首选 5GHz**（会弹一次管理员权限确认）。

## 用法

| 命令 | 作用 |
|---|---|
| `eduroam-boost` / `status` | 当前频段、信号、速率、到路由器的延迟，给出诊断 |
| `eduroam-boost diagnose` | 20 秒测试：慢在 Wi-Fi 这一跳，还是学校出口/运营商？ |
| `eduroam-boost boost` | 重连 Wi-Fi，最多 3 次，直到上了 5/6GHz 且延迟正常（`--force` 强制） |
| `eduroam-boost watch` | 每 30 秒检查一次，变差时提醒；`--auto` 自动重连 |
| `eduroam-boost report` | 最近 24 小时：各频段占比、延迟、每次 boost 前后对比、**效果维持了多久** |
| `eduroam-boost prefer-5g`（仅 Windows） | 设置网卡首选 5GHz；`-Undo` 恢复 |

日志位置：macOS `~/Library/Logs/eduroam-boost/`，Windows `%LOCALAPPDATA%\eduroam-boost\`。

卸载：
```bash
curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/uninstall.sh | bash          # 加 -s -- --purge 连日志一起删
```
```powershell
irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/uninstall.ps1 | iex       # 用过 prefer-5g 的先运行 eduroam-boost prefer-5g -Undo
```

## 原理

大学里一台 AP 通常同时发 2.4GHz 和 5GHz（新的还有 6GHz）。2.4GHz 穿墙好但信道少、人多就挤，5/6GHz 快得多。问题是：

- 设备第一次连上哪个频段，往往就一直待着（sticky client），哪怕旁边的 5GHz 好得多；
- 这时**电脑到路由器这一跳**就要几百毫秒，后面的网络再快也没用——所以 VPN、“游戏加速器”这类东西帮不上忙。

macOS 和 iOS 都不让你手动选频段，但关掉再打开 Wi-Fi 会触发重新扫描，常常就换到了 5GHz。eduroam-boost 做的就是：
1. **判断**：读系统的 Wi-Fi 信息（频段、信号、附近有没有同类型的 5/6GHz 网络），并 ping 默认网关测第一跳延迟；
2. **处理**：只有确实很差时才重连，每次重连后重新测量，直到变好或者试满次数；
3. **验证**：每次 boost 的前后数据，以及之后监控到的情况都记下来，`report` 会算出成功率和**效果维持的时间**。

Windows 多数无线网卡驱动带「首选频带（Preferred Band）」选项，可以直接设成偏好 5GHz，比反复重连更彻底。

> 如果 `boost` 试了几次还是 2.4GHz：说明你这个位置的 5GHz 信号太弱，设备是对的。换个离 AP 近的座位、用手机热点或者插网线才有用。`diagnose` 显示慢在学校出口而不是 Wi-Fi 的话，本工具也帮不上。

## iPhone / iPad

1. 在手机上打开 [ios/eduroam-Boost.shortcut](ios/eduroam-Boost.shortcut)，点「下载」（Raw），用「快捷指令」打开并添加。
2. 觉得卡的时候运行它：Wi-Fi 关闭 → 3 秒 → 打开 → 弹通知。可以把它加到主屏幕、控制中心，或者设置「轻点背面」触发。

导入不了的话，自己建一个也只要四步：新建快捷指令 → 添加「设定 Wi-Fi：关」→「等待 3 秒」→「设定 Wi-Fi：开」。

iOS 不允许任何 App 选频段或读取热点详情，所以手机上只能“重连碰运气”，没有诊断和自动监控。

## 安卓

安卓 10 以后，普通 App 不能开关 Wi-Fi，也不能指定热点，所以没法做成一键工具。可以手动这样做：

- 下拉通知栏，把 Wi-Fi 关掉再打开（效果和 iPhone 快捷指令一样）；
- 部分手机（如三星、小米）在「WLAN → 高级设置」里有**频段选择 / 优先 5GHz**，打开即可；
- 会用 ADB 的话可以：`adb shell cmd wifi set-wifi-enabled disabled && sleep 3 && adb shell cmd wifi set-wifi-enabled enabled`。

## 常见问题

**会不会影响正在进行的下载、视频会议？** 会。重连时断网几秒。所以默认只在“确实很差”时才动手，后台监控默认只提醒不自动重连。

**收集我的数据吗？** 不收集。只 ping 你的默认网关（`diagnose` 额外 ping 1.1.1.1），所有记录只存在本机。macOS 下热点名称会被系统隐藏，本工具也不需要它。

**为什么不直接连某个 BSSID？** macOS 和 iOS 不允许命令行工具这么做（需要定位权限和私有接口）；本工具只用系统公开、稳定的功能。

## 开发

```bash
python3 -m unittest discover -s tests -v                 # macOS：单元测试 + 安装/卸载测试（在临时目录里）
pwsh -c "Invoke-Pester windows/tests -Output Detailed"   # Windows 解析逻辑测试
python3 ios/build_shortcut.py                            # 重新生成并签名 iPhone 快捷指令（需要 macOS）
```

CI 会在 macOS、Windows 和 Linux（shellcheck）上跑上述测试。欢迎提交其他语言的 `netsh` 输出样例到 `windows/tests/fixtures/`。

---

## English

**Campus Wi-Fi slow? Your device is probably stuck on a weak 2.4 GHz access point.** eduroam-boost moves it to 5/6 GHz and measures whether that helped and how long it lasted.

- **macOS**: `curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/install.sh | bash`, then `eduroam-boost status | diagnose | boost | watch [--auto] | report`. Reconnects Wi-Fi only when the first hop is bad, re-measures after each attempt, and logs everything for `report`.
- **Windows (experimental)**: `irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/install.ps1 | iex`. Adds `prefer-5g`, which sets the Wi-Fi driver's *Preferred Band* to 5 GHz (persistent, needs admin).
- **iPhone/iPad (experimental)**: import [ios/eduroam-Boost.shortcut](ios/eduroam-Boost.shortcut) (Wi-Fi off, wait, on).
- **Android**: apps can't toggle Wi-Fi since Android 10; see the manual steps above (toggle Wi-Fi, "prefer 5 GHz" setting on some phones, or ADB).

Output follows your system language (Chinese or English); set `EDUROAM_BOOST_LANG=en` to force English.
If the bottleneck is upstream rather than the Wi-Fi hop (`diagnose` tells you), no client-side tool can help.

## License

MIT
