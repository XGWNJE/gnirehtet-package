# gnirehtet 反向 USB 工具包 —— 详细操作与排错教程

本教程面向 **Windows 10/11** 与 **Windows 7 (x64)** 用户，覆盖从首次准备、日常使用到常见坑点排查的完整流程。

---

## 一、运行前先看：你用的是哪个 PowerShell？

本包所有脚本均已做 **Windows 7 + PowerShell 5.1 / PowerShell 7 双兼容**（UTF-8 with BOM 编码，内置 `netstat` / `WMI` / 防火墙 COM / `WebClient` / TLS 1.2 自动降级）：

- **Windows 10 / 11（已装 PowerShell 7）**：直接用 `pwsh`
  ```powershell
  pwsh -NoProfile -File scripts\gnirehtet.ps1 -Action run
  ```
- **Windows 7 或未安装 PowerShell 7 的电脑**：用系统自带的 `powershell`（加上 `-ExecutionPolicy Bypass` 绕过默认脚本执行限制）
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action run
  ```

> 下面教程中的命令均以 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 示范（Win7 / Win10 / Win11 通用）；装了 PowerShell 7 的机器可直接把前面换成 `pwsh -NoProfile -File ...`。

---

## 二、Windows 7 专项准备（仅 Win7 需要看）

Windows 7 原厂环境较老，首次使用前请确认以下 4 项：

1. **系统与 PowerShell 版本**
   - 需要 **Windows 7 SP1 64 位**。
   - 原厂自带 PowerShell 2.0 过旧，建议安装微软官方 **WMF 5.1**（Windows Management Framework 5.1，需先有 .NET Framework 4.5.2+），安装后重启即可正常执行全部脚本。
2. **Android USB 驱动（最重要）**
   - Win7 不会自动下载手机/平板的 ADB 驱动。插上数据线后，打开「设备管理器」确认有 `Android ADB Interface`（没有黄色感叹号）；如果显示未知设备，需安装对应手机/平板厂商官方 USB 驱动或 Google USB Driver。
3. **运行库补丁（防止 `adb.exe` 报缺 DLL）**
   - 本包内置的 `platform-tools`（adb 37.x）依赖 **Universal C Runtime（KB2999226）**。如果运行 `00_offline_verify.ps1` 时 `adb version` 报错缺少 `api-ms-win-crt-*.dll`，请安装微软官方补丁 **KB2999226**（或 VC++ 2015-2022 Redistributable x64）。
   - 如果极老的精简版 Win7 即使装了 UCRT 仍无法运行最新 `adb.exe`，可手动将 Google 旧版 `platform-tools`（如 `r33.0.3`）中的 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` 覆盖到 `tools\gnirehtet\`。
4. **离线直接用（免下载）**
   - 如果你直接从 U 盘拷贝了已经构建好的完整绿色包，**不需要再运行 `build_package.ps1`**，跳过构建直接从第三节第 2 步开始即可。

---

## 三、标准操作流程（一步一步来）

先打开 PowerShell（或按 `Win + R` 输入 `powershell` 回车），切换到包目录（例如在 U 盘 `E:\gnirehtet-package`）：

```powershell
cd E:\gnirehtet-package
```

### 第 1 步：（仅首次从零构建需要）下载并准备工具
如果 `tools\gnirehtet\` 里已经有 `gnirehtet.exe`、`gnirehtet.apk`、`adb.exe`，**跳过此步**。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_package.ps1
```

### 第 2 步：离线验收（只读，不连设备）
检查文件完整性、SHA256 清单、adb 能否正常运行、31416 端口和脚本语法：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\00_offline_verify.ps1
```
- 看到 **`结论：通过`** 表示包本身没问题。
- 如果防火墙规则很多导致扫描较慢，可加 `-SkipFirewallScan`。

### 第 3 步：环境体检与冲突处理
检查电脑上有没有其它软件（如模拟器、Android Studio、投屏软件）占着 5037 或 31416 端口：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\10_env_preflight.ps1
```
- **0 阻断**：直接进入第 4 步。
- **有阻断项**（例如 5037 被其它 `adb server` 占用）：
  - **方案 A（关掉旧服务）**：运行交互式清理，它会逐个说明后果，你输入 `1` 并输入 `关` 才会关闭：
    ```powershell
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\10_env_preflight.ps1 -Fix
    ```
  - **方案 B（不碰旧服务，走隔离端口）**：仅在当前窗口改用 5099 端口（适合不想打断其它工具时）：
    ```powershell
    $env:ANDROID_ADB_SERVER_PORT = '5099'
    ```

