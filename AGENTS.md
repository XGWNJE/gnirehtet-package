# AGENTS.md

## 项目定位

`gnirehtet-package` 是面向 Windows 7 / 10 / 11 (x64) 的离线绿色反向 USB 网络工具包，全部用户交互收口于根目录唯一入口 `gnirehtet.bat`。

## 核心硬约束

1. **唯一入口**：根目录仅保留 `gnirehtet.bat`（纯 ASCII 无 BOM），优先调用 `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` 确保 64 位原生执行。
2. **Windows 7 / PowerShell 2.0 兼容性**：
   - `scripts\**\*.ps1` 必须保存为**单一 UTF-8 with BOM**（`EF BB BF`，严禁双 BOM）。
   - 严禁使用 PowerShell 3.0+ 专属语法：`-in` / `-notin`、`[pscustomobject]`、`[ordered]`、`$PSScriptRoot` / `$PSCommandPath`、`Where-Object Prop -eq Val` 简化写法、`Get-Content -Raw`、`Get-ChildItem -File`、`Get-Command -All`、`[Parameter(Mandatory)]`（须写 `Mandatory = $true`）、`HashSet<T>`。
   - 双引号字符串 `"..."` 内严禁出现中文弯引号 `“` `”`（改用 `「` `」`）。
3. **二进制与驱动兼容**：
   - `tools\gnirehtet\adb.exe` 固定使用兼容 Windows 7 的 `platform-tools r33.0.3`（零 Win8+ API 依赖），不得随意升级到含 `GetSystemTimePreciseAsFileTime`、`WaitOnAddress` 或 `ProcessPrng` 导入的版本。
   - 离线依赖统一放置在 `deps\`（`vc_redist.x86.exe`、`UniversalAdbDriverSetup.msi`、`google-usb-driver\`），不向系统写入永久环境变量、路由或防火墙规则。
4. **验证与 Git 规范**：
   - 提交或推送前必须运行 `cmd.exe /c "gnirehtet.bat -Action verify"`，确认 0 FAIL、0 阻断，并同步核对 `README.md` 与 `docs\GUIDE.md`。
   - 默认在 `main` 主线推进；新建分支、工作树或 `push` 须经用户明确授权。

## 细节索引

- 用户使用与排错细节：[docs/GUIDE.md](docs/GUIDE.md)
- 离线构建与清单生成：[scripts/build_package.ps1](scripts/build_package.ps1)
- Win7 依赖与驱动绑定实现：[scripts/lib/Win7Deps.ps1](scripts/lib/Win7Deps.ps1)
- 断连自愈守护实现：[scripts/lib/TunnelWatchdog.ps1](scripts/lib/TunnelWatchdog.ps1)
