<#
    环境处置库：找出“会互相打扰的目标”，并按需关闭。

    调用前需先点引用 EnvCheck.ps1（复用其中的查询函数）。
    这里只放“识别 + 关闭”，提示话术和确认流程由 10_env_preflight.ps1 负责。

    安全约定：
      · adb 服务走官方 kill-server 协议，不用强杀；
      · 其它进程按“当场查到的进程编号”精确关闭，不做按名字批量结束；
      · 关闭后立刻复查，能分辨“关掉了 / 关不掉 / 又被拉起来了”。
#>

function Get-InterferenceTargets {
    param([string]$Root = '')
    $Root = Resolve-PackageRoot -Root $Root

    $p = Get-GnirehtetPaths -Root $Root
    $pkgVer = Get-AdbVersionInfo -Exe $p.AdbExe
    $targets = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[int]

    # ---- adb 服务（5037）
    foreach ($s in @(Get-PortOwners -Port 5037 -ListenOnly)) {
        if (-not $s.PID -or $seen.Contains($s.PID)) { continue }
        [void]$seen.Add($s.PID)
        $own = Test-SamePath $s.Path $p.AdbExe
        $ver = Get-AdbVersionInfo -Exe $s.Path
        $facts = @(
            ('程序：' + $(if ($s.Path) { $s.Path } else { '（读不到路径，可能是别的账户启动的）' })),
            ('进程编号：' + $s.PID)
        )
        if ($ver.Ok -and $pkgVer.Ok) {
            $facts += ('它的版本：' + $ver.Build + '　我们这套：' + $pkgVer.Build)
        }

        $targets.Add([pscustomobject]@{
            Kind      = 'adb-server'
            Pid       = $s.PID
            Name      = $s.Name
            Path      = $s.Path
            Own       = $own
            Headline  = $(if ($own) { '这套工具上次留下的 adb 服务还在跑' } else { '别的软件正在占用 adb 服务（5037 端口）' })
            Reason    = $(if ($own) {
                    '是我们自己起的，关掉不影响别人；不关的话，下次启动会多一层混乱。'
                } else {
                    'adb 服务全电脑只能有一个。我们这套一启动，它会被顶掉并重启，对方正在做的调试、安装或投屏可能中断。'
                })
            IfStopped = $(if ($own) { '下次启动时会自动重新拉起，干净。' } else { '这套工具马上就能用；对方需要重新连接设备。' })
            Facts     = $facts
        })
    }

    # ---- 31416 上的进程
    foreach ($s in @(Get-PortOwners -Port 31416 -ListenOnly)) {
        if (-not $s.PID -or $seen.Contains($s.PID)) { continue }
        [void]$seen.Add($s.PID)
        $own = ($s.Name -eq 'gnirehtet.exe')
        $targets.Add([pscustomobject]@{
            Kind      = 'port'
            Pid       = $s.PID
            Name      = $s.Name
            Path      = $s.Path
            Own       = $own
            Headline  = $(if ($own) { '这套工具的转发服务还在跑（31416 端口）' } else { '别的程序占着 31416 端口' })
            Reason    = $(if ($own) {
                    '上次可能没有正常退出。重复启动会抢同一个端口。'
                } else {
                    '这套工具的转发服务要用 31416 端口，被占用就启动不了。'
                })
            IfStopped = $(if ($own) { '清理干净，可以重新开始。' } else { '那个程序会停止工作，请确认它当前不在做事。' })
            Facts     = @(
                ('程序：' + $(if ($s.Name) { $s.Name } else { '未知' })),
                ('进程编号：' + $s.PID),
                ('路径：' + $(if ($s.Path) { $s.Path } else { '（读不到）' }))
            )
        })
    }

    # ---- 没占端口但还挂着的 gnirehtet 进程
    foreach ($g in @(Get-GnirehtetProcessList)) {
        if ($seen.Contains($g.PID)) { continue }
        [void]$seen.Add($g.PID)
        $targets.Add([pscustomobject]@{
            Kind      = 'process'
            Pid       = $g.PID
            Name      = 'gnirehtet.exe'
            Path      = $g.Path
            Own       = $true
            Headline  = '这套工具还有进程没退出'
            Reason    = '残留进程可能占着设备或端口，让下一次启动行为变得难判断。'
            IfStopped = '清理干净，可以重新开始。'
            Facts     = @(
                ('进程编号：' + $g.PID),
                ('启动参数：' + $(if ($g.CommandLine) { $g.CommandLine } else { '（读不到）' }))
            )
        })
    }

    $targets.ToArray()
}

<#
.SYNOPSIS
    关闭一个干扰目标，并复查结果。
#>
function Stop-InterferenceTarget {
    param(
        [Parameter(Mandatory)] $Target,
        [string]$Root = '',
        [switch]$DryRun
    )

    $Root = Resolve-PackageRoot -Root $Root
    $p = Get-GnirehtetPaths -Root $Root
    $result = [pscustomobject]@{ Ok = $false; Message = ''; Respawned = $false }

    if ($Target.Kind -eq 'adb-server') {
        $exe = if ($Target.Path -and (Test-Path -LiteralPath $Target.Path)) { $Target.Path } else { $p.AdbExe }
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
        $still = @(Get-PortOwners -Port 5037 -ListenOnly)
        if ($still.Count -eq 0) {
            $result.Ok = $true
            $result.Message = '已经退出，5037 端口空出来了。'
        } elseif ($still[0].PID -ne $Target.Pid) {
            $result.Respawned = $true
            $result.Message = "它退出后又被拉起来了（新的进程编号 $($still[0].PID)）。说明有别的软件在自动重启它，需要先停掉那个软件。"
        } else {
            $result.Message = "它还在。可能没有权限结束，或它自己拒绝了退出。"
        }
        return $result
    }

    # 其它进程：按当场查到的 PID 精确关闭
    $proc = Get-Process -Id $Target.Pid -ErrorAction SilentlyContinue
    if (-not $proc) {
        $result.Ok = $true
        $result.Message = '它已经不在运行了，不用处理。'
        return $result
    }
    if ($DryRun) {
        $result.Ok = $true
        $result.Message = "演练模式，未执行：结束进程 $($Target.Pid)（$($Target.Name)）"
        return $result
    }
    try {
        Stop-Process -Id $Target.Pid -ErrorAction Stop
    } catch {
        $result.Message = '没能关掉：' + $_.Exception.Message + '（可能需要管理员权限）'
        return $result
    }
    Start-Sleep -Milliseconds 400
    if (Get-Process -Id $Target.Pid -ErrorAction SilentlyContinue) {
        $result.Message = '命令发出去了，但它还在运行。'
        return $result
    }
    $result.Ok = $true
    $result.Message = '已经退出。'
    $result
}