### 第 4 步：连接手机/平板并确认识别
1. 在手机/平板上打开 **设置 → 开发者选项 → USB 调试**。
2. 用**支持数据传输**的 USB 线连上电脑，屏幕上弹出「允许 USB 调试」时点 **允许**（可勾选“始终允许”）。
3. 查看识别结果：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action status
   ```
   看到类似 `[1] 型号（序列号）  已授权` 即成功。

### 第 5 步：安装客户端并启动反向网络
1. 首次使用建议先单独安装客户端（如手机弹出“允许通过 USB 安装应用”，点允许）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action install
   ```
2. 启动反向网络隧道：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action run
   ```
   - 首次启动时，手机/平板屏幕会弹出 **「网络连接请求 / VPN 授权」**，点 **确定**。
   - 保持该 PowerShell 窗口不要关闭，看到不断滚动的 `TcpConnection` / `UdpConnection` 日志即说明流量正在通过电脑 USB 转发。

### 第 6 步：结束与收尾清理
1. 在运行窗口按 **`Ctrl + C`** 停止电脑端转发。
2. 停止手机/平板上的 VPN（恢复正常上网）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action stop
   ```
3. （可选）顺手回收本包自己的 `adb server`，做到零残留：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\10_env_preflight.ps1 -Apply
   ```

---

## 四、高频问题与实测排错手册

### 1. 浏览器 / B站能上网，但部分 App（如波点音乐、UU远程等）提示“无网络”？
- **原因**：`gnirehtet` 在免 Root 条件下建立的是纯 VPN 网卡（`tun0`）。当你把手机/平板的 Wi-Fi 和流量全关掉后，Android 系统认为「底层物理网络为空（`Active default network: none`）」。很多国内 App（例如实测的波点音乐、UU远程）在发请求前会强制检查 **`WIFI/CELLULAR` 且 `NOT_VPN`**，查不到就直接报错离线，根本不发数据包。
- **解决办法（已实测验证）**：
  - 让手机/平板**连上任意一个 Wi-Fi**（家用 Wi-Fi 或无外网的局域网热点均可；若连无外网热点，系统提示“不可上网”时点「保持连接」）。
  - **放心，流量依然 100% 走 USB 电脑**：因为 `gnirehtet` 创建的是全局不可绕过 VPN（`bypassable=false`，`0.0.0.0/0 -> tun0`），Wi-Fi 仅用来满足系统的在线状态位，实测所有应用流量都经由 `tun0` 走电脑转发。

### 2. 用着用着突然所有 App 都断网了？
- **原因**：小米 HyperOS / MIUI、华为、OPPO 等国产系统会激进清理后台，把 `gnirehtet` 客户端强杀掉（电脑日志会出现 `Client #0 disconnected`），导致 `tun0` 消失。
- **解决办法**：
  1. 在手机/平板的「最近任务」里把 `gnirehtet` 卡片**下拉锁定**，并在应用详情中把省电策略设为 **无限制**。
  2. 也可以在电脑上用 adb 一键加入省电白名单（把 `<序列号>` 换成 `-Action status` 看到的序列号，只有一台设备时可省略 `-s <序列号>`）：
     ```powershell
     .\tools\gnirehtet\adb.exe shell dumpsys deviceidle whitelist +com.genymobile.gnirehtet
     ```
  3. 断线后重新运行 `-Action run` 即可恢复。

### 3. `ping` 不通是不是没网？
- **不是**。`gnirehtet` 只转发 **TCP 和 UDP**，不转发 ICMP（`ping` 永远超时），请用浏览器打开网页或 App 实测。

### 4. 需要手动放行 Windows 防火墙 31416 端口吗？
- **不需要**。`gnirehtet` 仅监听本机回环 `127.0.0.1:31416`，通过 `adb reverse` 走 USB 通信，不暴露到局域网，无需修改防火墙。

### 5. 同时插了多台安卓设备怎么办？
- 脚本会自动列出已授权的设备让你输入编号；直接回车默认选第 1 台，输错或越界会安全取消不会误操作。
- 也可以直接指定序列号免去询问：
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gnirehtet.ps1 -Action run -Serial <序列号> -Yes
  ```

### 6. 双击 `gnirehtet-run.cmd` 报错找不到 adb？
- 不要直接裸跑 `tools\gnirehtet\gnirehtet.exe` 或 `gnirehtet-run.cmd`，请始终通过 `scripts\gnirehtet.ps1` 运行，它会自动在本次进程内把本包 `adb.exe` 置顶到 PATH，避免找不到或用错系统里的 adb。
