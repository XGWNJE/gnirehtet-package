<#
    断连自愈守护库（兼容 Windows 7 原厂 PowerShell 2.0 ~ PowerShell 7.x）。

    解决以下运行中断连无法自动恢复的场景：
      1. USB 数据线松动 / 拔插重连后 adb reverse 映射丢失或设备短暂 offline；
      2. 手机 / 平板锁屏时间久了进入休眠或后台被系统清理，导致客户端断开或假死；
      3. 本机 gnirehtet relay 进程意外退出。

    调用前需先点引用 EnvCheck.ps1 与 AdbDevices.ps1。
#>

function Test-AndroidApkInstalled {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    if (-not $AdbExe -or -not $Serial) { return $false }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', 'pm', 'path', 'com.genymobile.gnirehtet') -TimeoutSeconds 8
        if ($cap.TimedOut -or $cap.ExitCode -ne 0) { return $false }
        $raw = $cap.StdOut + "`n" + $cap.StdErr
        return ($raw -match 'package:')
    } catch {
        return $false
    }
}

function Set-AndroidPowerSavingWhitelist {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    if (-not $AdbExe -or -not $Serial) { return }
    try {
        $shellCmd = 'dumpsys deviceidle whitelist +com.genymobile.gnirehtet 2>/dev/null; cmd appops set com.genymobile.gnirehtet RUN_IN_BACKGROUND allow 2>/dev/null; cmd appops set com.genymobile.gnirehtet RUN_ANY_IN_BACKGROUND allow 2>/dev/null; true'
        Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', $shellCmd) -TimeoutSeconds 8 | Out-Null
    } catch { }
}

function Test-AdbReverseActive {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$Port = 31416
    )
    $res = New-Object PSObject -Property @{
        Ok        = $false
        HasTunnel = $false
        Raw       = ''
        TimedOut  = $false
    }
    if (-not $AdbExe -or -not $Serial) { return $res }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'reverse', '--list') -TimeoutSeconds 8
        $res.TimedOut = [bool]$cap.TimedOut
        $raw = ($cap.StdOut + "`n" + $cap.StdErr).Trim()
        $res.Raw = $raw
        if (-not $cap.TimedOut -and $cap.ExitCode -eq 0) {
            $res.Ok = $true
            $pattern = "localabstract:gnirehtet\s+tcp:$Port\b"
            $res.HasTunnel = [bool]($raw -match $pattern)
        }
    } catch {
        $res.Raw = $_.Exception.Message
    }
    return $res
}

function Test-RelayPortListening {
    param([int]$Port = 31416)
    return (@(Get-TcpPortConnections -Port $Port -ListenOnly).Count -gt 0)
}

function Test-RelayClientConnected {
    param([int]$Port = 31416)
    return (@(Get-TcpPortConnections -Port $Port | Where-Object { $_.State -eq 'Established' }).Count -gt 0)
}

function Test-AndroidGnirehtetServiceAlive {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    $res = New-Object PSObject -Property @{
        Ok       = $false
        Alive    = $false
        Raw      = ''
        TimedOut = $false
    }
    if (-not $AdbExe -or -not $Serial) { return $res }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', 'dumpsys', 'activity', 'services', 'com.genymobile.gnirehtet') -TimeoutSeconds 8
        $res.TimedOut = [bool]$cap.TimedOut
        $raw = ($cap.StdOut + "`n" + $cap.StdErr).Trim()
        $res.Raw = $raw
        if (-not $cap.TimedOut -and $cap.ExitCode -eq 0) {
            $res.Ok = $true
            $res.Alive = [bool]($raw -match 'GnirehtetService')
        }
    } catch {
        $res.Raw = $_.Exception.Message
    }
    return $res
}

function Start-GnirehtetRelayProcess {
    param(
        [string]$GnExe,
        [string]$ToolsDir,
        [int]$Port = 31416
    )
    $args = if ($Port -ne 31416) { @('relay', '-p', "$Port") } else { @('relay') }
    $proc = Start-Process -FilePath $GnExe -ArgumentList $args -WorkingDirectory $ToolsDir -NoNewWindow -PassThru
    $null = $proc.Handle

    for ($i = 0; $i -lt 25; $i++) {
        if ($proc.HasExited) {
            return $proc
        }
        if (Test-RelayPortListening -Port $Port) {
            return $proc
        }
        Start-Sleep -Milliseconds 200
    }
    return $proc
}

