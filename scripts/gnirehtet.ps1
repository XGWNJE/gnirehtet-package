<#
.SYNOPSIS
    gnirehtet 唯一统一入口（兼容 Windows 7 原厂 PowerShell 2.0 ~ PowerShell 7.x）。

.DESCRIPTION
    普通用户只需双击根目录 gnirehtet.bat，默认进入全自动一键模式（-Action auto）：
      1. 自动检测本包 adb 能否运行，缺失运行库时自动静默安装内置 VC++ / UCRT 运行库
      2. 自动清理本包残留进程；遇到端口冲突时提供一键隔离端口或关闭选项
      3. 自动识别手机；Windows 7 缺少 USB 驱动或发现未知 Android 设备时自动安装内置驱动
      4. 手机未授权时自动等待你在手机上点「允许」，点完自动继续
      5. 自动安装手机客户端、尝试加省电白名单、启动反向网络；按 Ctrl+C 退出时自动收尾

.PARAMETER Action
    auto（默认，全自动一键启动）| run | status | install | stop | install-deps | preflight | verify

.PARAMETER Root
    包根目录，默认按脚本自身位置定位（整包绿色可移动）。

.PARAMETER Serial
    多台手机时可指定设备序列号。

.PARAMETER Yes
    非交互模式（自动选默认项、不暂停）。

.PARAMETER Force
    忽略环境阻断项强制继续。

.PARAMETER PauseOnExit
    结束前暂停按键（双击 gnirehtet.bat 时自动开启，防止窗口闪退）。
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'run', 'status', 'install', 'stop', 'install-deps', 'elevated-deps', 'preflight', 'verify')]
    [string]$Action = 'auto',
    [string]$Root = '',
    [string]$Serial = '',
    [string]$DepsStateFile = '',
    [switch]$Yes,
    [switch]$Force,
    [switch]$PauseOnExit
)

$ErrorActionPreference = 'Stop'

# 兼容 PowerShell 2.0 ~ 7.x 获取脚本目录与包根目录
$script:EntryDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $script:EntryDir }

. (Join-Path $script:EntryDir 'lib\EnvCheck.ps1')
. (Join-Path $script:EntryDir 'lib\EnvFix.ps1')
. (Join-Path $script:EntryDir 'lib\AdbDevices.ps1')
. (Join-Path $script:EntryDir 'lib\Win7Deps.ps1')
. (Join-Path $script:EntryDir 'lib\TunnelWatchdog.ps1')

$p = Get-GnirehtetPaths -Root $Root

function Wait-ExitPause {
    if ($PauseOnExit -and -not $Yes) {
        Write-Host ''
        try { Read-Host '按回车键关闭窗口' | Out-Null } catch { }
    }
}

