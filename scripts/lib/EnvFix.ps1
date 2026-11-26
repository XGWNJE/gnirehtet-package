<#
    环境处置库：找出“会互相打扰的目标”，并按需关闭（兼容 PowerShell 2.0 ~ 7.x）。

    调用前需先点引用 EnvCheck.ps1（复用其中的查询函数）。
#>

function Get-InterferenceTargets {
    param([string]$Root = '')
    $Root = Resolve-PackageRoot -Root $Root

    $p = Get-GnirehtetPaths -Root $Root
    $adbPort = Get-AdbServerPort
    $pkgVer = Get-AdbVersionInfo -Exe $p.AdbExe
    $targets = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    # ---- adb 服务端口（默认 5037，遵循 ANDROID_ADB_SERVER_PORT）
    foreach ($s in @(Get-PortOwners -Port $adbPort -ListenOnly)) {
        if (-not $s.PID -or $seen.ContainsKey($s.PID)) { continue }
        $seen[$s.PID] = $true

        if ($s.Name -ine 'adb.exe') {
            $targets.Add((New-Object PSObject -Property @{
                Kind         = 'port'
                Port         = $adbPort
                Pid          = $s.PID
                Name         = $s.Name
                Path         = $s.Path
                CreationDate = $s.CreationDate
                Own          = $false
                Headline     = "别的程序占着 adb 端口（$adbPort 端口）"
                Reason       = "adb 服务需要使用 $adbPort 端口，但当前占用者不是 adb.exe，脚本不会调用它。"
                IfStopped    = '那个程序会停止工作，请确认它当前不在做事。'
                Facts        = @(
                    ('程序：' + $(if ($s.Name) { $s.Name } else { '未知' })),
                    ('进程编号：' + $s.PID),
                    ('路径：' + $(if ($s.Path) { $s.Path } else { '（读不到，可能是别的账户启动的）' }))
                )
            }))
            continue
        }

        $own = Test-SamePath $s.Path $p.AdbExe
        $ver = Get-AdbVersionInfo -Exe $s.Path
        $facts = @(
            ('程序：' + $(if ($s.Path) { $s.Path } else { '（读不到路径，可能是别的账户启动的）' })),
            ('进程编号：' + $s.PID)
        )
        if ($ver.Ok -and $pkgVer.Ok) {
            $facts += ('它的版本：' + $ver.Build + '　我们这套：' + $pkgVer.Build)
        }

        $targets.Add((New-Object PSObject -Property @{
            Kind         = 'adb-server'
            Port         = $adbPort
            Pid          = $s.PID
            Name         = $s.Name
            Path         = $s.Path
            CreationDate = $s.CreationDate
            Own          = $own
            Headline     = $(if ($own) { "这套工具上次留下的 adb 服务还在跑（$adbPort 端口）" } else { "别的软件正在占用 adb 服务（$adbPort 端口）" })
            Reason       = $(if ($own) {
                    '是我们自己起的，关掉不影响别人；不关的话，下次启动会多一层混乱。'
                } else {
                    'adb 服务全电脑只能有一个。我们这套一启动，它会被顶掉并重启，对方正在做的调试、安装或投屏可能中断。'
                })
            IfStopped    = $(if ($own) { '下次启动时会自动重新拉起，干净。' } else { '这套工具马上就能用；对方需要重新连接设备。' })
            Facts        = $facts
        }))
    }

    # ---- 31416 上的进程
    foreach ($s in @(Get-PortOwners -Port 31416 -ListenOnly)) {
        if (-not $s.PID -or $seen.ContainsKey($s.PID)) { continue }
        $seen[$s.PID] = $true
        $own = if ($s.Path) { Test-SamePath $s.Path $p.GnExe } else { ($s.Name -ieq 'gnirehtet.exe') }
        $targets.Add((New-Object PSObject -Property @{
            Kind         = 'port'
            Port         = 31416
            Pid          = $s.PID
            Name         = $s.Name
            Path         = $s.Path
            CreationDate = $s.CreationDate
            Own          = $own
            Headline     = $(if ($own) { '这套工具的转发服务还在跑（31416 端口）' } else { '别的程序占着 31416 端口' })
            Reason       = $(if ($own) {
                    '上次可能没有正常退出。重复启动会抢同一个端口。'
                } else {
                    '这套工具的转发服务要用 31416 端口，被占用就启动不了。'
                })
            IfStopped    = $(if ($own) { '清理干净，可以重新开始。' } else { '那个程序会停止工作，请确认它当前不在做事。' })
            Facts        = @(
                ('程序：' + $(if ($s.Name) { $s.Name } else { '未知' })),
                ('进程编号：' + $s.PID),
                ('路径：' + $(if ($s.Path) { $s.Path } else { '（读不到）' }))
            )
        }))
    }

    # ---- 没占端口但还挂着的 gnirehtet 进程
    foreach ($g in @(Get-GnirehtetProcessList)) {
        if ($seen.ContainsKey($g.PID)) { continue }
        $seen[$g.PID] = $true
        $own = if ($g.Path) {
            Test-SamePath $g.Path $p.GnExe
        } elseif ($g.CommandLine) {
            $g.CommandLine.IndexOf($p.GnExe, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } else {
            $true
        }
        $targets.Add((New-Object PSObject -Property @{
            Kind         = 'process'
            Port         = $null
            Pid          = $g.PID
            Name         = 'gnirehtet.exe'
            Path         = $g.Path
            CreationDate = $g.CreationDate
            Own          = $own
            Headline     = '这套工具还有进程没退出'
            Reason       = '残留进程可能占着设备或端口，让下一次启动行为变得难判断。'
            IfStopped    = '清理干净，可以重新开始。'
            Facts        = @(
                ('进程编号：' + $g.PID),
                ('启动参数：' + $(if ($g.CommandLine) { $g.CommandLine } else { '（读不到）' }))
            )
        }))
    }

    $targets.ToArray()
}

function Stop-InterferenceTarget {
    param(
        [Parameter(Mandatory = $true)] $Target,
        [string]$Root = '',
        [switch]$DryRun
    )

    $Root = Resolve-PackageRoot -Root $Root
    $p = Get-GnirehtetPaths -Root $Root
    $result = New-Object PSObject -Property @{ Ok = $false; Message = ''; Respawned = $false }

    if ($Target.Kind -eq 'adb-server') {
        $adbPort = if ($Target.Port) { [int]$Target.Port } else { Get-AdbServerPort }
        $isAdbBin = ($Target.Name -ieq 'adb.exe') -and $Target.Path -and (Test-Path -LiteralPath $Target.Path)
        $exe = if ($isAdbBin) { $Target.Path } else { $p.AdbExe }
        if ($DryRun) {
            $result.Ok = $true
            $result.Message = "演练模式，未执行：`"$exe`" kill-server"
            return $result
        }
        try {
            Invoke-ProcessCapture -FilePath $exe -Arguments @('kill-server') -TimeoutSeconds 15 | Out-Null
        } catch {
            $result.Message = '调用 kill-server 失败：' + $_.Exception.Message
            return $result
        }
        Start-Sleep -Milliseconds 500
        $still = @(Get-PortOwners -Port $adbPort -ListenOnly)
        if ($still.Count -eq 0) {
            $result.Ok = $true
            $result.Message = "已经退出，$adbPort 端口空出来了。"
        } elseif ($still[0].PID -ne $Target.Pid) {
            $result.Respawned = $true
            $result.Message = "它退出后又被拉起来了（新的进程编号 $($still[0].PID)）。说明有别的软件在自动重启它，需要先停掉那个软件。"
        } else {
            $result.Message = "它还在。可能没有权限结束，或它自己拒绝了退出。"
        }
        return $result
    }

    $cur = Get-CimProcess -ProcessId $Target.Pid
    if (-not $cur) {
        $result.Ok = $true
        $result.Message = '它已经不在运行了，不用处理。'
        return $result
    }
    $identityMismatch = $false
    if ($Target.Name -and $cur.Name -and ($cur.Name -ine $Target.Name)) { $identityMismatch = $true }
    if ($Target.Path -and $cur.ExecutablePath -and -not (Test-SamePath $cur.ExecutablePath $Target.Path)) { $identityMismatch = $true }
    if ($Target.CreationDate -and $cur.CreationDate -and ($cur.CreationDate -ne $Target.CreationDate)) { $identityMismatch = $true }
    if ($identityMismatch) {
        $result.Message = "进程编号 $($Target.Pid) 已被其它程序复用（当前为 $($cur.Name)），原目标已退出，已中止关闭以防误杀。"
        return $result
    }

    if ($DryRun) {
        $result.Ok = $true
        $result.Message = "演练模式，未执行：结束进程 $($Target.Pid)（$($Target.Name)）"
        return $result
    }
    try {
        Stop-Process -Id $Target.Pid -Force -ErrorAction Stop
    } catch {
        $result.Message = '没能关掉：' + $_.Exception.Message + '（可能需要管理员权限）'
        return $result
    }
    Start-Sleep -Milliseconds 400
    $after = Get-CimProcess -ProcessId $Target.Pid
    if ($after -and (-not $Target.CreationDate -or $after.CreationDate -eq $Target.CreationDate)) {
        $result.Message = '命令发出去了，但它还在运行。'
        return $result
    }
    $result.Ok = $true
    $result.Message = '已经退出。'
    $result
}

function Test-OwnGnirehtetProcEntry {
    param($ProcEntry, [string]$GnExePath)
    if (-not $ProcEntry) { return $false }
    if ($ProcEntry.Path) {
        return (Test-SamePath $ProcEntry.Path $GnExePath)
    }
    if ($ProcEntry.CommandLine) {
        return ($ProcEntry.CommandLine.IndexOf($GnExePath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    return $false
}

function Stop-VerifiedProcessByIdentity {
    param(
        [int]$ProcessId,
        [string]$ExpectedName = '',
        [string]$ExpectedPath = '',
        $ExpectedCreationDate = $null,
        [int]$WaitMs = 2000
    )
    if ($ProcessId -le 0) { return $false }
    $cur = Get-CimProcess -ProcessId $ProcessId
    if (-not $cur) { return $true }

    if ($ExpectedName -and $cur.Name -and ($cur.Name -ine $ExpectedName)) { return $false }
    if ($ExpectedPath -and $cur.ExecutablePath -and -not (Test-SamePath $cur.ExecutablePath $ExpectedPath)) { return $false }
    if ($ExpectedCreationDate -and $cur.CreationDate -and ($cur.CreationDate -ne $ExpectedCreationDate)) { return $false }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch { }

    $elapsed = 0
    while ($elapsed -lt $WaitMs) {
        $after = Get-CimProcess -ProcessId $ProcessId
        if (-not $after) { return $true }
        if ($ExpectedCreationDate -and $after.CreationDate -and ($after.CreationDate -ne $ExpectedCreationDate)) {
            return $true
        }
        Start-Sleep -Milliseconds 150
        $elapsed += 150
    }
    $final = Get-CimProcess -ProcessId $ProcessId
    if (-not $final) { return $true }
    if ($ExpectedCreationDate -and $final.CreationDate -and ($final.CreationDate -ne $ExpectedCreationDate)) { return $true }
    return $false
}

function Stop-OwnPackageProcesses {
    param(
        [string]$Root = '',
        [switch]$StopAdbServer,
        [switch]$KeepAdbIfOtherGnirehtetRunning,
        [switch]$SkipGnirehtet,
        [switch]$Quiet
    )

    $Root = Resolve-PackageRoot -Root $Root
    $p = Get-GnirehtetPaths -Root $Root
    $adbPort = Get-AdbServerPort

    $stoppedGn = New-Object System.Collections.Generic.List[int]
    $stoppedAdb = New-Object System.Collections.Generic.List[int]
    $remainingOwn = New-Object System.Collections.Generic.List[int]
    $keptExternalAdb = $false
    $skippedAdbForActiveSession = $false

    # 1. 清理所有属于本包的 gnirehtet.exe（含 31416 端口监听者及无端口残留进程）
    if (-not $SkipGnirehtet) {
        $gnCandidates = @{}
        foreach ($g in @(Get-GnirehtetProcessList)) {
            if (Test-OwnGnirehtetProcEntry -ProcEntry $g -GnExePath $p.GnExe) {
                $gnCandidates[$g.PID] = New-Object PSObject -Property @{
                    PID          = $g.PID
                    Name         = 'gnirehtet.exe'
                    Path         = $g.Path
                    CreationDate = $g.CreationDate
                }
            }
        }
        foreach ($s in @(Get-PortOwners -Port 31416 -ListenOnly)) {
            if (-not $s.PID) { continue }
            $isOwnPort = if ($s.Path) { Test-SamePath $s.Path $p.GnExe } else { ($s.Name -ieq 'gnirehtet.exe') }
            if ($isOwnPort -and -not $gnCandidates.ContainsKey($s.PID)) {
                $gnCandidates[$s.PID] = New-Object PSObject -Property @{
                    PID          = $s.PID
                    Name         = $s.Name
                    Path         = $s.Path
                    CreationDate = $s.CreationDate
                }
            }
        }

        foreach ($pidKey in $gnCandidates.Keys) {
            $cand = $gnCandidates[$pidKey]
            if (Stop-VerifiedProcessByIdentity -ProcessId $cand.PID -ExpectedName 'gnirehtet.exe' -ExpectedPath $p.GnExe -ExpectedCreationDate $cand.CreationDate -WaitMs 2000) {
                $stoppedGn.Add([int]$cand.PID)
            }
        }
    }

    # 2. 按需清理本包 adb.exe（严格按路径匹配，绝不触碰外部工具的 adb.exe）
    $otherGnRunning = @(@(Get-GnirehtetProcessList) | Where-Object { Test-OwnGnirehtetProcEntry -ProcEntry $_ -GnExePath $p.GnExe })
    if ($StopAdbServer) {
        if ($KeepAdbIfOtherGnirehtetRunning -and $otherGnRunning.Count -gt 0) {
            $skippedAdbForActiveSession = $true
        } else {
            $portOwners = @(Get-PortOwners -Port $adbPort -ListenOnly)
            $hasOwnPortAdb = $false
            foreach ($po in $portOwners) {
                if ($po.Name -ieq 'adb.exe') {
                    if ($po.Path -and (Test-SamePath $po.Path $p.AdbExe)) {
                        $hasOwnPortAdb = $true
                    } else {
                        $keptExternalAdb = $true
                    }
                }
            }

            if ($hasOwnPortAdb -and (Test-Path -LiteralPath $p.AdbExe -PathType Leaf)) {
                try { Invoke-ProcessCapture -FilePath $p.AdbExe -Arguments @('kill-server') -TimeoutSeconds 8 | Out-Null } catch { }
                $waited = 0
                while ($waited -lt 2000) {
                    $stillPort = @(Get-PortOwners -Port $adbPort -ListenOnly | Where-Object {
                        $_.Name -ieq 'adb.exe' -and $_.Path -and (Test-SamePath $_.Path $p.AdbExe)
                    })
                    if ($stillPort.Count -eq 0) { break }
                    Start-Sleep -Milliseconds 150
                    $waited += 150
                }
                foreach ($po in $portOwners) {
                    if ($po.Name -ieq 'adb.exe' -and $po.Path -and (Test-SamePath $po.Path $p.AdbExe)) {
                        $curAfter = Get-CimProcess -ProcessId $po.PID
                        if (-not $curAfter -or ($po.CreationDate -and $curAfter.CreationDate -ne $po.CreationDate)) {
                            if (-not ($stoppedAdb.Contains([int]$po.PID))) { $stoppedAdb.Add([int]$po.PID) }
                        } elseif (Stop-VerifiedProcessByIdentity -ProcessId $po.PID -ExpectedName 'adb.exe' -ExpectedPath $p.AdbExe -ExpectedCreationDate $po.CreationDate -WaitMs 2000) {
                            if (-not ($stoppedAdb.Contains([int]$po.PID))) { $stoppedAdb.Add([int]$po.PID) }
                        }
                    }
                }
            }

            # 扫描并清理所有精确匹配本包路径的残留 adb.exe（例如未监听的卡死进程或切换端口前的本包 adb）
            if ($otherGnRunning.Count -eq 0) {
                $ownAdbs = @(Get-AdbProcessList | Where-Object { $_.Path -and (Test-SamePath $_.Path $p.AdbExe) })
                if (-not $hasOwnPortAdb -and $ownAdbs.Count -gt 0 -and (Test-Path -LiteralPath $p.AdbExe -PathType Leaf)) {
                    try { Invoke-ProcessCapture -FilePath $p.AdbExe -Arguments @('kill-server') -TimeoutSeconds 5 | Out-Null } catch { }
                    Start-Sleep -Milliseconds 250
                }
                foreach ($oa in $ownAdbs) {
                    $curAdb = Get-CimProcess -ProcessId $oa.PID
                    if (-not $curAdb -or ($oa.CreationDate -and $curAdb.CreationDate -ne $oa.CreationDate)) {
                        if (-not ($stoppedAdb.Contains([int]$oa.PID))) { $stoppedAdb.Add([int]$oa.PID) }
                    } elseif (Stop-VerifiedProcessByIdentity -ProcessId $oa.PID -ExpectedName 'adb.exe' -ExpectedPath $p.AdbExe -ExpectedCreationDate $oa.CreationDate -WaitMs 2000) {
                        if (-not ($stoppedAdb.Contains([int]$oa.PID))) { $stoppedAdb.Add([int]$oa.PID) }
                    }
                }
            }
        }
    }

    # 3. 复查是否仍有本包残留进程
    if (-not $SkipGnirehtet) {
        foreach ($g in @(Get-GnirehtetProcessList)) {
            if (Test-OwnGnirehtetProcEntry -ProcEntry $g -GnExePath $p.GnExe) {
                if (-not ($remainingOwn.Contains([int]$g.PID))) { $remainingOwn.Add([int]$g.PID) }
            }
        }
    }
    if ($StopAdbServer -and -not $skippedAdbForActiveSession) {
        foreach ($oa in @(Get-AdbProcessList)) {
            if ($oa.Path -and (Test-SamePath $oa.Path $p.AdbExe)) {
                if (-not ($remainingOwn.Contains([int]$oa.PID))) { $remainingOwn.Add([int]$oa.PID) }
            }
        }
    }

    if (-not $Quiet) {
        if ($stoppedGn.Count -gt 0 -or $stoppedAdb.Count -gt 0) {
            Write-Host ("[*] 已清理本包后台进程：gnirehtet={0}，adb={1}" -f ($stoppedGn.ToArray() -join ','), ($stoppedAdb.ToArray() -join ',')) -ForegroundColor DarkGray
        }
        if ($remainingOwn.Count -gt 0) {
            Write-Host ("[注意] 仍有本包进程未能退出（PID：{0}）。" -f ($remainingOwn.ToArray() -join ', ')) -ForegroundColor Yellow
        }
    }

    return (New-Object PSObject -Property @{
        StoppedGnirehtetPids       = $stoppedGn.ToArray()
        StoppedAdbPids             = $stoppedAdb.ToArray()
        KeptExternalAdb            = $keptExternalAdb
        SkippedAdbForActiveSession = $skippedAdbForActiveSession
        RemainingOwnPids           = $remainingOwn.ToArray()
        Clean                      = ($remainingOwn.Count -eq 0)
    })
}
