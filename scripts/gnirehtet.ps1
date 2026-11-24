<#
.SYNOPSIS
    gnirehtet 统一入口：先过环境闸门，再只在该问的地方问你。

.DESCRIPTION
    设计原则：能自动判断的都不问。
      · 只连一台手机      → 直接用，不打扰
      · 连了多台手机      → 列出来让你选编号
      · 只读操作（status）→ 直接执行，不确认
      · 要动手机的操作（install / run / stop）→ 给一句话摘要，回车继续
      · 自动化场景        → 加 -Yes（不再问）+ -Serial（多台时指定）

    所有实机操作都走这里，避免裸跑 gnirehtet.exe 时用错 adb 或与别的服务冲突。
    执行时把本包目录临时放到进程 PATH 最前面，只影响本次调用。

.PARAMETER Action
    preflight（默认）| status | install | run | stop

.PARAMETER Root
    包根目录，默认取脚本所在包的根目录（整包可移动，无需指定）。

.PARAMETER Serial
    设备序列号；有多台设备时用它指定，避免被问。

.PARAMETER Yes
    跳过确认（install / run / stop），用于脚本或无人值守。

.PARAMETER Force
    环境体检有阻断项时仍然继续（确认可以打断对方服务时使用）。

.EXAMPLE
    pwsh -NoProfile -File scripts\gnirehtet.ps1
    pwsh -NoProfile -File scripts\gnirehtet.ps1 -Action status

.NOTES
    退出码：0 = 成功；3 = 闸门拒绝或环境未就绪；2 = 找不到可执行文件；其它为工具自身退出码。
#>
[CmdletBinding()]
param(
    [ValidateSet('preflight', 'status', 'install', 'run', 'stop')]
    [string]$Action = 'preflight',
    [string]$Root = '',
    [string]$Serial,
    [switch]$Yes,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 绿色版：不带参数时以包自身位置为准，整个目录可以随意搬动
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'lib\EnvCheck.ps1')
. (Join-Path $here 'lib\AdbDevices.ps1')

$p = Get-GnirehtetPaths -Root $Root

$missingTools = @($p.GnExe, $p.AdbExe, $p.GnApk | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingTools.Count -gt 0) {
    foreach ($m in $missingTools) {
        Write-Host "[阻断] 找不到 $m" -ForegroundColor Red
    }
    Write-Host '       → 先运行 scripts\build_package.ps1' -ForegroundColor Yellow
    exit 2
}

Write-Host ''
Write-Host '── 环境体检 ──────────────────────────────────────────'
$pre = Invoke-EnvPreflight -Root $Root

foreach ($f in $pre.Findings | Where-Object { $_.Severity -in @('BLOCKER', 'WARN') } | Sort-Object { $script:SeverityRank[$_.Severity] }) {
    foreach ($l in (Format-EnvFinding -Finding $f)) { Write-Host $l }
}
if ($pre.Blockers -eq 0 -and $pre.Warnings -eq 0) {
    Write-Host '[通过] 未发现干扰风险。'
}
Write-Host ''
Write-Host ('阻断 {0} 项 / 注意 {1} 项' -f $pre.Blockers, $pre.Warnings)
Write-Host ''

if ($Action -eq 'preflight') {
    if ($pre.Blockers -gt 0) {
        Write-Host '结论：暂不放行。'
        Write-Host '  想处理干扰：pwsh -NoProfile -File scripts\10_env_preflight.ps1 -Fix'
        Write-Host '  确认可以打断对方：在本命令后加 -Force'
    } else {
        Write-Host '结论：可以放行。下一步：'
        Write-Host '  1) -Action status   看看手机认到没有'
        Write-Host '  2) -Action install  装客户端（不会自动启动）'
        Write-Host '  3) -Action run      开始反向上网'
    }
    exit $(if ($pre.Blockers -gt 0) { 3 } else { 0 })
}

if ($pre.Blockers -gt 0 -and -not $Force) {
    Write-Host '拒绝执行：环境有阻断项，未指定 -Force。' -ForegroundColor Red
    Write-Host '已停止，未连接设备、未启动任何进程。' -ForegroundColor Red
    Write-Host ''
    Write-Host '想先处理干扰，可以运行：' -ForegroundColor Yellow
    Write-Host '  pwsh -NoProfile -File scripts\10_env_preflight.ps1 -Fix' -ForegroundColor Yellow
    Write-Host '它会一个一个问你，说「关」才关。' -ForegroundColor Yellow
    exit 3
}
if ($pre.Blockers -gt 0 -and $Force) {
    Write-Host '[警告] 已用 -Force 跳过阻断项，可能打断其它服务。' -ForegroundColor Yellow
    Write-Host ''
}

# 进程内临时置顶本包目录：只影响子进程，不改用户/系统 PATH
$env:PATH = "$($p.ToolsDir);$env:PATH"

# 先把 adb 服务用独立方式拉起来，避免第一次查询时 server 继承调用方的输出管道
if ($Action -ne 'preflight') {
    if (-not (Initialize-AdbServer -AdbExe $p.AdbExe)) {
        Write-Host '[注意] adb 服务没能启动，后面可能连不上设备。' -ForegroundColor Yellow
    }
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    Write-Host ('执行：' + $Exe + ' ' + ($Arguments -join ' ')) -ForegroundColor Cyan
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
        Write-Host '没找到手机。检查三件事：'
        Write-Host '  1. 数据线插好了吗（有的线只能充电，不能传数据）'
        Write-Host '  2. 手机上「设置 → 开发者选项 → USB 调试」打开了吗'
        Write-Host '  3. 手机弹窗点「允许」了吗（勾选“始终允许”以后不用再点）'
        return
    }

    Write-Host ("找到 {0} 台设备：" -f $Devices.Count)
    $i = 0
    foreach ($d in $Devices) {
        $i++
        Write-Host ("  [{0}] {1}  {2}" -f $i, (Get-DeviceLabel -Device $d), (Get-DeviceStateText -State $d.State))
    }
}