function Exit-Clean {
    param(
        [int]$Code = 0,
        [switch]$SkipPause
    )
    if (-not $SkipPause) {
        Wait-ExitPause
    }
    exit $Code
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    Push-Location -LiteralPath $p.ToolsDir
    try {
        & $Exe @Arguments | Out-Host
        return [int]$LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Show-Devices {
    param($Devices)
    if ($Devices.Count -eq 0) {
        Write-Host '暂未发现已连接的手机。请检查：' -ForegroundColor Yellow
        Write-Host '  1. 数据线是否插牢（部分充电线不能传数据）'
        Write-Host '  2. 手机是否已打开「设置 → 开发者选项 → USB 调试」'
        Write-Host '  3. 手机弹出「允许 USB 调试」时是否点了「允许」'
        return
    }
    Write-Host ("发现 {0} 台设备：" -f $Devices.Count)
    $i = 0
    foreach ($d in $Devices) {
        $i++
        Write-Host ("  [{0}] {1}  {2}" -f $i, (Get-DeviceLabel -Device $d), (Get-DeviceStateText -State $d.State))
    }
}

function Ensure-AdbRuntimeReady {
    if (Test-AdbRunnable -AdbExe $p.AdbExe) {
        return $true
    }

    Write-Host '[依赖] 检测到当前系统无法直接运行 adb.exe（常见于 Windows 7 缺少系统运行库）。' -ForegroundColor Yellow
    $depsInfo = Get-BundledDepsInfo -Root $Root
    if (-not $depsInfo.HasVcRedist) {
        Write-Host '[阻断] 包内缺少 deps\vc_redist.x86.exe，无法自动修复运行库。' -ForegroundColor Red
        return $false
    }

    Write-Host '  正在自动安装内置微软运行库（deps\vc_redist.x86.exe），请稍候……' -ForegroundColor Cyan
    $res = Install-BundledDeps -Root $Root -InstallRuntime
    if (Test-AdbRunnable -AdbExe $p.AdbExe) {
        Write-Host '  [通过] 运行库安装完成，adb 已可正常运行。' -ForegroundColor Green
        return $true
    }

    if ($res.RebootSuggested) {
        Write-Host '[提示] 运行库已安装，但 Windows 7 需要重启电脑一次才能生效。请重启后再双击 gnirehtet.bat。' -ForegroundColor Yellow
    } else {
        Write-Host '[阻断] 安装运行库后 adb 仍无法运行。' -ForegroundColor Red
        if ($res.Log) { Write-Host ('  详情：' + ($res.Log.Trim() -replace '\s+', ' ')) -ForegroundColor DarkGray }
    }
    return $false
}

function Resolve-EnvironmentAuto {
    param([switch]$SkipOwnGnirehtetCleanup)
    # 1. 自动清理本包残留的 gnirehtet 进程（静默处理，不打扰用户；只读查询/安装不误杀活跃会话）
    if (-not $SkipOwnGnirehtetCleanup) {
        $targets = @(Get-InterferenceTargets -Root $Root)
        foreach ($t in $targets) {
            if ($t.Own -and ($t.Kind -eq 'process' -or ($t.Kind -eq 'port' -and $t.Port -eq 31416))) {
                Write-Host ("[*] 检测到上次残留的 gnirehtet（PID {0}），正在自动清理……" -f $t.Pid) -ForegroundColor DarkGray
                Stop-InterferenceTarget -Target $t -Root $Root | Out-Null
            }
        }
    }

    # 2. 重新体检
    $pre = Invoke-EnvPreflight -Root $Root
    if ($pre.Blockers -eq 0) {
        return $true
    }

    if ($Force) {
        Write-Host '[警告] 已使用 -Force 忽略环境阻断项。' -ForegroundColor Yellow
        return $true
    }

    # 3. 分别处理 5037 与 31416 外部冲突
    $adbPort = Get-AdbServerPort
    $adbConflicts = @($pre.Findings | Where-Object {
        $_.Severity -eq 'BLOCKER' -and (@('adb-server-foreign', 'adb-port-non-adb') -contains $_.Id)
    })
    if ($adbConflicts.Count -gt 0) {
        Write-Host ''
        Write-Host ("[冲突] 电脑上已有别的软件占用了 ADB 端口 {0}：" -f $adbPort) -ForegroundColor Yellow
        foreach ($f in $adbConflicts) {
            foreach ($l in (Format-EnvFinding -Finding $f)) { Write-Host ('  ' + $l) }
        }
        Write-Host ''
        if ($Yes) {
            $env:ANDROID_ADB_SERVER_PORT = '5099'
            Write-Host '[*] 自动模式：已切换到隔离端口 5099，不影响其它软件。' -ForegroundColor Cyan
        } else {
            Write-Host '请选择处理方式：'
            Write-Host '  [1] 自动换用隔离端口 5099 继续（推荐，不打断别的软件，直接回车即可）'
            Write-Host '  [2] 关闭占用端口的程序并继续'
            Write-Host '  [3] 取消退出'
            $ans = ''
            try { $ans = Read-Host '输入 1 / 2 / 3（默认 1）' } catch { $ans = '3' }
            $ans = if ($null -eq $ans) { '3' } else { $ans.Trim() }
            if ($ans -eq '' -or $ans -eq '1') {
                $env:ANDROID_ADB_SERVER_PORT = '5099'
                Write-Host '[*] 已切换到隔离端口 5099，不打断其它软件。' -ForegroundColor Cyan
            } elseif ($ans -eq '2') {
                $nowTargets = @(Get-InterferenceTargets -Root $Root | Where-Object { $_.Port -eq $adbPort })
                foreach ($nt in $nowTargets) {
                    $r = Stop-InterferenceTarget -Target $nt -Root $Root
                    Write-Host ('  -> ' + $r.Message)
                }
            } else {
                Write-Host '已取消。'
                return $false
            }
        }
    }

    $relayConflicts = @(Get-InterferenceTargets -Root $Root | Where-Object { $_.Port -eq 31416 -and -not $_.Own })
    if ($relayConflicts.Count -gt 0) {
        Write-Host ''
        Write-Host '[冲突] 31416 端口被其它程序占用，gnirehtet 无法启动：' -ForegroundColor Yellow
        foreach ($rc in $relayConflicts) {
            Write-Host ("  · {0}（PID {1}）" -f $rc.Name, $rc.Pid)
        }
        if ($Yes) {
            Write-Host '[阻断] 自动模式下不强制结束未知外部程序，请手动关闭后重试。' -ForegroundColor Red
            return $false
        }
        Write-Host '  [1] 关闭上述程序并继续'
        Write-Host '  [2] 取消退出（直接回车）'
        $ans = ''
        try { $ans = Read-Host '输入 1 或 2（默认 2）' } catch { $ans = '2' }
        if ($null -ne $ans -and $ans.Trim() -eq '1') {
            foreach ($rc in $relayConflicts) {
                $r = Stop-InterferenceTarget -Target $rc -Root $Root
                Write-Host ('  -> ' + $r.Message)
            }
        } else {
            Write-Host '已取消。'
            return $false
        }
    }

    $after = Invoke-EnvPreflight -Root $Root
    if ($after.Blockers -gt 0) {
        Write-Host '[阻断] 端口冲突仍未解除，已安全停止。' -ForegroundColor Red
        return $false
    }
    return $true
}

function Try-WhitelistPowerSaving {
    param([string]$DeviceSerial)
    Set-AndroidPowerSavingWhitelist -AdbExe $p.AdbExe -Serial $DeviceSerial
}

function Wait-AndResolveDevice {
    param([switch]$AllowInteractiveWait)

    $driverInstalledThisRun = $false

    while ($true) {
        $probe = Get-AdbDevices -AdbExe $p.AdbExe
        if (-not $probe.Ok) {
            Write-Host '[错误] 无法与 adb 通信：' -ForegroundColor Red
            foreach ($l in ($probe.Raw -split "`r?`n" | Where-Object { $_.Trim() })) {
                Write-Host ('  ' + $l)
            }
            return $null
        }

        $all = @($probe.Devices)

        if ($Serial) {
            $hit = $all | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
            if ($hit -and $hit.State -eq 'device') {
                Write-Host ("[*] 已选中设备：{0}" -f (Get-DeviceLabel -Device $hit)) -ForegroundColor Green
                return $hit
            }
            if ($hit) {
                Write-Host ("[*] 设备 {0} 当前状态：{1}" -f (Get-DeviceLabel -Device $hit), (Get-DeviceStateText -State $hit.State)) -ForegroundColor Yellow
            } else {
                Write-Host ("[*] 尚未发现序列号 {0} 的设备。" -f $Serial) -ForegroundColor Yellow
                Show-Devices -Devices $all
            }
            if (-not $AllowInteractiveWait -or $Yes) { return $null }
        } else {
            $usable = @($all | Where-Object { $_.State -eq 'device' })
            if ($usable.Count -eq 1) {
                Write-Host ("[*] 已识别手机：{0}" -f (Get-DeviceLabel -Device $usable[0])) -ForegroundColor Green
                return $usable[0]
            }
            if ($usable.Count -gt 1) {
                if ($Yes) {
                    Write-Host '[阻断] 同时连接了多台手机，自动模式下请用 -Serial 指定序列号。' -ForegroundColor Yellow
                    Show-Devices -Devices $all
                    return $null
                }
                return (Select-AdbDevice -Devices $all)
            }

            # 如果检测到未授权设备，自动轮询等待用户在手机上点「允许」
            $unauth = @($all | Where-Object { $_.State -eq 'unauthorized' })
            if ($unauth.Count -gt 0 -and $AllowInteractiveWait -and -not $Yes) {
                Write-Host ''
                Write-Host '[等待授权] 已检测到手机，请在手机屏幕上点击「允许 USB 调试」（建议勾选始终允许）……' -ForegroundColor Cyan
                Write-Host '           点完后这里会自动继续，无需任何操作（按 Ctrl+C 可取消）。' -ForegroundColor DarkGray
                for ($w = 0; $w -lt 45; $w++) {
                    Start-Sleep -Seconds 2
                    $reProbe = Get-AdbDevices -AdbExe $p.AdbExe
                    if ($reProbe.Ok) {
                        $reUsable = @($reProbe.Devices | Where-Object { $_.State -eq 'device' })
                        if ($reUsable.Count -ge 1) {
                            Write-Host '[通过] 手机已授权！' -ForegroundColor Green
                            if ($reUsable.Count -eq 1) { return $reUsable[0] }
                            return (Select-AdbDevice -Devices @($reProbe.Devices))
                        }
                    }
                }
                Write-Host '[超时] 仍未收到手机授权，请检查手机屏幕弹窗或拔插数据线。' -ForegroundColor Yellow
            } else {
                Show-Devices -Devices $all
            }
        }

        if (-not $AllowInteractiveWait -or $Yes) {
            return $null
        }

        # 没找到设备时：针对 Windows 7 或存在异常 USB/Android 设备，自动安装内置通用 ADB 驱动
        $brokenUsb = @(Get-BrokenAndroidUsbDevices)
        if ($brokenUsb.Count -gt 0) {
            Write-Host ''
            Write-Host '[诊断] 设备管理器中发现以下缺少驱动的 USB/手机接口：' -ForegroundColor Yellow
            foreach ($b in $brokenUsb) {
                $bName = if ($b.Name) { $b.Name } else { '未知设备' }
                $bId   = if ($b.HardwareId) { $b.HardwareId } else { $b.DeviceId }
                Write-Host ("  · {0}  [{1}] (错误码 {2})" -f $bName, $bId, $b.ErrorCode) -ForegroundColor DarkGray
            }
        }

        if (-not $driverInstalledThisRun) {
            $isWin7 = Test-IsLegacyWindows
            $depsInfo = Get-BundledDepsInfo -Root $Root
            if (($isWin7 -or $brokenUsb.Count -gt 0) -and ($depsInfo.HasGoogleInf -or $depsInfo.HasUniversal)) {
                $extraHids = @($brokenUsb | Where-Object { $_.HardwareId } | ForEach-Object { $_.HardwareId })
                Write-Host ''
                Write-Host '[驱动] 正在自动为这台手机安装通用 Android ADB 驱动（含 Class_FF 通配与当前设备 ID）……' -ForegroundColor Cyan
                $drvRes = Install-BundledDeps -Root $Root -InstallDrivers -ExtraHardwareIds $extraHids
                $driverInstalledThisRun = $true
                if ($drvRes.Log) {
                    $logLines = @($drvRes.Log -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 10)
                    if ($logLines.Count -gt 0) {
                        Write-Host '  驱动安装反馈：' -ForegroundColor DarkGray
                        foreach ($sl in $logLines) { Write-Host ('    ' + $sl.Trim()) -ForegroundColor DarkGray }
                    }
                }
                if ($drvRes.Ok) {
                    Write-Host '[通过] 驱动安装完成，正在重新扫描手机……' -ForegroundColor Green
                    Start-Sleep -Seconds 2
                    try { Invoke-ProcessCapture -FilePath $p.AdbExe -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
                    Initialize-AdbServer -AdbExe $p.AdbExe | Out-Null
                    continue
                } else {
                    if (Test-IsAdministrator) {
                        Write-Host '[提示] 驱动绑定返回失败，请查看上方错误码（如系统拦截未签名驱动，可在开机按 F8 选禁用驱动程序签名强制，或手动安装摩托罗拉/联想官方驱动）。' -ForegroundColor Yellow
                    } else {
                        Write-Host '[提示] 自动安装驱动未完成（可能取消了管理员授权），请右键以管理员身份运行 gnirehtet.bat。' -ForegroundColor Yellow
                    }
                }
            }
        }

        Write-Host ''
        $retry = ''
        try { $retry = Read-Host '请拔插数据线并确认手机弹窗点「允许」后按回车重试（输入 d 重装驱动，q 退出）' } catch { return $null }
        if ($null -eq $retry -or $retry.Trim() -match '^(q|quit|exit|n)$') {
            return $null
        }
        if ($retry.Trim() -match '^(d|drv|driver)$') {
            $driverInstalledThisRun = $false
        }
    }
}

# ==============================================================================
# 主流程
# ==============================================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  gnirehtet 手机通过 USB 借电脑上网（一键统一入口）' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# 校验核心文件是否存在
$missingTools = @($p.GnExe, $p.AdbExe, $p.GnApk | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingTools.Count -gt 0) {
    foreach ($m in $missingTools) {
        Write-Host ("[阻断] 找不到必需文件：{0}" -f $m) -ForegroundColor Red
    }
    Write-Host '请确认整包已完整解压，或运行 scripts\build_package.ps1 重建工具包。' -ForegroundColor Yellow
    Exit-Clean 2
}

# 内部提权子流程：供非管理员进程通过 RunAs 调用，执行完毕将结果写回状态文件
if ($Action -eq 'elevated-deps') {
    $runRt = $false
    $runDrv = $false
    $hids = New-Object System.Collections.Generic.List[string]
    if ($DepsStateFile -and (Test-Path -LiteralPath $DepsStateFile -PathType Leaf)) {
        $reqLines = [System.IO.File]::ReadAllLines($DepsStateFile, [System.Text.Encoding]::UTF8)
        foreach ($rl in $reqLines) {
            if ($rl -eq 'RUNTIME=1') { $runRt = $true }
            elseif ($rl -eq 'DRIVERS=1') { $runDrv = $true }
            elseif ($rl.StartsWith('HWID=')) { $hids.Add($rl.Substring(5)) }
        }
    }
    $w = Invoke-BundledDepsElevatedWorker -Root $Root -InstallRuntime:$runRt -InstallDrivers:$runDrv -ExtraHardwareIds $hids.ToArray()
    if ($DepsStateFile) {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add('RESULT_OK=' + $(if ($w.Ok) { '1' } else { '0' }))
        $out.Add('REBOOT=' + $(if ($w.RebootSuggested) { '1' } else { '0' }))
        foreach ($ln in $w.Lines) {
            $out.Add('LOG=' + $ln)
        }
        [System.IO.File]::WriteAllLines($DepsStateFile, $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    }
    if (-not $w.Ok) { Start-Sleep -Seconds 3 }
    if ($w.Ok) { exit 0 } else { exit 2 }
}

# 快捷子命令：install-deps / verify / preflight
if ($Action -eq 'install-deps') {
    Write-Host '[*] 正在安装全部内置依赖（微软 VC++ 运行库 + 通用 Android ADB 驱动）……' -ForegroundColor Cyan
    $brokenNow = @(Get-BrokenAndroidUsbDevices)
    $extraHids = @($brokenNow | Where-Object { $_.HardwareId } | ForEach-Object { $_.HardwareId })
    $r = Install-BundledDeps -Root $Root -InstallRuntime -InstallDrivers -ExtraHardwareIds $extraHids
    if ($r.Ok) {
        Write-Host '[通过] 内置依赖安装完成。' -ForegroundColor Green
        if ($r.RebootSuggested) {
            Write-Host '[提示] 系统建议重启一次以使运行库完全生效。' -ForegroundColor Yellow
        }
        Exit-Clean 0
    }
    Write-Host '[失败] 安装未完成，请以管理员身份重试。' -ForegroundColor Red
    if ($r.Log) { Write-Host $r.Log -ForegroundColor DarkGray }
    Exit-Clean 2
}

if ($Action -eq 'verify') {
    & (Join-Path $script:EntryDir '00_offline_verify.ps1') -Root $Root
    Exit-Clean $LASTEXITCODE
}

if ($Action -eq 'preflight') {
    & (Join-Path $script:EntryDir '10_env_preflight.ps1') -Root $Root
    Exit-Clean $LASTEXITCODE
}

# 0. 关闭控制台快速编辑模式，防止误点窗口进入「选择」状态冻结进程
Disable-ConsoleQuickEdit | Out-Null

# 1. 确保 Win7 运行库就绪（adb 能正常运行）
if (-not (Ensure-AdbRuntimeReady)) {
    Exit-Clean 3
}

# 2. 进程级置顶本包目录与 ADB 环境变量（双保险，绝不用错系统里的 adb）
$env:PATH = "$($p.ToolsDir);$env:PATH"
$env:ADB  = $p.AdbExe
$env:GNIREHTET_APK = $p.GnApk

# 3. 自动处理环境与端口冲突
$isReadOrInstallAction = (@('status', 'install') -contains $Action)
if (-not (Resolve-EnvironmentAuto -SkipOwnGnirehtetCleanup:$isReadOrInstallAction)) {
    Exit-Clean 3
}

# 4. 独立拉起 adb server（记录是否由本会话拉起，用于退出时无残留清理）
$hadOwnAdbBefore = ($null -ne (Test-OwnAdbOnCurrentPort -AdbExe $p.AdbExe))
$hadOtherOwnGnBefore = (@(Get-GnirehtetProcessList | Where-Object { Test-OwnGnirehtetProcEntry -ProcEntry $_ -GnExePath $p.GnExe }).Count -gt 0)

if (-not (Initialize-AdbServer -AdbExe $p.AdbExe)) {
    Write-Host '[注意] adb 服务启动超时，将尝试直接继续。' -ForegroundColor Yellow
}

$ownAdbNow = Test-OwnAdbOnCurrentPort -AdbExe $p.AdbExe
$ownAdbStartedByUs = (-not $hadOwnAdbBefore -and $null -ne $ownAdbNow)
$adbPortNow = Get-AdbServerPort
$isWatchdogAction = (@('auto', 'run') -contains $Action)
$shouldCleanupOwnAdbOnExit = $isWatchdogAction -or ($Action -eq 'stop') -or ($ownAdbStartedByUs -and -not $hadOtherOwnGnBefore)

if ($isWatchdogAction -and $null -ne $ownAdbNow -and -not $hadOtherOwnGnBefore) {
    Attach-OwnAdbServerToJob -AdbExe $p.AdbExe | Out-Null
    try {
        if (Ensure-GnirehtetWatchdogNative) {
            [GnirehtetConsoleGuard]::ConfigureShutdownCleanup($null, $p.GnExe, $p.AdbExe, $p.ToolsDir, '', $adbPortNow, $true)
        }
    } catch { }
}

$exitCode = 0
$skipPause = $false
$selectedDev = $null

try {
    switch ($Action) {

        'status' {
            $probe = Get-AdbDevices -AdbExe $p.AdbExe
            if (-not $probe.Ok) {
                Write-Host '[错误] adb 执行失败：' -ForegroundColor Red
                Write-Host $probe.Raw
                $exitCode = 2
            } else {
                Write-Host ''
                Show-Devices -Devices @($probe.Devices)
                $exitCode = 0
            }
        }

        'install' {
            $selectedDev = Wait-AndResolveDevice
            if (-not $selectedDev) {
                $exitCode = 3
            } else {
                Write-Host ("[*] 正在给 {0} 安装客户端……" -f (Get-DeviceLabel -Device $selectedDev)) -ForegroundColor Cyan
                $code = Invoke-Tool -Exe $p.GnExe -Arguments @('install', $selectedDev.Serial)
                if ($code -eq 0) {
                    Write-Host '[通过] 客户端安装成功。' -ForegroundColor Green
                } else {
                    Write-Host ("[失败] 安装失败（退出码 {0}），请检查手机是否弹出「允许通过 USB 安装」。" -f $code) -ForegroundColor Yellow
                }
                $exitCode = $code
            }
        }

        'stop' {
            $selectedDev = Wait-AndResolveDevice
            if (-not $selectedDev) {
                Write-Host '[*] 未检测到已连接手机，将直接清理本包残留后台进程……' -ForegroundColor Yellow
                $exitCode = 0
            } else {
                Write-Host ("[*] 正在停止 {0} 上的反向网络……" -f (Get-DeviceLabel -Device $selectedDev)) -ForegroundColor Cyan
                $code = Invoke-Tool -Exe $p.GnExe -Arguments @('stop', $selectedDev.Serial)
                try {
                    Invoke-ProcessCapture -FilePath $p.AdbExe -Arguments @('-s', $selectedDev.Serial, 'reverse', '--remove', 'localabstract:gnirehtet') -TimeoutSeconds 3 | Out-Null
                } catch { }
                if ($code -eq 0) {
                    Write-Host '[通过] 已停止，手机已恢复原网络。' -ForegroundColor Green
                }
                $exitCode = $code
            }
        }

        default {
            # auto / run：全自动一条龙（内置断连自愈守护）
            $selectedDev = Wait-AndResolveDevice -AllowInteractiveWait:($Action -eq 'auto')
            if (-not $selectedDev) {
                $exitCode = 3
            } else {
                $devLabel = Get-DeviceLabel -Device $selectedDev
                Write-Host ''
                Write-Host ("[*] 正在为「{0}」开启 USB 反向网络……" -f $devLabel) -ForegroundColor Green
                Write-Host '    · 首次运行会自动在手机上安装 gnirehtet 客户端并弹出「VPN 网络连接请求」，请点「确定」'
                Write-Host '    · 已开启断连自动恢复与防窗口误点冻结保护（仅输出关键状态，不再刷屏）'
                Write-Host '    · 保持本窗口不要关闭；用完按 Ctrl+C 或关闭窗口即可自动停止并释放所有后台进程'
                Write-Host '    · 提示：若个别国内 App 报无网络，让手机连上任意 Wi-Fi（无需外网）即可，流量仍走 USB'
                Write-Host ''

                $code = Invoke-GnirehtetWatchdog `
                    -GnExe $p.GnExe `
                    -AdbExe $p.AdbExe `
                    -ToolsDir $p.ToolsDir `
                    -Serial $selectedDev.Serial `
                    -DeviceLabel $devLabel `
                    -Root $Root `
                    -StopOwnAdbOnExit
                $exitCode = $code
                if ($code -eq 0 -and ('GnirehtetConsoleGuard' -as [type]) -and [GnirehtetConsoleGuard]::IsStopRequested) {
                    $skipPause = $true
                }
            }
        }
    }
} finally {
    try {
        $skipPreWatchdogCleanup = ($isWatchdogAction -and $null -eq $selectedDev -and $hadOtherOwnGnBefore)
        if ($shouldCleanupOwnAdbOnExit -and -not $skipPreWatchdogCleanup) {
            $keepOther = ($Action -ne 'stop')
            $skipGnClean = $isReadOrInstallAction
            $quietClean = ($isWatchdogAction -and $null -ne $selectedDev) -or $isReadOrInstallAction
            $cleanRes = Stop-OwnPackageProcesses -Root $Root -StopAdbServer -KeepAdbIfOtherGnirehtetRunning:$keepOther -SkipGnirehtet:$skipGnClean -Quiet:$quietClean
            if ($Action -eq 'stop' -and -not $selectedDev -and $cleanRes) {
                if ($cleanRes.StoppedGnirehtetPids.Count -gt 0 -or $cleanRes.StoppedAdbPids.Count -gt 0) {
                    Write-Host '[完成] 已清理本包残留后台进程，目录与端口已释放。' -ForegroundColor Green
                } else {
                    Write-Host '[完成] 当前没有本包残留后台进程。' -ForegroundColor Green
                }
            }
        }
    } catch { }
    try {
        if ('GnirehtetConsoleGuard' -as [type]) {
            [GnirehtetConsoleGuard]::ClearShutdownCleanup()
        }
    } catch { }
    Close-SessionProcessJob
}

Exit-Clean -Code $exitCode -SkipPause:$skipPause
