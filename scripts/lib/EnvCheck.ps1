<#
    共享环境检测库（只读，兼容 PowerShell 2.0 ~ 7.x）。

    被以下脚本点引用：
      scripts\10_env_preflight.ps1   环境预检
      scripts\00_offline_verify.ps1  离线验收（汇总环境风险）
      scripts\gnirehtet.ps1          统一入口

    本库只查询进程、端口、环境变量和文件，不结束进程、不改配置。
#>

$script:SeverityRank = @{ 'BLOCKER' = 0; 'WARN' = 1; 'INFO' = 2 }
$script:EnvCheckLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-PackageRoot {
    param([string]$Root)
    if ($Root) { return $Root }
    # 默认取“本库所在包的根目录”，兼容 PowerShell 2.0 ~ 7.x，整包可任意搬动
    if ($script:EnvCheckLibDir) {
        return (Split-Path -Parent (Split-Path -Parent $script:EnvCheckLibDir))
    }
    return (Get-Location).Path
}

function Get-AdbServerPort {
    if ($env:ANDROID_ADB_SERVER_PORT) {
        $parsed = 0
        if ([int]::TryParse($env:ANDROID_ADB_SERVER_PORT.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
            return $parsed
        }
    }
    return 5037
}

function Get-GnirehtetPaths {
    param([string]$Root = '')
    $Root = Resolve-PackageRoot -Root $Root
    New-Object PSObject -Property @{
        Root        = $Root
        ToolsDir    = Join-Path $Root 'tools\gnirehtet'
        AdbExe      = Join-Path $Root 'tools\gnirehtet\adb.exe'
        GnExe       = Join-Path $Root 'tools\gnirehtet\gnirehtet.exe'
        GnApk       = Join-Path $Root 'tools\gnirehtet\gnirehtet.apk'
        DepsDir     = Join-Path $Root 'deps'
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
    New-Object PSObject -Property @{
        Severity = $Severity
        Id       = $Id
        Title    = $Title
        Detail   = $Detail
        Fix      = $Fix
        Evidence = $Evidence
        AutoFix  = [bool]$AutoFix
    }
}

function Get-OsDescription {
    $rt = 'System.Runtime.InteropServices.RuntimeInformation' -as [type]
    if ($rt) {
        try { return ([string]$rt::OSDescription).Trim() } catch { }
    }
    return [Environment]::OSVersion.VersionString
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-CimProcess {
    param([int]$ProcessId)
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            return (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop)
        } catch { }
    }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            $w = Get-WmiObject Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
            if ($w) {
                $cd = $null
                if ($w.CreationDate) {
                    try { $cd = [Management.ManagementDateTimeConverter]::ToDateTime($w.CreationDate) } catch { $cd = $w.CreationDate }
                }
                return (New-Object PSObject -Property @{
                    ProcessId      = [int]$w.ProcessId
                    Name           = $w.Name
                    ExecutablePath = $w.ExecutablePath
                    CommandLine    = $w.CommandLine
                    CreationDate   = $cd
                })
            }
        } catch { }
    }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $pPath = $null; $pStart = $null
        try { $pPath = $p.Path } catch { }
        try { $pStart = $p.StartTime } catch { }
        return (New-Object PSObject -Property @{
            ProcessId      = [int]$p.Id
            Name           = if ($p.ProcessName -like '*.exe') { $p.ProcessName } else { "$($p.ProcessName).exe" }
            ExecutablePath = $pPath
            CommandLine    = $null
            CreationDate   = $pStart
        })
    } catch {
        return $null
    }
}

function Get-TcpPortConnections {
    param([int]$Port, [switch]$ListenOnly)
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $query = @{ LocalPort = $Port }
        if ($ListenOnly) { $query['State'] = 'Listen' }
        try {
            return @(Get-NetTCPConnection @query -ErrorAction Stop)
        } catch {
            if ($_.Exception.Message -match 'No MSFT_NetTCPConnection|找不到任何') {
                return @()
            }
        }
    }

    # Windows 7 / CIM 受限兜底：解析 netstat -ano -p tcp
    $results = New-Object System.Collections.Generic.List[object]
    $netstatOut = @()
    try { $netstatOut = @(& netstat.exe -ano -p tcp 2>$null) } catch { return @() }
    foreach ($line in $netstatOut) {
        if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+(\S+):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
            $localAddr  = $Matches[1].Trim('[', ']')
            $localPort  = [int]$Matches[2]
            $remoteAddr = $Matches[3].Trim('[', ']')
            $remotePort = if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] }
            $rawState   = $Matches[5].ToUpperInvariant()
            $owningPid  = [int]$Matches[6]
            if ($localPort -ne $Port) { continue }
            $state = switch ($rawState) {
                'LISTENING'   { 'Listen' }
                'ESTABLISHED' { 'Established' }
                'TIME_WAIT'   { 'TimeWait' }
                'CLOSE_WAIT'  { 'CloseWait' }
                default       { $rawState }
            }
            if ($ListenOnly -and $state -ne 'Listen') { continue }
            $results.Add((New-Object PSObject -Property @{
                LocalAddress  = $localAddr
                LocalPort     = $localPort
                RemoteAddress = $remoteAddr
                RemotePort    = $remotePort
                State         = $state
                OwningProcess = $owningPid
            }))
        }
    }
    return $results.ToArray()
}

