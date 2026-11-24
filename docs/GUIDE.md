# gnirehtet 反向 USB 工具包 —— 使用与排错手册

本手册面向 **Windows 7 (x64)** 与 **Windows 10 / 11 (x64)** 用户。  
工具包已将 Windows 7 所需的离线依赖（运行库 + 手机 USB 驱动）全部打包在内，并通过唯一的根目录入口 **`gnirehtet.bat`** 全自动完成检测、安装、连接与收尾。

---

## 一、最快上手（只需双击一个文件）

1. **手机端准备**：
   - 打开手机 **设置 → 开发者选项 → USB 调试**。
   - 用**支持数据传输**的 USB 数据线把手机连到电脑。
2. **电脑端启动**：
   - 直接双击包根目录的 **`gnirehtet.bat`**。
   - 若电脑为 Windows 7 且缺少运行库或 USB 驱动，程序会自动弹出一次管理员权限提示，点 **「是」** 即可全自动静默安装内置依赖。
3. **手机端确认**：
   - 弹出 **「允许 USB 调试」** 时点 **允许**（建议勾选“始终允许”），电脑端会自动检测通过并继续。
   - 首次运行时会自动安装手机端 `gnirehtet` 客户端并弹出 **「网络连接请求 / VPN 授权」**，点 **确定**。
4. **保持窗口开启**：
   - 看到日志正常滚动后即可上网。
   - 用完在窗口按 **`Ctrl + C`**，程序会自动停止手机端 VPN 并恢复手机原有网络。

---

## 二、Windows 7 老环境说明（已全自动处理）

本包针对 Windows 7 原厂老环境专门做了三层兼容，**无需用户提前联网下载任何补丁**：

1. **无需升级 PowerShell（免装 WMF 5.1）**
   - 所有内部脚本均兼容 Windows 7 原厂自带的 **PowerShell 2.0** 到最新的 **PowerShell 7.x**。
2. **兼容版 ADB + 内置微软运行库**
   - 内置 Google 官方 `platform-tools r33.0.3`（零 Windows 8+ API 依赖，Windows 7 / 10 / 11 全通）。
   - 启动时自动测试 `adb.exe`；若 Windows 7 缺少通用 C 运行库（UCRT / KB2999226），会自动静默安装内置的 **`deps\vc_redist.x86.exe`**。
   - *注：个别极老的 Windows 7 装完 UCRT 后可能需要重启电脑一次才能生效，程序会自动提示。*
3. **内置双保险 Android USB 驱动**
   - 当 Windows 7 上未识别到手机，或设备管理器里发现带感叹号的未知 USB/Android 设备时，程序会自动静默安装：
     - **`deps\google-usb-driver\`**（Google 官方签名 USB 驱动）
     - **`deps\UniversalAdbDriverSetup.msi`**（通用 ADB 驱动，覆盖小米、华为、OPPO、vivo、三星等主流机型）
   - 驱动装完后，按提示**拔掉手机数据线再重新插上**即可识别。
   - 也可以随时手动运行一次 `gnirehtet.bat -Action install-deps` 一次性预装全部内置依赖。

---

## 三、进阶命令行参数（可选）

所有功能都收口在唯一的 `gnirehtet.bat` 中，进阶或排错时可带参数运行：

```cmd
gnirehtet.bat                              :: 全自动一键运行（双击默认模式）
gnirehtet.bat -Action status               :: 只查看已识别的手机
gnirehtet.bat -Action stop                 :: 手动停止手机端 VPN
gnirehtet.bat -Action install-deps         :: 立即安装全部内置运行库和 USB 驱动
gnirehtet.bat -Action verify               :: 离线验收包完整性、SHA256 与脚本语法
gnirehtet.bat -Action preflight            :: 只读环境体检（查 5037 / 31416 端口占用）
gnirehtet.bat -Action auto -Serial <序列号> -Yes  :: 多设备或无人值守指定某台手机
```

### 遇到端口冲突怎么选？
- 如果电脑上开着模拟器、Android Studio 或投屏软件占用了 `5037` 端口，程序会给出 3 个选项，**直接按回车（默认选 `[1]`）** 即可自动切换到隔离端口 `5099`，完全不打断对方软件。

---

## 四、高频问题与实测排错手册

### 1. 浏览器 / B站能上网，但部分 App（如波点音乐、UU远程等）提示“无网络”？
- **原因**：`gnirehtet` 在免 Root 条件下建立的是纯 VPN 网卡（`tun0`）。当手机把 Wi-Fi 和流量全关掉后，Android 系统认为底层物理网络为空（`Active default network: none`）。部分国内 App 发请求前会强制检查 `WIFI/CELLULAR` 状态位，查不到就直接报离线。
- **解决办法（已实测验证）**：
  - 让手机**连上任意一个 Wi-Fi**（即使该 Wi-Fi 没有外网也可以；系统提示“不可上网”时点「保持连接」）。
  - **放心，流量依然 100% 走 USB 电脑**：`gnirehtet` 建立的是全局不可绕过 VPN（`0.0.0.0/0 -> tun0`），Wi-Fi 仅用来满足系统的在线状态位。

### 2. 用着用着突然所有 App 都断网了？
- **原因**：小米 HyperOS / MIUI、华为、OPPO 等国产系统会激进清理后台，把 `gnirehtet` 客户端强杀掉（电脑日志出现 `Client #0 disconnected`）。
- **解决办法**：
  - 本包启动时已自动尝试通过 ADB 把 `com.genymobile.gnirehtet` 加入省电白名单。
  - 若仍被杀后台，请在手机「最近任务」里把 `gnirehtet` 卡片**下拉锁定**，并在应用详情中把省电策略设为 **无限制**；断线后重新双击 `gnirehtet.bat` 即可恢复。

### 3. `ping` 不通是不是没网？
- **不是**。`gnirehtet` 只转发 **TCP 和 UDP**，不转发 ICMP（`ping` 永远超时），请用浏览器打开网页或 App 实测。

### 4. 需要手动放行 Windows 防火墙 31416 端口吗？
- **不需要**。`gnirehtet` 仅监听本机回环 `127.0.0.1:31416`，通过 `adb reverse` 走 USB 通信，不暴露到局域网，无需改动防火墙。

### 5. 同时插了多台安卓设备怎么办？
- 程序会自动列出已授权的设备让你输入编号；直接回车默认选第 1 台，输错或越界会安全取消不会误操作。
