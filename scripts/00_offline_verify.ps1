<#
.SYNOPSIS
    gnirehtet 反向 USB 工具包离线验收（只读）。

.DESCRIPTION
    只做检查，不启动隧道、不连接手机、不改防火墙、不改路由、不杀进程。
    检查项：
      1. 目录结构
      2. 必需文件（大小 + SHA256），并与 manifest.json 比对
      3. adb version（本地执行，不启动 adb server）
      4. TCP 31416 占用情况（含占用进程）
      5. 现有防火墙规则（按名称 gnirehtet / 按端口 31416 查询）
      6. 脚本语法解析
      7. 环境预检（与其它服务的干扰风险，见 lib\EnvCheck.ps1）
    结果写入 logs\offline-verify-<时间戳>.txt（UTF-8）。

.PARAMETER Root
    包根目录，默认取脚本所在包的根目录（整包可移动，无需指定）。

.PARAMETER SkipFirewallScan
    跳过防火墙规则扫描（规则很多、CIM 较慢时使用）。

.PARAMETER LogFile
    自定义日志路径，默认 logs\offline-verify-yyyyMMdd-HHmmss.txt。

.NOTES
    退出码：0 = 全部通过；2 = 包本身有阻断项（缺文件 / adb 异常 / 端口占用 / 语法错误）；
            3 = 包通过但环境未就绪（有会与其他服务互相干扰的因素）。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$SkipFirewallScan,
    [string]$LogFile
)

$ErrorActionPreference = 'Continue'

# 绿色版：兼容 PowerShell 2.0 ~ 7.x，不带参数时以包自身位置为准
$script:VerifyDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $script:VerifyDir }

$ToolsDir     = Join-Path $Root 'tools\gnirehtet'
$DepsDir      = Join-Path $Root 'deps'
$LogsDir      = Join-Path $Root 'logs'
$ScriptsDir   = Join-Path $Root 'scripts'
$ManifestPath = Join-Path $Root 'manifest.json'
$EnvLibPath = Join-Path $ScriptsDir 'lib\EnvCheck.ps1'
$script:EnvLibLoaded = $false
if (Test-Path -LiteralPath $EnvLibPath) {
    try {
        . $EnvLibPath
        $script:EnvLibLoaded = $true
    } catch { }
}

if (-not (Get-Command Get-OsDescription -ErrorAction SilentlyContinue)) {
    function Get-OsDescription {
        $rt = 'System.Runtime.InteropServices.RuntimeInformation' -as [type]
        if ($rt) { try { return ([string]$rt::OSDescription).Trim() } catch { } }
        return [Environment]::OSVersion.VersionString
    }
}
if (-not (Get-Command Get-FileSha256 -ErrorAction SilentlyContinue)) {
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
}

if (-not $LogFile) {
    $LogFile = Join-Path $LogsDir ('offline-verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
}
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

$script:Lines  = New-Object System.Collections.Generic.List[string]
$script:Checks = New-Object System.Collections.Generic.List[object]

function Add-Line {
    param([string]$Text = '')
    $script:Lines.Add($Text)
    Write-Host $Text
}

function Add-Section {
    param([string]$Title)
    Add-Line ''
    Add-Line ('=' * 72)
    Add-Line $Title
    Add-Line ('=' * 72)
}

function Add-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Detail = '',
        [switch]$Blocking
    )
    $script:Checks.Add((New-Object PSObject -Property @{
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Blocking = [bool]$Blocking
    }))
    $tag = switch ($Status) {
        'PASS' { '[PASS]' }
        'WARN' { '[WARN]' }
        'FAIL' { '[FAIL]' }
        'INFO' { '[INFO]' }
    }
    Add-Line ('{0} {1}{2}' -f $tag, $Name, $(if ($Detail) { ' —— ' + $Detail } else { '' }))
}

function Invoke-Captured {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 20
    )
    $outFile = Join-Path $env:TEMP ('ov-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ('ov-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $result = New-Object PSObject -Property @{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false }
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $p.Kill() } catch { }
        } else {
            $p.WaitForExit()
            $result.ExitCode = $p.ExitCode
        }
        if (Test-Path -LiteralPath $outFile) { $result.StdOut = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) }
        if (Test-Path -LiteralPath $errFile) { $result.StdErr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) }
    } catch {
        $result.StdErr = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $result
}