function Stop-GnirehtetRelayProcess {
    param($Process)
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
            $Process.WaitForExit(3000) | Out-Null
        }
    } catch { }
}

function Repair-AdbDeviceTransport {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$OfflineStreak
    )
    if (-not $AdbExe) { return $false }

    if ($OfflineStreak -eq 1 -or $OfflineStreak -eq 2) {
        if ($Serial) {
            try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'reconnect') -TimeoutSeconds 10 | Out-Null } catch { }
        }
        try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('reconnect', 'offline') -TimeoutSeconds 10 | Out-Null } catch { }
        return $true
    }

    if ($OfflineStreak -eq 4 -or ($OfflineStreak -gt 4 -and (($OfflineStreak - 4) % 5 -eq 0))) {
        try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
        return (Initialize-AdbServer -AdbExe $AdbExe)
    }

    return $true
}

function Invoke-WatchdogHook {
    param(
        $Hooks,
        [string]$Name,
        [scriptblock]$DefaultAction,
        [object[]]$Arguments = @()
    )
    if ($Hooks -and $Hooks.ContainsKey($Name) -and $Hooks[$Name]) {
        return (& $Hooks[$Name] @Arguments)
    }
    return (& $DefaultAction @Arguments)
}

function Repair-GnirehtetConnection {
    param(
        [string]$GnExe,
        [string]$AdbExe,
        [string]$ToolsDir,
        [string]$Serial,
        [ValidateSet('initial', 'tunnel-only', 'restart')]
        [string]$Mode,
        [int]$Port = 31416,
        [int]$TunnelWaitSeconds = 2,
        $Hooks = $null
    )

    $tunnelArgs = if ($Port -ne 31416) { @('tunnel', $Serial, '-p', "$Port") } else { @('tunnel', $Serial) }
    $startArgs  = if ($Port -ne 31416) { @('start', $Serial, '-p', "$Port") }  else { @('start', $Serial) }
    $restartArgs = if ($Port -ne 31416) { @('restart', $Serial, '-p', "$Port") } else { @('restart', $Serial) }

    if ($Mode -eq 'initial') {
        $installed = Test-AndroidApkInstalled -AdbExe $AdbExe -Serial $Serial
        if (-not $installed) {
            Write-Host '[安装] 正在向设备安装 gnirehtet 客户端……' -ForegroundColor Cyan
            $instCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments @('install', $Serial) -TimeoutSeconds 45 -WorkingDirectory $ToolsDir
            if ($instCap.TimedOut -or $instCap.ExitCode -ne 0) {
                $msg = (($instCap.StdOut + ' ' + $instCap.StdErr).Trim() -replace '\s+', ' ')
                Write-Host ("[提示] 客户端安装返回异常（退出码 {0}）：{1}" -f $instCap.ExitCode, $msg) -ForegroundColor Yellow
            }
        }
        Set-AndroidPowerSavingWhitelist -AdbExe $AdbExe -Serial $Serial
        $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
        $sCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $startArgs -TimeoutSeconds 20 -WorkingDirectory $ToolsDir
        return (New-Object PSObject -Property @{
            Ok      = (-not $tCap.TimedOut -and $tCap.ExitCode -eq 0 -and -not $sCap.TimedOut -and $sCap.ExitCode -eq 0)
            Mode    = 'initial'
            Tunnel  = $tCap
            Action  = $sCap
        })
    }

    if ($Mode -eq 'tunnel-only') {
        $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
        if ($TunnelWaitSeconds -gt 0) {
            Invoke-WatchdogHook -Hooks $Hooks -Name 'Sleep' -DefaultAction { param($sec) Start-Sleep -Seconds $sec } -Arguments @($TunnelWaitSeconds) | Out-Null
        }
        $connected = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestClientConnected' -DefaultAction { param($p) Test-RelayClientConnected -Port $p } -Arguments @($Port)
        if ($connected) {
            return (New-Object PSObject -Property @{
                Ok     = (-not $tCap.TimedOut -and $tCap.ExitCode -eq 0)
                Mode   = 'tunnel-only'
                Tunnel = $tCap
                Action = $null
            })
        }
        # 仅重建隧道后仍未连通（例如客户端已被锁屏清理），自动升级为 restart
        Write-Host '[恢复] 隧道重建后客户端未回连，正在重启手机端服务……' -ForegroundColor Cyan
        return (Repair-GnirehtetConnection -GnExe $GnExe -AdbExe $AdbExe -ToolsDir $ToolsDir -Serial $Serial -Mode 'restart' -Port $Port -TunnelWaitSeconds $TunnelWaitSeconds -Hooks $Hooks)
    }

    # Mode -eq 'restart'
    Set-AndroidPowerSavingWhitelist -AdbExe $AdbExe -Serial $Serial
    $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
    $rCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $restartArgs -TimeoutSeconds 25 -WorkingDirectory $ToolsDir
    return (New-Object PSObject -Property @{
        Ok     = (-not $tCap.TimedOut -and $tCap.ExitCode -eq 0 -and -not $rCap.TimedOut -and $rCap.ExitCode -eq 0)
        Mode   = 'restart'
        Tunnel = $tCap
        Action = $rCap
    })
}

