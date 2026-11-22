<#
    共享环境检测库（只读）。

    被以下脚本点引用：
      scripts\10_env_preflight.ps1   环境预检
      scripts\00_offline_verify.ps1  离线验收（汇总环境风险）
      scripts\gnirehtet.ps1          统一入口（闸门）

    本库只查询进程、端口、环境变量和文件，不结束进程、不改配置。
#>

$script:SeverityRank = @{ 'BLOCKER' = 0; 'WARN' = 1; 'INFO' = 2 }

function Get-GnirehtetPaths {
    param([string]$Root = 'C:\Users\wen\gnirehtet-package')
    [pscustomobject]@{
        Root        = $Root
        ToolsDir    = Join-Path $Root 'tools\gnirehtet'
        AdbExe      = Join-Path $Root 'tools\gnirehtet\adb.exe'
        GnExe       = Join-Path $Root 'tools\gnirehtet\gnirehtet.exe'
        LogsDir     = Join-Path $Root 'logs'
        DownloadDir = Join-Path $Root 'download'
    }
}

function New-Finding {
    param(
        [ValidateSet('BLOCKER', 'WARN', 'INFO')][string]$Severity,
        [string]$Id,
        [string]$Title,
        [string]$Detail = '',
        [string]$Fix = '',
        [string[]]$Evidence = @(),
        [switch]$AutoFix
    )
    [pscustomobject]@{
        Severity = $Severity
        Id       = $Id
        Title    = $Title
        Detail   = $Detail
        Fix      = $Fix
        Evidence = $Evidence
        AutoFix  = [bool]$AutoFix
    }
}

function Get-CimProcess {
    param([int]$ProcessId)
    try {
        Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    } catch {
        $null
    }
}

function Get-PortOwners {
    param([int]$Port, [switch]$ListenOnly)
    $query = @{ LocalPort = $Port }
    if ($ListenOnly) { $query['State'] = 'Listen' }
    $conns = @(Get-NetTCPConnection @query -ErrorAction SilentlyContinue)
    foreach ($c in $conns) {
        $proc = Get-CimProcess -ProcessId $c.OwningProcess
        [pscustomobject]@{
            Port        = $Port
            Local       = "$($c.LocalAddress):$($c.LocalPort)"
            Remote      = "$($c.RemoteAddress):$($c.RemotePort)"
            State       = [string]$c.State
            PID         = [int]$c.OwningProcess
            Name        = if ($proc) { $proc.Name } else { '' }
            Path        = if ($proc) { $proc.ExecutablePath } else { $null }
            CommandLine = if ($proc) { $proc.CommandLine } else { $null }
        }
    }
}

function Get-AdbProcessList {
    @(Get-CimInstance Win32_Process -Filter "Name='adb.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                PID         = [int]$_.ProcessId
                Path        = $_.ExecutablePath
                CommandLine = $_.CommandLine
            }
        })
}

function Get-GnirehtetProcessList {
    @(Get-CimInstance Win32_Process -Filter "Name='gnirehtet.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                PID         = [int]$_.ProcessId
                Path        = $_.ExecutablePath
                CommandLine = $_.CommandLine
            }
        })
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 20
    )

    $outFile = Join-Path $env:TEMP ('cap-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ('cap-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $result = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false }

    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # 只等这一个进程。adb 会拉起常驻 server，且子进程会继承输出句柄，
        # 因此不能用管道捕获，也不能用 Start-Process -Wait，否则会被 server 拖住。
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $proc.Kill() } catch { }
        } else {
            $result.ExitCode = $proc.ExitCode
        }
        if (Test-Path -LiteralPath $outFile) { $result.StdOut = (Get-Content -LiteralPath $outFile -Raw -Encoding utf8) }
        if (Test-Path -LiteralPath $errFile) { $result.StdErr = (Get-Content -LiteralPath $errFile -Raw -Encoding utf8) }
    } catch {
        $result.StdErr = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $result
}