try {
    # ------------------------------------------------------------ 头部
    $elevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

    Add-Line 'gnirehtet 反向 USB 工具包 —— 离线验收报告'
    Add-Line ('生成时间   : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
    Add-Line ('计算机名   : ' + $env:COMPUTERNAME)
    Add-Line ('当前用户   : ' + $env:USERNAME + $(if ($elevated) { '（已提权）' } else { '（未提权）' }))
    Add-Line ('包根目录   : ' + $Root)
    Add-Line ('日志文件   : ' + $LogFile)
    Add-Line ('PowerShell : ' + $PSVersionTable.PSVersion.ToString())
    Add-Line ('操作系统   : ' + (Get-OsDescription))
    Add-Line ('进程位数   : ' + $(if ([Environment]::Is64BitProcess) { '64 位' } else { '32 位' }))
    Add-Line '模式       : 只读验收（不连手机、不启动隧道、不改防火墙、不改路由）'

    # ------------------------------------------------------------ 1 目录结构
    Add-Section '1. 目录结构'
    # 必需目录：缺了就没法用
    $requiredDirs = @(
        $Root,
        (Join-Path $Root 'scripts'),
        (Join-Path $Root 'tools'),
        $ToolsDir,
        $DepsDir
    )
    foreach ($d in $requiredDirs) {
        if (Test-Path -LiteralPath $d -PathType Container) {
            Add-Line ('[PASS] 目录存在：' + $d)
        } else {
            Add-Check -Name "目录缺失：$d" -Status FAIL -Blocking
        }
    }

    # 可选目录：绿色包里可能还没生成，运行时自动创建，不算问题
    foreach ($name in 'download', 'logs') {
        $d = Join-Path $Root $name
        if (Test-Path -LiteralPath $d -PathType Container) {
            Add-Line ('[PASS] 目录存在：' + $d)
        } else {
            Add-Line ('[INFO] 可选目录未生成：' + $d + '（首次运行会自动创建）')
        }
    }

    # ------------------------------------------------------------ 2 必需文件
    Add-Section '2. 必需文件'
    $required = @(
        @{ Name = 'gnirehtet.exe';    Min = 1000;  Desc = 'gnirehtet 主程序' },
        @{ Name = 'gnirehtet.apk';    Min = 10000; Desc = 'Android 客户端 APK' },
        @{ Name = 'adb.exe';          Min = 1000;  Desc = 'Android 调试桥' },
        @{ Name = 'AdbWinApi.dll';    Min = 1000;  Desc = 'adb Win32 API 依赖' },
        @{ Name = 'AdbWinUsbApi.dll'; Min = 1000;  Desc = 'adb USB 依赖' }
    )

    $fileHashes = @{}
    foreach ($r in $required) {
        $p = Join-Path $ToolsDir $r.Name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Add-Check -Name "缺少文件 $($r.Name)" -Status FAIL -Detail $r.Desc -Blocking
            continue
        }
        $item = Get-Item -LiteralPath $p
        if ($item.Length -lt $r.Min) {
            Add-Check -Name "文件过小 $($r.Name)" -Status FAIL -Detail "$($item.Length) 字节，$($r.Desc)" -Blocking
            continue
        }
        $hash = Get-FileSha256 -Path $p
        $fileHashes[$r.Name] = $hash
        Add-Check -Name $r.Name -Status PASS -Detail ('{0} 字节  {1}  {2}' -f $item.Length, $hash.Substring(0, 16), $r.Desc)
    }

    # 检查根目录唯一入口与 Win7 离线依赖
    $entryBat = Join-Path $Root 'gnirehtet.bat'
    if (Test-Path -LiteralPath $entryBat -PathType Leaf) {
        Add-Check -Name 'gnirehtet.bat' -Status PASS -Detail '根目录唯一入口存在'
    } else {
        Add-Check -Name '缺少根目录入口 gnirehtet.bat' -Status FAIL -Blocking
    }

    $depRequired = @(
        @{ Rel = 'vc_redist.x86.exe'; Min = 5000000; Desc = '微软 VC++ 2015-2022 x86 运行库（Win7 UCRT）' },
        @{ Rel = 'UniversalAdbDriverSetup.msi'; Min = 1000000; Desc = '通用 Android ADB USB 驱动' },
        @{ Rel = 'google-usb-driver\android_winusb.inf'; Min = 1000; Desc = 'Google 官方 USB 驱动 INF' }
    )
    foreach ($dr in $depRequired) {
        $dp = Join-Path $DepsDir $dr.Rel
        if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) {
            Add-Check -Name "缺少离线依赖 deps\$($dr.Rel)" -Status FAIL -Detail $dr.Desc -Blocking
            continue
        }
        $dItem = Get-Item -LiteralPath $dp
        if ($dItem.Length -lt $dr.Min) {
            Add-Check -Name "离线依赖过小 deps\$($dr.Rel)" -Status FAIL -Detail "$($dItem.Length) 字节，$($dr.Desc)" -Blocking
            continue
        }
        Add-Check -Name "deps\$($dr.Rel)" -Status PASS -Detail ('{0} 字节  {1}' -f $dItem.Length, $dr.Desc)
    }

    Add-Line ''
    Add-Line '同目录其他文件：'
    $others = Get-ChildItem -LiteralPath $ToolsDir -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and ($required.Name -notcontains $_.Name) }
    if ($others) {
        foreach ($o in $others) { Add-Line ('  - {0,-24} {1,10} 字节' -f $o.Name, $o.Length) }
    } else {
        Add-Line '  （无）'
    }

    # 与 manifest 比对
    Add-Line ''
    if (Test-Path -LiteralPath $ManifestPath) {
        if (-not (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue)) {
            Add-Check -Name 'manifest.json 比对' -Status INFO -Detail 'PowerShell 2.0 无 ConvertFrom-Json，跳过 JSON 解析比对'
        } else {
        try {
            $manifestRaw = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
            $manifest = $manifestRaw | ConvertFrom-Json
            Add-Line ('构建清单   : ' + $ManifestPath)
            Add-Line ('构建时间   : ' + $manifest.createdAt)
            if ($manifest.machine) { Add-Line ('构建主机   : ' + $manifest.machine) }
            Add-Line ('gnirehtet  : v' + $manifest.gnirehtetVersion)

            $manifestMap = @{}
            foreach ($t in @($manifest.tools)) {
                if ($t.file) { $manifestMap[$t.file] = [string]$t.sha256 }
            }

            $mismatch = @()
            $missingInManifest = @()
            foreach ($r in $required) {
                if (-not $manifestMap.ContainsKey($r.Name)) {
                    $missingInManifest += $r.Name
                } elseif ($fileHashes.ContainsKey($r.Name) -and $fileHashes[$r.Name] -ne $manifestMap[$r.Name]) {
                    $mismatch += $r.Name
                }
            }

            $untrackedBins = @()
            foreach ($o in @($others)) {
                if ($manifestMap.ContainsKey($o.Name)) {
                    $oHash = Get-FileSha256 -Path $o.FullName
                    if ($oHash -ne $manifestMap[$o.Name]) {
                        $mismatch += $o.Name
                    }
                } elseif (@('.exe', '.dll', '.cmd', '.bat', '.ps1') -contains $o.Extension) {
                    $untrackedBins += $o.Name
                }
            }

            if ($mismatch.Count -eq 0 -and $missingInManifest.Count -eq 0) {
                Add-Check -Name 'manifest 哈希一致性' -Status PASS -Detail '所有必需文件及已登记附带文件与构建清单一致'
            } else {
                $parts = @()
                if ($mismatch.Count -gt 0) { $parts += ('哈希不匹配：' + ($mismatch -join ', ')) }
                if ($missingInManifest.Count -gt 0) { $parts += ('清单缺少条目：' + ($missingInManifest -join ', ')) }
                Add-Check -Name 'manifest 哈希不一致' -Status FAIL -Detail ($parts -join '；') -Blocking
            }
            if ($untrackedBins.Count -gt 0) {
                Add-Check -Name '同目录存在清单外可执行/库文件' -Status WARN -Detail ($untrackedBins -join ', ')
            }
        } catch {
            Add-Check -Name 'manifest.json 解析' -Status WARN -Detail $_.Exception.Message
        }
        }
    } else {
        Add-Check -Name 'manifest.json 缺失' -Status WARN -Detail '无法核对构建来源，建议重新运行 build_package.ps1'
    }

    # ------------------------------------------------------------ 3 adb version
    Add-Section '3. adb version'
    $adbPath = Join-Path $ToolsDir 'adb.exe'
    if (-not (Test-Path -LiteralPath $adbPath)) {
        Add-Check -Name 'adb version' -Status FAIL -Detail 'adb.exe 不存在，无法执行' -Blocking
    } else {
        $r = Invoke-Captured -FilePath $adbPath -Arguments @('version') -TimeoutSeconds 20
        if ($r.TimedOut) {
            Add-Check -Name 'adb version' -Status FAIL -Detail '执行超时（20s），未强制结束后续步骤' -Blocking
        } elseif ($r.ExitCode -ne 0) {
            Add-Check -Name 'adb version' -Status FAIL -Detail "退出码 $($r.ExitCode)" -Blocking
            foreach ($l in ($r.StdErr -split "`r?`n" | Where-Object { $_.Trim() })) { Add-Line ('       ' + $l) }
        } else {
            $text = (($r.StdOut + $r.StdErr) -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | '
            Add-Check -Name 'adb version' -Status PASS -Detail $text
        }
    }

    # ------------------------------------------------------------ 4 端口 31416
    Add-Section '4. TCP 31416 占用情况'
    # 兼容 Win7（无 Get-NetTCPConnection 时自动降级 netstat）
    $port31416 = if (Get-Command Get-TcpPortConnections -ErrorAction SilentlyContinue) {
        @(Get-TcpPortConnections -Port 31416)
    } else {
        @(Get-NetTCPConnection -LocalPort 31416 -ErrorAction SilentlyContinue)
    }

    if ($port31416.Count -eq 0) {
        Add-Check -Name '端口 31416' -Status PASS -Detail '当前无监听/连接，可分配'
    } else {
        Add-Check -Name '端口 31416 已被占用' -Status FAIL -Detail 'gnirehtet relay 默认监听此端口，需先由人工处理' -Blocking
        foreach ($c in $port31416) {
            $procName = ''
            $procPath = ''
            try {
                $proc = Get-Process -Id $c.OwningProcess -ErrorAction Stop
                $procName = $proc.ProcessName
                $procPath = $proc.Path
            } catch {
                $procName = '（无法读取进程信息，可能为其他用户或已退出）'
            }
            Add-Line ('       {0}:{1} -> {2}:{3}  {4}  PID={5}  {6}' -f `
                $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $c.State, $c.OwningProcess, $procName)
            if ($procPath) { Add-Line ('       可执行文件: ' + $procPath) }
        }
    }

    # ------------------------------------------------------------ 5 防火墙
    Add-Section '5. 现有防火墙规则（只读查询）'
    if ($SkipFirewallScan) {
        Add-Check -Name '防火墙规则扫描' -Status INFO -Detail '已按参数跳过'
    } else {
        $fwOk = $true
        $allCount = 0
        $nameRules = @()
        $portRules = @()
        try {
            if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
                $allRules = @(Get-NetFirewallRule -ErrorAction Stop)
                $allCount = $allRules.Count
                $nameRules = @($allRules | Where-Object { $_.DisplayName -like '*gnirehtet*' -or $_.Name -like '*gnirehtet*' })

                $portFilters = @(Get-NetFirewallPortFilter -ErrorAction Stop)
                $idsFor31416 = @{}
                foreach ($pf in $portFilters) {
                    foreach ($p in @($pf.LocalPort)) {
                        if ([string]$p -eq '31416') { $idsFor31416[$pf.InstanceID] = $true }
                    }
                }
                if ($idsFor31416.Count -gt 0) {
                    $portRules = @($allRules | Where-Object { $idsFor31416.ContainsKey($_.InstanceID) })
                }
            } else {
                # Windows 7 兜底：使用 COM HNetCfg.FwPolicy2 只读枚举防火墙规则
                $fwPolicy = New-Object -ComObject HNetCfg.FwPolicy2
                $nList = New-Object System.Collections.Generic.List[object]
                $pList = New-Object System.Collections.Generic.List[object]
                foreach ($r in $fwPolicy.Rules) {
                    $allCount++
                    $obj = New-Object PSObject -Property @{
                        DisplayName = [string]$r.Name
                        Enabled     = [bool]$r.Enabled
                        Direction   = if ($r.Direction -eq 1) { 'Inbound' } else { 'Outbound' }
                        Action      = if ($r.Action -eq 1) { 'Allow' } else { 'Block' }
                        Profile     = [string]$r.Profiles
                    }
                    if ($obj.DisplayName -like '*gnirehtet*') { $nList.Add($obj) }
                    if ($r.LocalPorts -and (([string]$r.LocalPorts -split ',') -contains '31416')) { $pList.Add($obj) }
                }
                $nameRules = $nList.ToArray()
                $portRules = $pList.ToArray()
            }
        } catch {
            $fwOk = $false
            Add-Check -Name '防火墙规则查询' -Status WARN -Detail ('查询受限：' + $_.Exception.Message)
        }

        if ($fwOk) {
            Add-Line ('规则总数      : ' + $allCount)
            Add-Line ('名称含 gnirehtet : ' + $nameRules.Count + ' 条')
            foreach ($r in $nameRules) {
                Add-Line ('  - {0} | 启用={1} 方向={2} 动作={3}' -f $r.DisplayName, $r.Enabled, $r.Direction, $r.Action)
            }
            Add-Line ('匹配端口 31416 : ' + $portRules.Count + ' 条')
            foreach ($r in $portRules) {
                Add-Line ('  - {0} | 启用={1} 方向={2} 动作={3} 配置文件={4}' -f $r.DisplayName, $r.Enabled, $r.Direction, $r.Action, $r.Profile)
            }
            if ($nameRules.Count -eq 0 -and $portRules.Count -eq 0) {
                Add-Check -Name '防火墙放行规则' -Status WARN -Detail '未发现 gnirehtet / 31416 相关规则，符合“未改动”预期；实机联调时需人工决定是否添加'
            } else {
                Add-Check -Name '防火墙放行规则' -Status INFO -Detail '已存在相关规则，保持原样未改动'
            }
            if (-not $elevated) {
                Add-Line '提示：当前未提权，个别系统规则可能不可见，不影响“未改动”结论。'
            }
        }
    }

    # ------------------------------------------------------------ 6 脚本语法
    Add-Section '6. 脚本语法检查'
    $psFiles = @()
    if (Test-Path -LiteralPath $ScriptsDir) {
        $psFiles += @(Get-ChildItem -LiteralPath $ScriptsDir -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    }
    if ($psFiles.Count -eq 0) {
        Add-Check -Name '脚本语法' -Status WARN -Detail 'scripts\ 下没有 .ps1 文件'
    } else {
        $parserType = 'System.Management.Automation.Language.Parser' -as [type]
        foreach ($f in $psFiles) {
            $tokens = $null
            $errors = $null
            if ($parserType) {
                [void]$parserType::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
                if ($errors -and $errors.Count -gt 0) {
                    Add-Check -Name "语法错误：$($f.Name)" -Status FAIL -Detail "$($errors.Count) 处" -Blocking
                    foreach ($e in $errors) {
                        Add-Line ('       L{0}: {1}' -f $e.Extent.StartLineNumber, $e.Message)
                    }
                } else {
                    Add-Check -Name "语法 $($f.Name)" -Status PASS -Detail "解析通过（$($tokens.Count) 个 token）"
                }
            } else {
                $src = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                $tokens = [System.Management.Automation.PSParser]::Tokenize($src, [ref]$errors)
                if ($errors -and $errors.Count -gt 0) {
                    Add-Check -Name "语法错误：$($f.Name)" -Status FAIL -Detail "$($errors.Count) 处" -Blocking
                } else {
                    Add-Check -Name "语法 $($f.Name)" -Status PASS -Detail "PS2.0 解析通过（$($tokens.Count) 个 token）"
                }
            }
        }
    }

    # ------------------------------------------------------------ 7 环境预检
    Add-Section '7. 环境预检（是否与其他服务互相干扰）'
    $envPre = $null
    if ($script:EnvLibLoaded -or (Test-Path -LiteralPath $EnvLibPath)) {
        try {
            if (-not $script:EnvLibLoaded) { . $EnvLibPath }
            $envPre = Invoke-EnvPreflight -Root $Root
            foreach ($sev in @('BLOCKER', 'WARN', 'INFO')) {
                foreach ($f in $envPre.Findings | Where-Object { $_.Severity -eq $sev }) {
                    foreach ($l in (Format-EnvFinding -Finding $f)) { Add-Line $l }
                }
            }
            $envStatus = if ($envPre.Blockers -gt 0) { 'FAIL' } elseif ($envPre.Warnings -gt 0) { 'WARN' } else { 'PASS' }
            Add-Check -Name '环境就绪度' -Status $envStatus `
                -Detail ("阻断 {0} 项 / 注意 {1} 项 / 信息 {2} 项" -f $envPre.Blockers, $envPre.Warnings, $envPre.Infos)
        } catch {
            Add-Check -Name '环境预检' -Status WARN -Detail ('执行失败：' + $_.Exception.Message)
        }
    } else {
        Add-Check -Name '环境预检库缺失' -Status WARN -Detail "缺少 $EnvLibPath，跳过干扰检查"
    }

    $drive = (Get-Item -LiteralPath $Root).PSDrive
    if ($drive -and $drive.Free) {
        $freeGb = [math]::Round($drive.Free / 1GB, 2)
        $status = if ($freeGb -lt 1) { 'WARN' } else { 'INFO' }
        Add-Check -Name '磁盘剩余空间' -Status $status -Detail ("{0}: {1} GB 可用" -f $drive.Name, $freeGb)
    }

    # ------------------------------------------------------------ 汇总
    Add-Section '8. 汇总'
    $pass = @($script:Checks | Where-Object { $_.Status -eq 'PASS' }).Count
    $warn = @($script:Checks | Where-Object { $_.Status -eq 'WARN' }).Count
    $fail = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    $blocking = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' -and $_.Blocking }).Count
    $envBlockers = if ($envPre) { $envPre.Blockers } else { 0 }
    $envWarns = if ($envPre) { $envPre.Warnings } else { 0 }

    Add-Line ("PASS {0} 项 / WARN {1} 项 / FAIL {2} 项" -f $pass, $warn, $fail)
    Add-Line ("其中：包完整性阻断 {0} 项，环境干扰阻断 {1} 项" -f $blocking, $envBlockers)
    if ($fail -gt 0) {
        Add-Line ''
        Add-Line '未通过项：'
        foreach ($c in $script:Checks | Where-Object { $_.Status -eq 'FAIL' }) {
            Add-Line ('  - ' + $c.Name + $(if ($c.Detail) { '：' + $c.Detail } else { '' }))
        }
    }
    if ($warn -gt 0) {
        Add-Line ''
        Add-Line '需关注项：'
        foreach ($c in $script:Checks | Where-Object { $_.Status -eq 'WARN' }) {
            Add-Line ('  - ' + $c.Name + $(if ($c.Detail) { '：' + $c.Detail } else { '' }))
        }
    }
    Add-Line ''
    if ($blocking -gt 0) {
        Add-Line '结论：未通过（包本身存在阻断项，需人工处理后重跑本脚本）'
        $script:ExitCode = 2
    } elseif ($envBlockers -gt 0) {
        Add-Line ('结论：包通过，但环境未就绪（{0} 项阻断）。先跑 10_env_preflight.ps1 处理环境，再进入实机。' -f $envBlockers)
        $script:ExitCode = 3
    } else {
        Add-Line '结论：通过（离线准备完成，环境无阻断，可进入实机验证阶段）'
        $script:ExitCode = 0
    }
}
catch {
    Add-Line ''
    Add-Line ('[FAIL] 验收脚本异常中止：' + $_.Exception.Message)
    Add-Line ($_.ScriptStackTrace)
    $script:ExitCode = 2
}
finally {
    try {
        $logParent = Split-Path -Parent $LogFile
        if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
            New-Item -ItemType Directory -Force -Path $logParent | Out-Null
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($LogFile, $script:Lines, $utf8)
        Write-Host ''
        Write-Host ('日志已写入：' + $LogFile)
    } catch {
        Write-Warning ('写入日志失败：' + $_.Exception.Message)
    }
}

exit $(if ($null -ne $script:ExitCode) { $script:ExitCode } else { 2 })
