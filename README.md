<div align="center">

# gnirehtet-package

插上 USB 数据线，让安卓手机或平板直接借 Windows 7 / 10 / 11 电脑上网的离线绿色工具包。

[使用场景](#你会在哪儿用到它) · [快速开始](#快速开始) · [命令速查](#命令速查) · [项目结构](#项目结构) · [排错](#排错) · [路线规划](#路线规划)

[![gnirehtet v2.5.1](https://img.shields.io/badge/gnirehtet-v2.5.1-blue)](https://github.com/Genymobile/gnirehtet/releases/tag/v2.5.1) [![adb 33.0.3](https://img.shields.io/badge/platform--tools-r33.0.3-green)](manifest.json) [![Windows 7 / 10 / 11 x64](https://img.shields.io/badge/Windows-7%20%7C%2010%20%7C%2011%20(x64)-0078D6)](#快速开始) [![PowerShell 2.0+](https://img.shields.io/badge/PowerShell-2.0%2B-5391FE)](#快速开始)

</div>

## 你会在哪儿用到它

**适合** 手机或平板没流量、现场没有可用外网 Wi-Fi，想插根 USB 数据线借电脑网络上网（含未打补丁的 Windows 7 SP1 老电脑）。\
**先别用** 32 位 Windows 系统（`gnirehtet.exe` 为 64 位程序），或依赖 `ping`（ICMP 协议）的场景（`gnirehtet` 仅转发 TCP/UDP）。

| 时刻 | 你做什么 | 工具包自动替你处理什么 |
| --- | --- | --- |
| 首次在 Windows 7 运行 | 双击 `gnirehtet.bat` | 脚本兼容原厂 PowerShell 2.0（免装 WMF 5.1）；内置 `adb r33.0.3`，缺运行库时自动静默安装 `deps\vc_redist.x86.exe` |
| 电脑认不到手机 ADB 接口 | 按提示点一次确认 | 自动提取缺驱动接口的 `VID/PID`，调用系统 `newdev.dll` 强制绑定通用 WinUSB 驱动并预存入系统驱动库，装完自动重扫 |
| 电脑装有模拟器或投屏软件 | 直接按回车 | 自动清理本包残留；`5037` 端口冲突时默认切到隔离端口 `5099`，不打断其它软件；进程内临时置顶本包 `adb`，不改系统环境变量 |
| 数据线松动或手机锁屏久了断连 | 保持窗口开启即可 | 守护循环每 3 秒巡检一次：自动 `adb reconnect`、重建 `adb reverse` 隧道或重启手机端客户端，通常几秒内自动恢复 |
| 用完准备拔线 | 按 `Ctrl + C` | 自动停止手机端 VPN 服务，恢复手机原有网络 |

## 快速开始

### 前置条件

- 64 位 Windows 7 SP1 / Windows 10 / Windows 11
- 支持数据传输的 USB 数据线（部分充电线仅能充电）
- 安卓手机或平板已打开 **设置 → 开发者选项 → USB 调试**

### 开始使用

1. 下载或克隆本仓库到任意目录（支持中文路径、空格路径和 U 盘）。
2. 手机插上电脑，双击根目录的 [`gnirehtet.bat`](gnirehtet.bat)。
3. 若为 Windows 7 首次运行：弹出管理员权限提示点 **「是」**；若弹出 Windows 安全红框，点击 **「始终安装此驱动程序软件」**，驱动绑定后会自动重新扫描手机。
4. 手机屏幕弹出「允许 USB 调试」时点 **允许**，首次启动弹出「网络连接请求（VPN）」时点 **确定**，看到连接日志滚动即可上网。
5. 结束时在窗口按 **`Ctrl + C`**，自动关掉手机 VPN。

## 命令速查

所有操作均收口在根目录唯一入口 [`gnirehtet.bat`](gnirehtet.bat)，日常使用直接双击即可；需要单独执行某项操作时，在命令行传入参数：

| 命令 | 说明 |
| --- | --- |
| `gnirehtet.bat` | 全自动一键启动反向上网（双击默认模式） |
| `gnirehtet.bat -Action status` | 只查看已连接的手机状态 |
| `gnirehtet.bat -Action stop` | 手动停止手机端 VPN |
| `gnirehtet.bat -Action install-deps` | 立即安装全部内置运行库和通用 ADB 驱动 |
| `gnirehtet.bat -Action verify` | 离线验收包完整性、SHA256 与脚本语法 |
| `gnirehtet.bat -Action preflight` | 只读环境体检（检查 `5037` / `31416` 端口占用） |
| `gnirehtet.bat -Action auto -Serial <序列号> -Yes` | 多台设备或无人值守时指定某台手机 |

详细图文步骤与实测排错请见 [`docs/GUIDE.md`](docs/GUIDE.md)。

## 项目结构

```text
gnirehtet-package/
├── gnirehtet.bat                  # 唯一统一入口，双击即可全自动运行
├── tools/gnirehtet/               # gnirehtet v2.5.1 + Win7/10/11 兼容 adb r33.0.3 + APK
├── deps/                          # Windows 7 老环境离线依赖（按需自动安装）
│   ├── vc_redist.x86.exe          # 微软 VC++ 2015-2022 x86 运行库（自带 Win7 UCRT）
│   ├── UniversalAdbDriverSetup.msi# 通用 Android ADB USB 驱动补充包
│   └── google-usb-driver/         # Google 官方 WinUSB 驱动（动态绑定通用 Class_FF 与设备 ID）
├── scripts/                       # 内部 PowerShell 2.0+ 兼容脚本与依赖库
├── docs/GUIDE.md                  # 详细操作与高频排错手册
├── AGENTS.md                      # 面向 Agent 的项目核心约束
└── manifest.json                  # 文件版本、大小与 SHA256 清单
```

## 排错

| 现象 | 处理方式 |
| --- | --- |
| 资源管理器能看手机文件，但脚本一直提示未发现手机 | 手机的 MTP 与 ADB 是两个独立接口。`gnirehtet.bat` 会自动识别错误码 28 的 ADB 接口并绑定通用 WinUSB 驱动，弹窗点「始终安装此驱动程序软件」即可；也可在重试时输入 `d` 重装驱动 |
| 浏览器能上网，但部分国内 App 提示“无网络” | 让手机连上任意一个 Wi-Fi（即使无外网也行）满足系统物理网络状态位，实际流量依然 100% 走 USB |
| 用着用着突然所有 App 断网 | 工具包已内置断连自动恢复（数据线松动、`offline`、锁屏被清理都会自动重连）；若极端省电策略持续拦截，请在手机「最近任务」锁定 `gnirehtet` 卡片并把省电策略设为「无限制」 |
| `ping` 一直超时 | `gnirehtet` 只转发 TCP 和 UDP，不转发 ICMP（`ping`），请直接用浏览器或 App 测试上网 |

更多排错细节请看 [`docs/GUIDE.md`](docs/GUIDE.md)。

## 路线规划

> **暂无。** 当前没有已公布的未来规划。