function Get-PortOwners {
    param([int]$Port, [switch]$ListenOnly)
    $conns = @(Get-TcpPortConnections -Port $Port -ListenOnly:$ListenOnly)
    foreach ($c in $conns) {
        $proc = Get-CimProcess -ProcessId $c.OwningProcess
        New-Object PSObject -Property @{
            Port         = $Port
            Local        = "$($c.LocalAddress):$($c.LocalPort)"
            Remote       = "$($c.RemoteAddress):$($c.RemotePort)"
            State        = [string]$c.State
            PID          = [int]$c.OwningProcess
            Name         = if ($proc) { $proc.Name } else { '' }
            Path         = if ($proc) { $proc.ExecutablePath } else { $null }
            CommandLine  = if ($proc) { $proc.CommandLine } else { $null }
            CreationDate = if ($proc) { $proc.CreationDate } else { $null }
        }
    }
}

function Get-ProcessListByName {
    param([string]$ExeName)
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            return @(Get-CimInstance Win32_Process -Filter "Name='$ExeName'" -ErrorAction Stop |
                ForEach-Object {
                    New-Object PSObject -Property @{
                        PID          = [int]$_.ProcessId
                        Path         = $_.ExecutablePath
                        CommandLine  = $_.CommandLine
                        CreationDate = $_.CreationDate
                    }
                })
        } catch { }
    }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            return @(Get-WmiObject Win32_Process -Filter "Name='$ExeName'" -ErrorAction Stop |
                ForEach-Object {
                    $cd = $null
                    if ($_.CreationDate) {
                        try { $cd = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate) } catch { $cd = $_.CreationDate }
                    }
                    New-Object PSObject -Property @{
                        PID          = [int]$_.ProcessId
                        Path         = $_.ExecutablePath
                        CommandLine  = $_.CommandLine
                        CreationDate = $cd
                    }
                })
        } catch { }
    }
    $baseName = [IO.Path]::GetFileNameWithoutExtension($ExeName)
    return @(Get-Process -Name $baseName -ErrorAction SilentlyContinue |
        ForEach-Object {
            $pPath = $null; $pStart = $null
            try { $pPath = $_.Path } catch { }
            try { $pStart = $_.StartTime } catch { }
            New-Object PSObject -Property @{
                PID          = [int]$_.Id
                Path         = $pPath
                CommandLine  = $null
                CreationDate = $pStart
            }
        })
}

function Get-AdbProcessList {
    Get-ProcessListByName -ExeName 'adb.exe'
}

function Get-GnirehtetProcessList {
    Get-ProcessListByName -ExeName 'gnirehtet.exe'
}

function Find-PathExecutables {
    param([string]$FileName)
    $hits = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $env:PATH) { return @() }
    foreach ($dir in ($env:PATH -split ';')) {
        $d = $dir.Trim().Trim('"')
        if (-not $d) { continue }
        $candidate = Join-Path $d $FileName
        $exists = $false
        try { $exists = Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue } catch { $exists = $false }
        if ($exists) {
            $full = $candidate
            try { $full = [IO.Path]::GetFullPath($candidate) } catch { }
            $key = $full.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $hits.Add($full)
            }
        }
    }
    return $hits.ToArray()
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 20,
        [string]$WorkingDirectory = ''
    )

    $outFile = Join-Path $env:TEMP ('cap-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ('cap-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $result = New-Object PSObject -Property @{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false }

    try {
        $spParams = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($Arguments -and $Arguments.Count -gt 0) {
            $spParams['ArgumentList'] = $Arguments
        }
        if ($WorkingDirectory) {
            $spParams['WorkingDirectory'] = $WorkingDirectory
        }
        $proc = Start-Process @spParams
        # 缓存进程句柄，避免 Windows PowerShell 2.0/5.1 下 WaitForExit 后 ExitCode 为 $null
        $null = $proc.Handle
        # 只等这一个进程，避免 adb server 继承句柄导致管道挂起
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $proc.Kill() } catch { }
        } else {
            $proc.WaitForExit()
            $result.ExitCode = $proc.ExitCode
        }
        if (Test-Path -LiteralPath $outFile) {
            $result.StdOut = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
        }
        if (Test-Path -LiteralPath $errFile) {
            $result.StdErr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
        }
    } catch {
        $result.StdErr = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $result
}