# 选设备：指定了 -Serial 就用它；只有一台直接用；多台才问
function Resolve-Device {
    $probe = Get-AdbDevices -AdbExe $p.AdbExe
    if (-not $probe.Ok) {
        Write-Host '[没连上 adb] 看看下面这行：' -ForegroundColor Red
        foreach ($l in ($probe.Raw -split "`r?`n" | Where-Object { $_.Trim() })) {
            Write-Host ('  ' + $l)
        }
        return $null
    }

    $all = @($probe.Devices)

    if ($Serial) {
        $hit = $all | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if (-not $hit) {
            Write-Host ("没找到序列号 {0} 的设备。" -f $Serial) -ForegroundColor Yellow
            Show-Devices -Devices $all
            return $null
        }
        if ($hit.State -ne 'device') {
            Write-Host ("{0} 现在不能用：{1}" -f (Get-DeviceLabel -Device $hit), (Get-DeviceStateText -State $hit.State)) -ForegroundColor Yellow
            return $null
        }
        Write-Host ("用 {0}。" -f (Get-DeviceLabel -Device $hit))
        return $hit
    }

    $usable = @($all | Where-Object State -eq 'device')

    if ($usable.Count -eq 0) {
        Show-Devices -Devices $all
        if ($all.Count -gt 0) {
            Write-Host ''
            Write-Host '设备在，但还不能操作：先在手机上点「允许」，或者拔插一次数据线。'
        }
        return $null
    }

    if ($usable.Count -eq 1) {
        Write-Host ("用 {0}。" -f (Get-DeviceLabel -Device $usable[0]))
        return $usable[0]
    }

    if ($Yes) {
        Write-Host '接了多台设备，自动模式（-Yes）下必须用 -Serial 指定是哪台。已停止。' -ForegroundColor Yellow
        Show-Devices -Devices $all
        return $null
    }

    Select-AdbDevice -Devices $all
}

# 动手机之前问一句；回车=继续，n=取消，其它输入也当继续（傻瓜化）
function Confirm-Step {
    param([string]$Question, [string]$Detail = '')

    Write-Host ''
    Write-Host $Question
    if ($Detail) { Write-Host ('  ' + $Detail) }

    if ($Yes) {
        Write-Host '  （-Yes：已自动继续）' -ForegroundColor DarkGray
        return $true
    }

    try { $answer = Read-Host '  按回车继续，输入 n 取消' } catch { return $false }
    if ($null -eq $answer) { return $false }
    return -not ($answer.Trim() -match '^(n|no|取消|算了)$')
}

switch ($Action) {

    'status' {
        $probe = Get-AdbDevices -AdbExe $p.AdbExe
        if (-not $probe.Ok) {
            Write-Host '[没连上 adb] 看看下面这行：' -ForegroundColor Red
            foreach ($l in ($probe.Raw -split "`r?`n" | Where-Object { $_.Trim() })) {
                Write-Host ('  ' + $l)
            }
            exit 2
        }
        Write-Host ''
        Show-Devices -Devices @($probe.Devices)
        Write-Host ''
        $usable = @($probe.Devices | Where-Object State -eq 'device')
        if ($usable.Count -gt 0) {
            Write-Host '下一步：-Action install（装客户端）或 -Action run（直接开始）'
        }
        exit 0
    }

    'install' {
        $dev = Resolve-Device
        if (-not $dev) { exit 3 }

        $ok = Confirm-Step -Question ("要给「{0}」安装 gnirehtet 客户端吗？" -f (Get-DeviceLabel -Device $dev)) `
            -Detail '装完不会自动启动，随时可以用 -Action stop 收尾。'
        if (-not $ok) { Write-Host ''; Write-Host '已取消，什么都没做。'; exit 0 }

        $code = Invoke-Tool -Exe $p.GnExe -Arguments @('install', $dev.Serial)
        Write-Host ''
        if ($code -eq 0) {
            Write-Host '装好了。下一步：-Action run 开始反向上网。'
        } else {
            Write-Host ("安装没成功（退出码 {0}）。常见原因：手机没授权、存储权限被拒、Android 版本不兼容。" -f $code) -ForegroundColor Yellow
        }
        exit $code
    }

    'run' {
        $dev = Resolve-Device
        if (-not $dev) { exit 3 }

        $ok = Confirm-Step -Question ("要给「{0}」开启反向网络吗？" -f (Get-DeviceLabel -Device $dev)) `
            -Detail '手机没装客户端时会先自动装好，然后在手机上建一个本地 VPN，把流量转到这台电脑。结束按 Ctrl+C。'
        if (-not $ok) { Write-Host ''; Write-Host '已取消，什么都没做。'; exit 0 }

        $code = Invoke-Tool -Exe $p.GnExe -Arguments @('run', $dev.Serial)
        Write-Host ''
        Write-Host '已结束。想确认收尾干净：-Action status'
        exit $code
    }

    'stop' {
        $dev = Resolve-Device
        if (-not $dev) { exit 3 }

        $ok = Confirm-Step -Question ("要停掉「{0}」上的 gnirehtet 吗？" -f (Get-DeviceLabel -Device $dev)) `
            -Detail '停掉后手机会恢复原来的上网方式。'
        if (-not $ok) { Write-Host ''; Write-Host '已取消，什么都没做。'; exit 0 }

        $code = Invoke-Tool -Exe $p.GnExe -Arguments @('stop', $dev.Serial)
        Write-Host ''
        if ($code -eq 0) { Write-Host '已经停了。' }
        exit $code
    }
}
