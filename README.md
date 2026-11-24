# gnirehtet 反向 USB 工具包（Windows 7 / 10 / 11 一键全能版）

把手机通过 USB 数据线连上电脑，借电脑网络给手机上网（反向 tethering）。  
已针对 **Windows 7 老环境** 打包全部所需离线依赖，**只保留一个统一入口**，双击即可全自动跑通。

---

## 怎么用（就一步）

1. 手机打开 **设置 → 开发者选项 → USB 调试**，用支持传数据的 USB 线插上电脑。
2. 直接双击包根目录的 **[gnirehtet.bat](gnirehtet.bat)**。
3. 手机弹出「允许 USB 调试」点 **允许**，弹出「VPN 网络连接请求」点 **确定**，即可上网。
4. 用完在窗口按 **`Ctrl + C`**，脚本会自动停止手机端 VPN，恢复手机原网络。

> 详细排错与进阶用法（如部分国产 App 报“无网络”、后台防杀）请看 👉 [docs/GUIDE.md](docs/GUIDE.md)。

---

## 这个包自动帮你做了什么

- **唯一统一入口**：只需双击 `gnirehtet.bat`，不用手动敲多条命令。
- **原生兼容 Windows 7 老环境（零门槛）**：
  - 全部脚本兼容 **Windows 7 原厂 PowerShell 2.0 ~ PowerShell 7.x**，无需升级 WMF 5.1。
  - 内置 Google 官方 `platform-tools r33.0.3`（零 Win8+ API 依赖，Windows 7 / 10 / 11 全通）。
  - 自动检测 `adb.exe` 能否运行；若老系统缺少运行库，自动静默安装内置 **`deps\vc_redist.x86.exe`**（微软官方签名的 VC++ 2015-2022 x86 / Win7 UCRT）。
  - 在 Windows 7 上未识别手机或发现异常 USB 设备时，自动静默安装内置 **Google USB 驱动** 与 **Universal ADB 通用手机驱动**。
- **全自动防冲突与收尾**：
  - 自动清理本包上次残留进程；若电脑上别的软件占着 5037 端口，一键默认切换隔离端口 `5099`，不打断对方。
  - 进程内自动置顶本包 `adb.exe`（同时设置 `PATH` 和 `ADB` 环境变量），不写系统环境变量、不改防火墙、不改路由。
  - 手机未授权时自动轮询等待，点完「允许」自动继续；启动时自动装 APK 并尝试加入省电白名单；退出时自动停止手机端 VPN。

---

## 目录结构

```
gnirehtet-package\
├─ gnirehtet.bat                  ← 唯一入口！双击即可全自动运行
├─ tools\gnirehtet\               ← gnirehtet v2.5.1 + Win7/10/11 兼容 adb r33.0.3 + APK
├─ deps\                          ← Windows 7 老环境离线依赖包（运行时按需自动安装）
│  ├─ vc_redist.x86.exe           ← 微软 VC++ 2015-2022 x86 运行库（自带 Win7 UCRT）
│  ├─ UniversalAdbDriverSetup.msi ← 通用 Android ADB USB 驱动（覆盖主流安卓机型）
│  └─ google-usb-driver\          ← Google 官方 USB 驱动（android_winusb.inf）
├─ scripts\                       ← 内部脚本（支持 PowerShell 2.0 ~ 7.x，无需手动调用）
├─ docs\GUIDE.md                  ← 详细说明与高频问题排错手册
└─ manifest.json                  ← 文件版本、大小、SHA256 校验清单
```

---

## 进阶命令行用法（可选）

普通用户直接双击 `gnirehtet.bat` 即可；如需单独执行特定操作，仍通过同一个入口传参：

```cmd
gnirehtet.bat                        :: 默认：全自动一键启动反向上网
gnirehtet.bat -Action status         :: 只查看已连接的手机
gnirehtet.bat -Action stop           :: 手动停止手机端 VPN
gnirehtet.bat -Action install-deps   :: 手动立即安装全部内置运行库和 USB 驱动
gnirehtet.bat -Action verify         :: 离线验收包完整性与脚本语法
gnirehtet.bat -Action preflight      :: 只读环境体检（不改任何状态）
```

> 整包为绿色版，可任意移动、复制到 U 盘或中文/空格路径下运行；不需要时直接删除文件夹即可。