function Get-AdbVersionInfo {
    param([string]$Exe)
    $result = [pscustomobject]@{ Ok = $false; Build = $null; Raw = '' }
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $result }

    $cap = Invoke-ProcessCapture -FilePath $Exe -Arguments @('version') -TimeoutSeconds 15
    $raw = (($cap.StdOut + "`n" + $cap.StdErr).Trim())
    $result.Raw = $raw
    if ($cap.TimedOut) {
        $result.Raw = 'adb version 超时'
        return $result
    }
    if ($raw -match 'Version\s+([0-9]+(?:\.[0-9]+)+)-([0-9]+)') {
        $result.Build = $Matches[1]
        $result.Ok = $true
    } elseif ($raw -match 'Version\s+([0-9]+(?:\.[0-9]+)+)') {
        $result.Build = $Matches[1]
        $result.Ok = $true
    }
    $result
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try { [string]::Equals([IO.Path]::GetFullPath($A), [IO.Path]::GetFullPath($B), [StringComparison]::OrdinalIgnoreCase) }
    catch { $false }
}

<#
.SYNOPSIS
    执行只读环境预检，返回结构化结论。
.DESCRIPTION
    关注「会影响其他服务 / 被其他服务影响」的四类东西：
      - 5037 上的 adb server（谁起的、什么版本、会不会被本包客户端重启）
      - 31416 上的 gnirehtet relay（残留或他人占用）
      - PATH / 环境变量里会让 gnirehtet 用错 adb 的配置
      - 本包自己的残留进程