function Invoke-GnirehtetWatchdog {
    param(
        [string]$GnExe,
        [string]$AdbExe,
        [string]$ToolsDir,
        [string]$Serial,
        [string]$DeviceLabel = '',
        [int]$Port = 31416,
        [int]$PollIntervalSeconds = 3,
        [int]$ClientGracePolls = 3,
        [int]$ServiceCheckEveryPolls = 7,
        [int]$StartupGraceSeconds = 15,
        [int]$RecoveryGraceSeconds = 10,
        [int]$MaxIterations = 0,
        $Hooks = $null
    )

    if (-not $DeviceLabel) { $DeviceLabel = $Serial }

    $getNow = {
        if ($Hooks -and $Hooks.ContainsKey('Now') -and $Hooks['Now']) {
            return (& $Hooks['Now'])
        }
        return (Get-Date)
    }
    $doSleep = {
        param([int]$Sec)
        if ($Hooks -and $Hooks.ContainsKey('Sleep') -and $Hooks['Sleep']) {
            & $Hooks['Sleep'] $Sec
        } else {
            Start-Sleep -Seconds $Sec
        }
    }

    $relayProc = $null
    try {
        $relayProc = Invoke-WatchdogHook -Hooks $Hooks -Name 'StartRelay' -DefaultAction {
            param($g, $td, $p) Start-GnirehtetRelayProcess -GnExe $g -ToolsDir $td -Port $p
        } -Arguments @($GnExe, $ToolsDir, $Port)

        $relayAlive = Invoke-WatchdogHook -Hooks $Hooks -Name 'IsRelayAlive' -DefaultAction {
            param($pr) ($null -ne $pr -and -not $pr.HasExited)
        } -Arguments @($relayProc)
        $relayListening = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestRelayListening' -DefaultAction {
            param($p) Test-RelayPortListening -Port $p
        } -Arguments @($Port)

        if (-not $relayAlive -or -not $relayListening) {
            Write-Host ("[阻断] gnirehtet relay 启动失败（端口 {0} 未就绪）。" -f $Port) -ForegroundColor Red
            return 2
        }

        Write-Host ("[就绪] 本机转发服务已在 127.0.0.1:{0} 启动。" -f $Port) -ForegroundColor Green

        $initRes = Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
            param($g, $a, $td, $s, $m, $p, $h)
            Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -Hooks $h
        } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'initial', $Port, $Hooks)

        if (-not $initRes -or -not $initRes.Ok) {
            Write-Host '[提示] 首次启动客户端未完全就绪，守护循环将继续自动重试。' -ForegroundColor Yellow
        }

        $graceUntil = (& $getNow).AddSeconds($StartupGraceSeconds)
        $lastState = 'starting'
        $hadDisconnect = $false
        $adbFailStreak = 0
        $offlineStreak = 0
        $noClientStreak = 0
        $restartFailStreak = 0
        $warnedPersistentFail = $false
        $pollCount = 0

        while ($MaxIterations -le 0 -or $pollCount -lt $MaxIterations) {
            $pollCount++
            & $doSleep $PollIntervalSeconds

            # 1. 检查本机 relay 是否仍在监听
            $relayAlive = Invoke-WatchdogHook -Hooks $Hooks -Name 'IsRelayAlive' -DefaultAction {
                param($pr) ($null -ne $pr -and -not $pr.HasExited)
            } -Arguments @($relayProc)
            $relayListening = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestRelayListening' -DefaultAction {
                param($p) Test-RelayPortListening -Port $p
            } -Arguments @($Port)

            if (-not $relayAlive -or -not $relayListening) {
                Write-Host '[恢复] 检测到本机转发服务已退出，正在自动重启……' -ForegroundColor Yellow
                Invoke-WatchdogHook -Hooks $Hooks -Name 'StopRelay' -DefaultAction {
                    param($pr) Stop-GnirehtetRelayProcess -Process $pr
                } -Arguments @($relayProc) | Out-Null
                $relayProc = Invoke-WatchdogHook -Hooks $Hooks -Name 'StartRelay' -DefaultAction {
                    param($g, $td, $p) Start-GnirehtetRelayProcess -GnExe $g -ToolsDir $td -Port $p
                } -Arguments @($GnExe, $ToolsDir, $Port)
                $hadDisconnect = $true
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                continue
            }

            # 2. 探测 adb 设备列表
            $probe = Invoke-WatchdogHook -Hooks $Hooks -Name 'GetDevices' -DefaultAction {
                param($a) Get-AdbDevices -AdbExe $a
            } -Arguments @($AdbExe)

            if (-not $probe -or -not $probe.Ok) {
                $adbFailStreak++
                if ($adbFailStreak -ge 3) {
                    Write-Host '[恢复] adb 服务连续无响应，正在重启 adb server……' -ForegroundColor Yellow
                    Invoke-WatchdogHook -Hooks $Hooks -Name 'RestartAdbServer' -DefaultAction {
                        param($a)
                        try { Invoke-ProcessCapture -FilePath $a -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
                        Initialize-AdbServer -AdbExe $a
                    } -Arguments @($AdbExe) | Out-Null
                    $adbFailStreak = 0
                    $hadDisconnect = $true
                }
                continue
            }
            $adbFailStreak = 0

            $hit = @($probe.Devices | Where-Object { $_.Serial -eq $Serial }) | Select-Object -First 1

            # 3. 设备从列表消失（USB 线松动 / 拔出）
            if (-not $hit) {
                if ($lastState -ne 'disconnected') {
                    Write-Host ("[断连] 未检测到设备「{0}」（数据线可能松动或已拔出），等待重新连接……" -f $DeviceLabel) -ForegroundColor Yellow
                    $lastState = 'disconnected'
                }
                $hadDisconnect = $true
                $offlineStreak = 0
                $noClientStreak = 0
                continue
            }

            # 4. 设备处于 offline
            if ($hit.State -eq 'offline') {
                $offlineStreak++
                if ($lastState -ne 'offline') {
                    Write-Host ("[断连] 设备「{0}」处于离线状态（offline），正在自动尝试恢复 ADB 连接……" -f $DeviceLabel) -ForegroundColor Yellow
                    $lastState = 'offline'
                }
                $hadDisconnect = $true
                $noClientStreak = 0
                Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairTransport' -DefaultAction {
                    param($a, $s, $st) Repair-AdbDeviceTransport -AdbExe $a -Serial $s -OfflineStreak $st
                } -Arguments @($AdbExe, $Serial, $offlineStreak) | Out-Null
                continue
            }

            $offlineStreak = 0

            # 5. 设备未授权
            if ($hit.State -eq 'unauthorized') {
                if ($lastState -ne 'unauthorized') {
                    Write-Host ("[等待授权] 设备「{0}」需要重新授权，请在手机屏幕上点击「允许 USB 调试」……" -f $DeviceLabel) -ForegroundColor Cyan
                    $lastState = 'unauthorized'
                }
                $hadDisconnect = $true
                $noClientStreak = 0
                continue
            }

            # 6. 其他非可用状态（bootloader / recovery / sideload）
            if ($hit.State -ne 'device') {
                if ($lastState -ne $hit.State) {
                    Write-Host ("[等待] 设备「{0}」当前状态：{1}，等待恢复……" -f $DeviceLabel, (Get-DeviceStateText -State $hit.State)) -ForegroundColor Yellow
                    $lastState = $hit.State
                }
                $hadDisconnect = $true
                $noClientStreak = 0
                continue
            }

            # 7. 设备已在线（device）
            if ($hadDisconnect) {
                Write-Host ("[重连] 设备「{0}」已重新连接，正在自动恢复隧道与服务……" -f $DeviceLabel) -ForegroundColor Cyan
                Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $h)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -Hooks $h
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'tunnel-only', $Port, $Hooks) | Out-Null
                $hadDisconnect = $false
                $noClientStreak = 0
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                $lastState = 'recovering'
                continue
            }

            # 8. 轻量校验 adb reverse 映射是否存在（同时起到 USB/ADB 链路保活作用）
            $rev = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestReverse' -DefaultAction {
                param($a, $s, $p) Test-AdbReverseActive -AdbExe $a -Serial $s -Port $p
            } -Arguments @($AdbExe, $Serial, $Port)

            if ($rev -and $rev.Ok -and -not $rev.HasTunnel) {
                Write-Host '[恢复] 检测到 adb reverse 隧道丢失，正在自动重建……' -ForegroundColor Yellow
                Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $h)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -Hooks $h
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'tunnel-only', $Port, $Hooks) | Out-Null
                $noClientStreak = 0
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                $lastState = 'recovering'
                continue
            }

            # 9. 检查 31416 上是否存在活跃客户端连接
            $clientConnected = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestClientConnected' -DefaultAction {
                param($p) Test-RelayClientConnected -Port $p
            } -Arguments @($Port)

            if ($clientConnected) {
                if ($lastState -ne 'connected') {
                    if ($lastState -eq 'recovering') {
                        Write-Host ("[已恢复] 「{0}」USB 反向网络已自动恢复连通。" -f $DeviceLabel) -ForegroundColor Green
                    } else {
                        Write-Host ("[运行中] 「{0}」USB 反向网络已连通，断连自愈守护已开启。" -f $DeviceLabel) -ForegroundColor Green
                    }
                    $lastState = 'connected'
                }
                $noClientStreak = 0
                $restartFailStreak = 0
                $warnedPersistentFail = $false

                # 定期排查“半开僵尸连接”：TCP 仍显示 Established，但手机端服务已被锁屏清理
                if ($ServiceCheckEveryPolls -gt 0 -and ($pollCount % $ServiceCheckEveryPolls -eq 0)) {
                    $svc = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestServiceAlive' -DefaultAction {
                        param($a, $s) Test-AndroidGnirehtetServiceAlive -AdbExe $a -Serial $s
                    } -Arguments @($AdbExe, $Serial)

                    if ($svc -and $svc.Ok -and -not $svc.Alive) {
                        Write-Host '[恢复] 检测到手机端 gnirehtet 服务已停止（可能因锁屏休眠），正在自动拉起……' -ForegroundColor Yellow
                        Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                            param($g, $a, $td, $s, $m, $p, $h)
                            Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -Hooks $h
                        } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'restart', $Port, $Hooks) | Out-Null
                        $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                        $lastState = 'recovering'
                    }
                }
                continue
            }

            # 未连通：如果在宽限期内则继续等待
            if ((& $getNow) -lt $graceUntil) {
                continue
            }

            $noClientStreak++
            $threshold = if ($restartFailStreak -ge 3) { 7 } else { $ClientGracePolls }
            if ($noClientStreak -ge $threshold) {
                if ($restartFailStreak -ge 3 -and -not $warnedPersistentFail) {
                    Write-Host '[提示] 连续多次自动拉起仍未连通：请解锁手机确认是否弹出 VPN 授权，并建议在「最近任务」锁定 gnirehtet、省电策略设为无限制。程序仍会继续自动重试。' -ForegroundColor Yellow
                    $warnedPersistentFail = $true
                } else {
                    Write-Host '[恢复] 检测到手机端连接已断开（可能锁屏休眠或后台被清理），正在自动重启客户端……' -ForegroundColor Yellow
                }

                Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $h)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -Hooks $h
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'restart', $Port, $Hooks) | Out-Null

                $noClientStreak = 0
                $restartFailStreak++
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                $lastState = 'recovering'
            }
        }

        return 0
    } finally {
        Write-Host ''
        Write-Host '[*] 正在收尾：停止本机转发与手机端反向网络……' -ForegroundColor DarkGray
        try {
            Invoke-WatchdogHook -Hooks $Hooks -Name 'StopRelay' -DefaultAction {
                param($pr) Stop-GnirehtetRelayProcess -Process $pr
            } -Arguments @($relayProc) | Out-Null
        } catch { }
        try {
            Invoke-WatchdogHook -Hooks $Hooks -Name 'StopClient' -DefaultAction {
                param($g, $td, $s)
                Invoke-ProcessCapture -FilePath $g -Arguments @('stop', $s) -TimeoutSeconds 8 -WorkingDirectory $td | Out-Null
            } -Arguments @($GnExe, $ToolsDir, $Serial) | Out-Null
            Write-Host '[完成] 已停止，手机已恢复原有网络。' -ForegroundColor Green
        } catch { }
    }
}
