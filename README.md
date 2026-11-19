<div align="center">

<img src="docs/assets/logo.svg" width="96" height="96" alt="eduroam-boost">

# eduroam-boost

**校园 Wi-Fi 卡？先测出慢在哪，再对症处理。**

[![test](https://github.com/LucasYanzy/eduroam-boost/actions/workflows/test.yml/badge.svg)](https://github.com/LucasYanzy/eduroam-boost/actions/workflows/test.yml)
![platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20iOS-blue)
![license](https://img.shields.io/badge/license-MIT-green)

**简体中文** | [English](README.en.md)

</div>

在 eduroam 这类大型校园网上，设备经常黏在一个拥挤或信号弱的 2.4GHz 热点上不走：**电脑到路由器这一跳**就要几百毫秒，后面的网络再快也救不回来。VPN、“游戏加速器”优化的是路由器之后的线路，对这种情况无能为力。

eduroam-boost 做三件事：

<table>
<tr>
<td width="33%" valign="top">
<img src="docs/assets/measure.svg" width="32" height="32" alt=""><br>
<b>测</b><br>
<sub>频段、信号、到路由器的延迟和丢包，以及附近每台 AP 的<b>信道占用率和接入人数</b>（Mac 平时不显示）</sub>
</td>
<td width="33%" valign="top">
<img src="docs/assets/fix.svg" width="32" height="32" alt=""><br>
<b>治</b><br>
<sub>找座位模式实时显示 5GHz 和 2.4GHz 的信号差，帮你找到 Mac 会自己选 5GHz 的位置；只在有希望时才重连</sub>
</td>
<td width="33%" valign="top">
<img src="docs/assets/verify.svg" width="32" height="32" alt=""><br>
<b>验</b><br>
<sub>记录每次处理前后的数据，统计成功率和效果维持了多久；没用的时候也会直说</sub>
</td>
</tr>
</table>

```console
$ eduroam-boost
频段     2.4GHz   6 (2GHz, 20MHz)
信号   -73 dBm（噪声 -94 dBm）
速率     24 Mbps
到路由器 546 ms, 丢包 0%
附近 5/6GHz 同类网络: 157 (5GHz, 40MHz)

诊断: 连接差 — 到路由器平均 546ms（>100）; 连在 2.4GHz，附近有 5/6GHz 的同类网络
建议: eduroam-boost boost
```

<sub>↑ 数据来自 2026 年 11 月，一台 MacBook Pro 在某大学 eduroam 上的实测。</sub>

## 目录

- [支持的平台](#支持的平台)
- [安装](#安装)
- [使用](#使用)
- [它是怎么工作的](#它是怎么工作的)
- [实测结果](#实测结果)
- [iPhone / iPad](#iphone--ipad)
- [安卓](#安卓)
- [隐私与安全](#隐私与安全)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [参与开发](#参与开发)

## 支持的平台

| 平台 | 能做什么 | 安装方式 | 状态 |
|---|---|---|---|
| **macOS** | 诊断 · 扫描每台 AP 的拥挤程度 · 找座位 · 重连 · 后台监控 · 效果统计 | 一行命令 | <img src="docs/assets/status-stable-zh.svg" height="20" alt=""> 真机使用中 |
| **Windows** | 诊断 · 重连 · 后台监控 · 效果统计，外加**让网卡长期优先 5GHz** | 一行命令 | <img src="docs/assets/status-experimental-zh.svg" height="20" alt=""> 自动测试通过，尚未在真机上验证 |
| **iPhone / iPad** | 一键关开 Wi-Fi（快捷指令） | 导入快捷指令 | <img src="docs/assets/status-experimental-zh.svg" height="20" alt=""> 尚未在真机上验证 |
| **安卓** | 系统不允许 App 开关 Wi-Fi | 手动操作 | <img src="docs/assets/status-guide-zh.svg" height="20" alt=""> |

## 安装

### macOS

打开「终端」，粘贴：

```bash
curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/install.sh | bash
```

安装过程中会问你要不要开**后台监控**（登录后自动运行）：

| 选择 | 效果 |
|---|---|
| `n`（默认） | 只装命令，需要时自己运行 |
| `y` 只提醒 | 每 30 秒检查一次，连续 3 次都很慢（约 1.5 分钟）就弹系统通知 |
| `a` 自动处理 | 同上，但直接帮你重连；每次断网几秒，两次之间至少隔 5 分钟 |

想跳过提问，可以直接带参数：`… | bash -s -- --watch`、`--watch-auto` 或 `--no-watch`。

装好后运行一次 `eduroam-boost authorize`，在弹窗里点「允许」，就能用 `survey` 和 `seat` 了（[为什么要定位权限？](#常见问题)）。

> 需要 Python 3.8+。macOS 一般自带，如果提示找不到，先运行 `xcode-select --install`。
> 不需要管理员权限，只用 Python 标准库和 macOS 自带命令。命令装在 `~/.local/bin`，安装脚本会告诉你是否需要把它加进 PATH。

### Windows（实验性）

打开 PowerShell，粘贴：

```powershell
irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/install.ps1 | iex
```

安装时会问两件事：要不要开后台监控（登录时自动运行），以及要不要现在就让网卡**优先连 5GHz**（会弹一次管理员确认）。装好后打开一个新的终端窗口就能用 `eduroam-boost` 了。

## 使用

| 命令 | 作用 |
|---|---|
| `eduroam-boost` | 看当前状况并给出诊断（等同于 `status`） |
| `eduroam-boost diagnose` | 20 秒对比测试：慢在 Wi-Fi 这一跳，还是学校出口 / 运营商？ |
| `eduroam-boost survey` | 列出这个网络附近的每台 AP：频段、信道、信号、**信道占用率、接入人数**，并告诉你换频段有没有希望（`--all` 显示所有网络） |
| `eduroam-boost seat` | 找座位：每几秒刷新 5GHz 与 2.4GHz 的信号差，你挪动电脑，看到「5GHz 够强了」就停下（`--minutes N`） |
| `eduroam-boost authorize` | 一次性授权定位，`survey` 和 `seat` 需要 |
| `eduroam-boost boost` | 先看扫描结果：5GHz 足够接近、当前信道又很挤时才重连，最多 3 次，换到 5GHz 就停；5GHz 太弱时直接告诉你重连没用（`--force` 强制，`--tries N` 改次数） |
| `eduroam-boost watch` | 前台持续监控；加 `--auto` 自动重连，`--interval 秒数` 改检查间隔 |
| `eduroam-boost report` | 最近 24 小时的统计（`--hours N` 改范围）：各频段占比、延迟、每次 boost 的前后对比，以及**效果维持了多久** |
| `eduroam-boost prefer-5g` | 仅 Windows：把网卡驱动的「首选频带」设为 5GHz，重启后也有效；`-Undo` 恢复默认 |

推荐的使用顺序：

1. 觉得卡 → `eduroam-boost diagnose`，看是不是 Wi-Fi 的问题
2. 是 Wi-Fi 的问题 → `eduroam-boost survey`，看当前信道有多挤、5GHz 差多少
3. 5GHz 只差一点 → `eduroam-boost boost`；差得多 → `eduroam-boost seat` 换个位置（Windows 优先用 `prefer-5g`）
4. 用了几天 → `eduroam-boost report`，看到底有没有用

输出语言跟随系统（中文或英文），可以用 `EDUROAM_BOOST_LANG=zh` 或 `=en` 强制指定。日志保存在 macOS 的 `~/Library/Logs/eduroam-boost/`、Windows 的 `%LOCALAPPDATA%\eduroam-boost\`。

## 它是怎么工作的

```mermaid
flowchart TD
    A[觉得网很卡] --> B{diagnose<br/>到路由器慢吗？}
    B -- 不慢，慢在后面 --> C[学校出口 / 运营商的问题<br/>本工具帮不上]
    B -- 慢 --> D[boost：重连 Wi-Fi<br/>Windows：prefer-5g]
    D --> E{变快了吗？}
    E -- 是 --> F[watch 记录效果能维持多久]
    E -- 还是慢 --> G[这个位置 5GHz 太弱或 AP 太挤<br/>换座位 / 手机热点 / 网线]
```

**为什么会这样：**一台校园 AP 通常同时发 2.4GHz 和 5GHz（新的还有 6GHz）。2.4GHz 穿墙好，但信道少、人一多就挤；5/6GHz 快得多。设备第一次连上哪个频段，往往就一直待着不换（sticky client），哪怕旁边的 5GHz 好得多。

**怎么判断：**读取系统的 Wi-Fi 信息（频段、信号），再 ping 默认网关，测出第一跳的延迟和丢包。授权定位后，辅助 App 还会读取每台 AP 在信标里广播的 **BSS Load**（信道占用率、接入人数），这才是 2.4GHz 慢的真正原因：信号再好，信道 90% 的时间被占着也快不起来。注意这是 AP 广播的瞬时值，每次扫描会有波动。只有**实测到的症状**（延迟 >100ms 或丢包 >10%）才算慢；单纯“连在 2.4GHz、旁边有 5GHz”只作为提示，因为弱的 5GHz 可能比还不错的 2.4GHz 更差（[实测](#实测结果)里就遇到了）。

**怎么处理：**Mac 只按信号强弱选 AP，5GHz 比 2.4GHz 弱几 dB 就不会去连，哪怕 2.4GHz 已经挤爆。macOS 不允许为 eduroam 这类账号密码登录的网络强制指定 AP（实测：不传账号密码时系统会忽略指定，仍按自己的规则选），所以真正有效的办法是**让 5GHz 在 Mac 眼里变强**：`seat` 帮你找到 5GHz 不比 2.4GHz 弱的位置，Mac 就会自己稳定地连上 5GHz。5GHz 只差一两 dB 时，`boost` 重连一次往往就能换过去。Windows 上，多数无线网卡驱动有「首选频带（Preferred Band）」选项，直接设成偏好 5GHz，比反复重连更彻底。

**怎么验证：**每次 boost 都会记下前后数据；后台监控持续采样，`report` 据此算出成功率、各频段的延迟，以及每次 boost 之后过了多久又变慢。

## 实测结果

2026 年 11 月，一台 MacBook Pro 在美国某大学的 eduroam 上，同一个座位，下午时段。

**扫描结果**（`eduroam-boost survey`，同一台 AP 的三个频段）：

| 频段 | 信道 | 信号 | 信道占用 | 接入设备 |
|---|---|---|---|---|
| 2.4GHz（Mac 选的） | 6 | -68 ~ -71 dBm | **59–90%** | 2–5 |
| 5GHz | 157（40MHz） | -76 ~ -80 dBm | 15–39% | 15–17 |
| 6GHz | 149（80MHz） | -84 ~ -88 dBm | 0% | 3–5 |

**两个频段的实际表现**（同一台 AP，先后各测一次）：

| | 2.4GHz 第 6 信道 | 5GHz 第 157 信道 |
|---|---|---|
| 下载速度 | **0.3–0.8 Mbps** | **约 50 Mbps** |
| 丢包 | 3–6% | 0–1% |
| 到外网的延迟（中位数） | 60–120ms | 60–120ms（差不多） |

如实地说：

- **慢的根源是 2.4GHz 信道被挤爆**，下载速度只有 5GHz 的几十分之一；延迟两边差不多，下午整个校园网都偏慢。
- **5GHz 只弱了 5–11 dB，Mac 就死守 2.4GHz**，重连多少次都一样。这就是 `seat` 存在的原因：换个能让 5GHz 追上来的位置。
- **关掉 AWDL（AirDrop/接力）效果很小**：交替测了 4 轮，超过 50ms 的尖峰从 37% 降到 26%，但最慢的那部分延迟和丢包没有改善，所以没有做成功能（测试脚本在 `tools/awdl-test.sh`）。
- **强制指定 AP 走不通**：不提供账号密码时，系统会忽略指定、按自己的规则重新选，实测 3 次都回到 2.4GHz。
- **早期版本的“断网重连”在这里没用**，还曾在延迟正常时白白断网 3 次；现在先看扫描结果，没希望就不重连。

欢迎把你学校的 `eduroam-boost survey` 结果[提交到 Issues](https://github.com/LucasYanzy/eduroam-boost/issues)。

## iPhone / iPad

iOS 不允许任何 App 选择频段或读取热点详情，所以手机上能做的只有一件事：一键关开 Wi-Fi，让手机重新选热点。

1. 用 iPhone 的 Safari 打开 **[eduroam-Boost.shortcut](https://github.com/LucasYanzy/eduroam-boost/raw/main/ios/eduroam-Boost.shortcut)**，下载后选择用「快捷指令」打开，点「添加快捷指令」。
2. 觉得卡的时候运行它：关闭 Wi-Fi → 等 3 秒 → 打开 → 弹出通知。

建议设成双击手机背面触发：「设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下」，选「eduroam Boost」。也可以加到主屏幕或控制中心。

**导入不了？** 自己建一个只要一分钟：新建快捷指令 → 添加「设定 Wi-Fi」设为**关** → 添加「等待」3 秒 → 再添加「设定 Wi-Fi」设为**开**。

> Mac 和 iPhone 登录同一个 Apple ID、并在 iCloud 里开启了「快捷指令」的话，在 Mac 上添加后会自动同步到手机。

## 安卓

安卓 10 以后，普通 App 既不能开关 Wi-Fi，也不能指定连哪个热点，所以做不成一键工具。可以手动这样做：

- **关开 Wi-Fi**：下拉控制中心，把 WLAN 关掉再打开，效果和 iPhone 快捷指令一样。
- **优先 5GHz**：部分手机（如三星、小米）在「WLAN → 高级设置」里有频段选择或“优先 5GHz”，打开即可。
- **用 ADB**（适合开发者）：
  ```bash
  adb shell cmd wifi set-wifi-enabled disabled && sleep 3 && adb shell cmd wifi set-wifi-enabled enabled
  ```

## 隐私与安全

- **不收集、不上传任何数据。** 所有记录只保存在你自己的电脑上。
- **只发出很少的网络请求**：ping 你的默认网关；`diagnose` 额外 ping 一次 `1.1.1.1`。
- **定位权限只用来看热点。** macOS 规定，读取热点名称和地址必须有定位权限，所以 `survey`/`seat` 需要授权一次；辅助 App 从不读取你的位置。它在你电脑上从源码编译（`macos-helper/main.swift`，不到 200 行），不联网。
- **不改系统的网络配置。** macOS 上只会关开 Wi-Fi；Windows 上只有你主动运行 `prefer-5g` 时才会改网卡的「首选频带」，`-Undo` 可以恢复。
- **代码很短**，主程序只有一个 Python 文件和一个 PowerShell 文件，安装前可以先读一遍。

## 常见问题

<details>
<summary><b>重连会打断正在进行的下载、视频会议吗？</b></summary>

会，Wi-Fi 会断开几秒。所以 boost 只在确实很慢时才动手；后台监控默认只提醒，不会自动重连。
</details>

<details>
<summary><b>boost 试了 3 次还是 2.4GHz，是坏了吗？</b></summary>

不是。说明你这个位置的 5GHz 信号比 2.4GHz 更弱，设备选得没错。这种情况下软件能做的已经到头了：换个离 AP 近的座位、用手机热点，或者插网线。
</details>

<details>
<summary><b>diagnose 说慢在学校出口，怎么办？</b></summary>

那就不是你的设备或 Wi-Fi 的问题，任何装在电脑上的工具都帮不上，只能等高峰期过去，或者换个网络。
</details>

<details>
<summary><b>为什么要定位权限？</b></summary>

从 macOS 14 开始，没有定位权限的程序看不到热点名称、地址和 AP 广播的负载信息，扫描结果全是隐藏的。辅助 App 只用它来读这些信息，不读取、不保存你的位置。不授权也能用 `status`、`diagnose`、`boost`、`watch`，只是 `survey` 和 `seat` 不能用。
</details>

<details>
<summary><b>为什么不直接强制连到 5GHz 的那台 AP？</b></summary>

试过了。macOS 的接口在不提供 eduroam 账号密码时会忽略指定的 AP，按自己的规则（主要看信号强弱）重新选。读取你的 eduroam 密码在安全上太敏感，所以本工具不这么做，而是帮你找到 Mac 会自己选 5GHz 的位置。
</details>

<details>
<summary><b>不在 eduroam 上能用吗？</b></summary>

能。它适用于任何同时提供 2.4GHz 和 5/6GHz 的 Wi-Fi，校园网、公司网都可以。
</details>

## 卸载

macOS（加 `-s -- --purge` 连日志一起删）：

```bash
curl -fsSL https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/uninstall.sh | bash
```

Windows（如果用过 `prefer-5g`，先运行 `eduroam-boost prefer-5g -Undo` 恢复网卡设置）：

```powershell
irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/uninstall.ps1 | iex
```

## 参与开发

```
eduroam_boost.py        macOS 命令行工具（只用标准库）
install.sh / uninstall.sh
windows/                PowerShell 版、安装/卸载脚本、Pester 测试
macos-helper/           辅助 App（Swift）：定位授权、扫描每台 AP 的负载
ios/                    iPhone 快捷指令及其生成脚本
tools/                  实验脚本（如 AWDL 对比测试）
tests/                  macOS 单元测试和安装测试
```

```bash
python3 -m unittest discover -s tests -v                  # macOS：单元测试 + 安装/卸载测试（都在临时目录里进行）
pwsh -c "Invoke-Pester windows/tests -Output Detailed"    # Windows：解析逻辑测试
python3 ios/build_shortcut.py                             # 重新生成并签名快捷指令（需要 macOS）
./macos-helper/build.sh                                   # 编译辅助 App（需要 Xcode 命令行工具），输出到 build/
```

每次提交，CI 都会在 macOS、Windows 和 Linux（shellcheck）上跑一遍。特别欢迎这几类贡献：

- **Windows 真机测试结果**，尤其是 `prefer-5g` 在不同网卡上的表现
- **非英文 Windows 的 `netsh` 输出样例**，放到 `windows/tests/fixtures/`
- **你学校的实测数据**（`eduroam-boost report` 的输出）

## License

[MIT](LICENSE)