#>
function Invoke-EnvPreflight {
    param([string]$Root = 'C:\Users\wen\gnirehtet-package')

    $p = Get-GnirehtetPaths -Root $Root
    $findings = New-Object System.Collections.Generic.List[object]
    $pkgAdbVersion = Get-AdbVersionInfo -Exe $p.AdbExe

    # ---------------------------------------------------- 1) PATH 里的 adb
    $pathAdbAll = @(Get-Command adb.exe -All -ErrorAction SilentlyContinue)
    $pathAdb = if ($pathAdbAll.Count -gt 0) { $pathAdbAll[0] } else { $null }

    if (-not $pathAdb) {
        $findings.Add((New-Finding -Severity INFO -Id 'path-adb-none' `
            -Title 'PATH 中没有 adb.exe' `
            -Detail '直接双击或裸跑 gnirehtet.exe 时会找不到 adb（gnirehtet 调用的是 PATH 里的 adb）。' `
            -Fix '用 scripts\gnirehtet.ps1 入口运行，它会临时把本包目录放到 PATH 最前面。'))
    } elseif (Test-SamePath $pathAdb.Source $p.AdbExe) {
        $findings.Add((New-Finding -Severity INFO -Id 'path-adb-ok' `
            -Title 'PATH 优先命中本包 adb' `
            -Detail $p.AdbExe -Evidence @("$($pathAdbAll.Count) 个 adb 条目")))
    } else {
        $findings.Add((New-Finding -Severity WARN -Id 'path-adb-other' `
            -Title 'PATH 里先命中的不是本包 adb' `
            -Detail 'gnirehtet 通过 PATH 查找 adb，裸跑会用到下面这个二进制，可能与本包版本不一致。' `
            -Fix '用 scripts\gnirehtet.ps1 入口运行（进程内临时置顶本包目录，不改系统 PATH）。' `
            -Evidence (@($pathAdb.Source) + @($pathAdbAll | Select-Object -Skip 1 | ForEach-Object { '其次：' + $_.Source }))))
    }

    # ---------------------------------------------------- 2) 5037 adb server
    $server = @(Get-PortOwners -Port 5037 -ListenOnly)
    if ($server.Count -eq 0) {
        $findings.Add((New-Finding -Severity INFO -Id 'adb-server-none' `
            -Title '5037 上没有 adb server 在跑' `
            -Detail '当前环境是干净的；实机时本包 adb 会自行拉起 server。'))
    } else {
        foreach ($s in $server) {
            $isOwn = Test-SamePath $s.Path $p.AdbExe
            $srvVer = Get-AdbVersionInfo -Exe $s.Path
            $verNote = if ($srvVer.Ok -and $pkgAdbVersion.Ok) {
                if ($srvVer.Build -ne $pkgAdbVersion.Build) {
                    "server 版本 $($srvVer.Build) ≠ 本包 $($pkgAdbVersion.Build)：本包 adb 首次调用会把这个 server 杀掉并重启为新版本。"
                } else {
                    "server 版本 $($srvVer.Build)，与本包一致，不会触发重启。"
                }
            } else { '版本未能解析，重启风险未知。' }

            if ($isOwn) {
                $findings.Add((New-Finding -Severity WARN -Id 'adb-server-own' `
                    -Title '本包 adb server 残留' `
                    -Detail "PID $($s.PID) 由本包 adb 启动，属于可安全回收的自身残留。$verNote" `
                    -Fix '运行 10_env_preflight.ps1 -Apply 回收（只对本包 server 执行 kill-server）。' `
                    -Evidence @("$($s.Local)  PID $($s.PID)  $($s.Path)") -AutoFix))
            } else {
                $sameVersion = ($srvVer.Ok -and $pkgAdbVersion.Ok -and $srvVer.Build -eq $pkgAdbVersion.Build)
                $findings.Add((New-Finding -Severity $(if ($sameVersion) { 'WARN' } else { 'BLOCKER' }) -Id 'adb-server-foreign' `
                    -Title $(if ($sameVersion) { '5037 由其他工具启动，但版本一致' } else { '5037 被其他 adb server 占用' }) `
                    -Detail "这是别的工具链（不是本包）启动的 server。$verNote$(if ($sameVersion) { ' 版本一致，可以直接共用，不会互相重启。' } else { ' 重启会打断对方正在进行的调试或安装。' })" `
                    -Fix $(if ($sameVersion) {
                            '可以直接用；若想彻底隔开，可关闭对方服务后重跑体检。'
                        } else {
                            '先确认对方可以中断，再由人工执行：本包 tools\gnirehtet\adb.exe kill-server；不要交给自动化。'
                        }) `
                    -Evidence @("$($s.Local)  PID $($s.PID)  $($s.Path)")))
            }
        }
    }

    # ---------------------------------------------------- 3) 31416 relay
    $listen31416 = @(Get-PortOwners -Port 31416 -ListenOnly)
    if ($listen31416.Count -eq 0) {
        $findings.Add((New-Finding -Severity INFO -Id 'port-31416-free' `
            -Title '31416 空闲' -Detail 'gnirehtet relay 默认端口可分配。'))
    } else {
        foreach ($s in $listen31416) {
            $isOwn = ($s.Name -eq 'gnirehtet.exe')
            $findings.Add((New-Finding -Severity $(if ($isOwn) { 'WARN' } else { 'BLOCKER' }) -Id 'port-31416-busy' `
                -Title '31416 已被占用' `
                -Detail "占用者：$($s.Name)（PID $($s.PID)）。$($(if ($isOwn) { '看起来是本包 relay 残留。' } else { '不是 gnirehtet，启动 relay 会失败。' }))" `
                -Fix $(if ($isOwn) { '确认为残留后由人工结束该进程。' } else { '由人工判断该服务是否可停；本包不会结束非 gnirehtet 进程。' }) `
                -Evidence @("$($s.Local)  PID $($s.PID)  $($s.Path)")))
        }
    }

    $other31416 = @(Get-PortOwners -Port 31416 | Where-Object { $_.State -ne 'Listen' })
    if ($other31416.Count -gt 0) {
        $findings.Add((New-Finding -Severity INFO -Id 'port-31416-conns' `
            -Title '31416 存在非监听连接' `
            -Detail ("$($other31416.Count) 条连接记录（多为 TIME_WAIT，通常不影响下一次启动）。")))
    }

    # ---------------------------------------------------- 4) 多份 adb
    $runningAdb = @(Get-AdbProcessList)
    $runningPaths = @($runningAdb | Where-Object { $_.Path } |
        Select-Object -ExpandProperty Path -Unique)
    if ($runningPaths.Count -gt 1) {
        $findings.Add((New-Finding -Severity WARN -Id 'adb-multi' `
            -Title '同时存在多个不同路径的 adb 进程' `
            -Detail '多份 adb 共存时，"哪个 client 对应哪个 server" 很容易错位，表现为设备时有时无。' `
            -Fix '实机只保留一份：关掉其他 adb 相关工具后重跑预检。' `
            -Evidence @($runningPaths)))
    }

    # ---------------------------------------------------- 5) 环境变量干扰
    if ($env:ANDROID_SERIAL) {
        $findings.Add((New-Finding -Severity WARN -Id 'env-android-serial' `
            -Title "已设置 ANDROID_SERIAL = $($env:ANDROID_SERIAL)" `
            -Detail 'adb 会忽略 -s 之外的自动选择，强制指向该序列号；设备换机或未连接时命令会直接失败。' `
            -Fix '确认当前会话确实需要它；不需要时在新会话中清掉该变量。'))
    }
    if ($env:ADB_VENDOR_KEYS) {
        $findings.Add((New-Finding -Severity INFO -Id 'env-vendor-keys' `
            -Title "已设置 ADB_VENDOR_KEYS = $($env:ADB_VENDOR_KEYS)" `
            -Detail '只影响授权密钥查找，不改变版本协商。'))
    }
    foreach ($var in 'ANDROID_HOME', 'ANDROID_SDK_ROOT') {
        if ([Environment]::GetEnvironmentVariable($var)) {
            $findings.Add((New-Finding -Severity INFO -Id "env-$var" `
                -Title "$var = $([Environment]::GetEnvironmentVariable($var))" `
                -Detail 'gnirehtet 不使用这些变量（它只按 PATH 找 adb），列出以避免误判。'))
        }
    }

    # ---------------------------------------------------- 6) 本包进程残留
    $runningGn = @(Get-GnirehtetProcessList)
    if ($runningGn.Count -gt 0) {
        $findings.Add((New-Finding -Severity WARN -Id 'gnirehtet-running' `
            -Title '已有 gnirehtet 进程在运行' `
            -Detail '重复启动会争用 31416；也可能是上次没有正常退出。' `
            -Fix '确认没有正在进行的联调后，由人工结束；脚本不会自动结束它。' `
            -Evidence @($runningGn | ForEach-Object { "PID $($_.PID)  $($_.CommandLine)" })))
    }

    # ---------------------------------------------------- 7) 本包 adb 版本
    if (-not $pkgAdbVersion.Ok) {
        $findings.Add((New-Finding -Severity WARN -Id 'pkg-adb-broken' `
            -Title '本包 adb 无法返回版本' `
            -Detail ($pkgAdbVersion.Raw -replace '\s+', ' ') `
            -Fix '重跑 build_package.ps1 重建工具包。'))
    }

    # ---------------------------------------------------- 汇总
    $blockers = @($findings | Where-Object Severity -eq 'BLOCKER')
    $warns    = @($findings | Where-Object Severity -eq 'WARN')
    $infos    = @($findings | Where-Object Severity -eq 'INFO')

    [pscustomobject]@{
        Root        = $Root
        Paths       = $p
        AdbVersion  = $pkgAdbVersion
        Findings    = $findings.ToArray()
        Blockers    = $blockers.Count
        Warnings    = $warns.Count
        Infos       = $infos.Count
        Clean       = ($blockers.Count -eq 0 -and $warns.Count -eq 0)
        Ready       = ($blockers.Count -eq 0)
    }
}

function Format-EnvFinding {
    param($Finding)
    $tag = switch ($Finding.Severity) {
        'BLOCKER' { '[阻断]' }
        'WARN'    { '[注意]' }
        'INFO'    { '[信息]' }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$tag $($Finding.Title)")
    if ($Finding.Detail) { $lines.Add('       ' + $Finding.Detail) }
    foreach ($e in $Finding.Evidence) { if ($e) { $lines.Add('       · ' + $e) } }
    if ($Finding.Fix) { $lines.Add('       → ' + $Finding.Fix) }
    $lines
}