function Get-AdbVersionInfo {
    param([string]$Exe)
    $result = New-Object PSObject -Property @{ Ok = $false; Build = $null; Raw = '' }
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

function Invoke-EnvPreflight {
    param([string]$Root = '')
    $Root = Resolve-PackageRoot -Root $Root

    $p = Get-GnirehtetPaths -Root $Root
    $findings = New-Object System.Collections.Generic.List[object]
    $pkgAdbVersion = Get-AdbVersionInfo -Exe $p.AdbExe

    # ---------------------------------------------------- 1) PATH 里的 adb
    $pathAdbAll = @(Find-PathExecutables -FileName 'adb.exe')
    $pathAdb = if ($pathAdbAll.Count -gt 0) { $pathAdbAll[0] } else { $null }

    if (-not $pathAdb) {
        $findings.Add((New-Finding -Severity INFO -Id 'path-adb-none' `
            -Title 'PATH 中没有 adb.exe' `
            -Detail '直接双击或裸跑 gnirehtet.exe 时会找不到 adb（gnirehtet 调用的是 PATH 里的 adb）。' `
            -Fix '直接双击根目录 gnirehtet.bat 运行，它会自动配置本包 adb。'))
    } elseif (Test-SamePath $pathAdb $p.AdbExe) {
        $findings.Add((New-Finding -Severity INFO -Id 'path-adb-ok' `
            -Title 'PATH 优先命中本包 adb' `
            -Detail $p.AdbExe -Evidence @("$($pathAdbAll.Count) 个 adb 条目")))
    } else {
        $extraPaths = @()
        if ($pathAdbAll.Count -gt 1) {
            for ($idx = 1; $idx -lt $pathAdbAll.Count; $idx++) {
                $extraPaths += ('其次：' + $pathAdbAll[$idx])
            }
        }
        $findings.Add((New-Finding -Severity WARN -Id 'path-adb-other' `
            -Title 'PATH 里先命中的不是本包 adb' `
            -Detail 'gnirehtet 默认通过 PATH 查找 adb，入口会在本次进程内自动置顶本包 adb。' `
            -Fix '通过根目录 gnirehtet.bat 运行即可自动规避，不改系统 PATH。' `
            -Evidence (@($pathAdb) + $extraPaths)))
    }

    # ---------------------------------------------------- 2) adb server 端口（默认 5037）
    $adbPort = Get-AdbServerPort
    $server = @(Get-PortOwners -Port $adbPort -ListenOnly)
    if ($server.Count -eq 0) {
        $findings.Add((New-Finding -Severity INFO -Id 'adb-server-none' `
            -Title "$adbPort 上没有 adb server 在跑" `
            -Detail '当前环境是干净的；实机时本包 adb 会自行拉起 server。'))
    } else {
        $seenAdbPids = @{}
        foreach ($s in $server) {
            if ($s.PID) {
                if ($seenAdbPids.ContainsKey($s.PID)) { continue }
                $seenAdbPids[$s.PID] = $true
            }

            if ($s.Name -ine 'adb.exe') {
                $procLabel = if ($s.Name) { $s.Name } else { '未知进程' }
                $findings.Add((New-Finding -Severity BLOCKER -Id 'adb-port-non-adb' `
                    -Title "$adbPort 端口被非 adb 程序占用" `
                    -Detail "占用者：$procLabel（PID $($s.PID)）。不是 adb.exe，脚本不会调用它；adb 无法在此端口启动。" `
                    -Fix '可以在入口选择换用隔离端口 5099 或关闭该进程。' `
                    -Evidence @("$($s.Local)  PID $($s.PID)  $($s.Path)")))
                continue
            }

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
                    -Detail "PID $($s.PID) 由本包 adb 启动（端口 $adbPort），属于可安全回收的自身残留。$verNote" `
                    -Fix '入口会自动复用或清理。' `
                    -Evidence @("$($s.Local)  PID $($s.PID)  $($s.Path)") -AutoFix))
            } else {
                $sameVersion = ($srvVer.Ok -and $pkgAdbVersion.Ok -and $srvVer.Build -eq $pkgAdbVersion.Build)
                $findings.Add((New-Finding -Severity $(if ($sameVersion) { 'WARN' } else { 'BLOCKER' }) -Id 'adb-server-foreign' `
                    -Title $(if ($sameVersion) { "$adbPort 由其他工具启动，但版本一致" } else { "$adbPort 被其他 adb server 占用" }) `
                    -Detail "这是别的工具链（不是本包）启动的 server。$verNote$(if ($sameVersion) { ' 版本一致，可以直接共用，不会互相重启。' } else { ' 重启会打断对方正在进行的调试或安装。' })" `
                    -Fix $(if ($sameVersion) {
                            '可以直接共用。'
                        } else {
                            '可在入口直接选择换用隔离端口 5099 或关闭对方服务。'
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
        $seen31416Pids = @{}
        foreach ($s in $listen31416) {
            if ($s.PID) {
                if ($seen31416Pids.ContainsKey($s.PID)) { continue }
                $seen31416Pids[$s.PID] = $true
            }
            $isOwn = ($s.Name -ieq 'gnirehtet.exe')
            $findings.Add((New-Finding -Severity $(if ($isOwn) { 'WARN' } else { 'BLOCKER' }) -Id 'port-31416-busy' `
                -Title '31416 已被占用' `
                -Detail "占用者：$($s.Name)（PID $($s.PID)）。$($(if ($isOwn) { '看起来是本包 relay 残留。' } else { '不是 gnirehtet，启动 relay 会失败。' }))" `
                -Fix $(if ($isOwn) { '入口会自动清理本包残留。' } else { '需要关闭占用 31416 的程序后继续。' }) `
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
            -Fix '建议只保留一份 adb 服务运行。' `
            -Evidence @($runningPaths)))
    }

    # ---------------------------------------------------- 5) 环境变量干扰
    if ($env:ANDROID_ADB_SERVER_PORT) {
        $parsedPort = 0
        $validPort = [int]::TryParse($env:ANDROID_ADB_SERVER_PORT.Trim(), [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535
        if ($validPort) {
            $findings.Add((New-Finding -Severity INFO -Id 'env-adb-port' `
                -Title "已设置 ANDROID_ADB_SERVER_PORT = $parsedPort" `
                -Detail "本次体检和后续 adb 命令都会使用端口 $parsedPort（而非默认 5037）。"))
        } else {
            $findings.Add((New-Finding -Severity WARN -Id 'env-adb-port-invalid' `
                -Title "ANDROID_ADB_SERVER_PORT 无效：$($env:ANDROID_ADB_SERVER_PORT)" `
                -Detail '端口值不在 1-65535 范围内，脚本已回退检查 5037，但 adb 自身可能报错。' `
                -Fix '清掉该环境变量，或改为合法端口号。'))
        }
    }
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
    foreach ($var in @('ANDROID_HOME', 'ANDROID_SDK_ROOT')) {
        if ([Environment]::GetEnvironmentVariable($var)) {
            $findings.Add((New-Finding -Severity INFO -Id "env-$var" `
                -Title "$var = $([Environment]::GetEnvironmentVariable($var))" `
                -Detail 'gnirehtet 不使用这些变量（它只按 ADB 环境变量或 PATH 找 adb）。'))
        }
    }

    # ---------------------------------------------------- 6) 本包进程残留
    $runningGn = @(Get-GnirehtetProcessList)
    if ($runningGn.Count -gt 0) {
        $findings.Add((New-Finding -Severity WARN -Id 'gnirehtet-running' `
            -Title '已有 gnirehtet 进程在运行' `
            -Detail '重复启动会争用 31416；也可能是上次没有正常退出。' `
            -Fix '入口会自动清理本包残留进程。' `
            -Evidence @($runningGn | ForEach-Object { "PID $($_.PID)  $($_.CommandLine)" })))
    }

    # ---------------------------------------------------- 7) 本包 adb 版本
    if (-not $pkgAdbVersion.Ok) {
        $findings.Add((New-Finding -Severity WARN -Id 'pkg-adb-broken' `
            -Title '本包 adb 无法返回版本' `
            -Detail ($pkgAdbVersion.Raw -replace '\s+', ' ') `
            -Fix 'Windows 7 老环境可能缺少运行库，入口会自动安装 deps\vc_redist.x86.exe。'))
    }

    # ---------------------------------------------------- 汇总
    $blockers = @($findings | Where-Object { $_.Severity -eq 'BLOCKER' })
    $warns    = @($findings | Where-Object { $_.Severity -eq 'WARN' })
    $infos    = @($findings | Where-Object { $_.Severity -eq 'INFO' })

    New-Object PSObject -Property @{
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
