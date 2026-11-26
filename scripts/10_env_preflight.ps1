<#
.SYNOPSIS
    实机前的环境体检。默认只看不动；加 -Fix 可以交互式关掉干扰项。

.DESCRIPTION
    回答一个问题：现在启动 gnirehtet，会不会踩到别的服务 / 会不会被别的服务踩到。

    三种用法：
      · 直接运行           只看结果，什么都不改
      · -Apply             顺手清理“这套工具自己的”残留（自己的 adb 服务、下载临时文件）
      · -Fix               挨个问你要不要关掉干扰项，你确认后才关；可配 -DryRun 演练

    脚本永远不会自动执行安装、启动隧道、改防火墙、改路由。

.PARAMETER Root
    包根目录，默认取脚本所在包的根目录（整包可移动，无需指定）。

.PARAMETER Apply
    只清理本包自身残留，不碰别人的服务。

.PARAMETER Fix
    交互式处理：每关一个东西，先说明后果，再让你确认一次。

.PARAMETER DryRun
    配合 -Fix 使用：只演示会执行什么，不真的关。

.PARAMETER Answers
    预置回答，按顺序取用，仅用于自动化/演练；不填则现场键盘输入。
    例：-Answers '2','1','确认' 表示第一个问题选不动、第二个选关并确认。

.PARAMETER LogFile
    自定义日志路径。

.NOTES
    退出码：0 = 环境干净；3 = 还有需要处理的地方；2 = 脚本异常。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Apply,
    [switch]$Fix,
    [switch]$DryRun,
    [string[]]$Answers,
    [string]$LogFile
)

$ErrorActionPreference = 'Continue'

# 绿色版：兼容 PowerShell 2.0 ~ 7.x，不带参数时以包自身位置为准
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $here }
. (Join-Path $here 'lib\EnvCheck.ps1')
. (Join-Path $here 'lib\EnvFix.ps1')

$p = Get-GnirehtetPaths -Root $Root
New-Item -ItemType Directory -Force -Path $p.LogsDir | Out-Null
if (-not $LogFile) {
    $LogFile = Join-Path $p.LogsDir ('env-preflight-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
}

$lines = New-Object System.Collections.Generic.List[string]
function Add-Out {
    param([string]$Text = '')
    $lines.Add($Text)
    Write-Host $Text
}

function Write-Result {
    param($Result)
    foreach ($sev in @('BLOCKER', 'WARN', 'INFO')) {
        foreach ($f in $Result.Findings | Where-Object { $_.Severity -eq $sev }) {
            foreach ($l in (Format-EnvFinding -Finding $f)) { Add-Out $l }
        }
    }
    Add-Out ''
    Add-Out ("小计：待处理 {0} 项 / 可引起注意 {1} 项 / 仅供参考 {2} 项" -f $Result.Blockers, $Result.Warnings, $Result.Infos)
    Add-Out ''
    if ($Result.Blockers -gt 0) {
        Add-Out '结论：先别急着实机。上面标“阻断”的地方会和别的软件打架，需要先处理。'
    } elseif ($Result.Warnings -gt 0) {
        Add-Out '结论：能用，但有几处要留个心眼，按上面的建议确认一下。'
    } else {
        Add-Out '结论：干净，可以进入实机。'
    }
}

# 读取一个限定取值的回答；没输入、输入不认识的内容，一律当作“不动”
$script:answerQueue = New-Object System.Collections.Generic.Queue[string]
if ($Answers) {
    foreach ($a in $Answers) {
        # 兼容 pwsh -File 传入逗号分隔字符串（如 -Answers '1,关'）
        foreach ($part in ([string]$a -split ',')) {
            $script:answerQueue.Enqueue($part)
        }
    }
}

function Read-Answer {
    param([string[]]$Allowed, [string]$Prompt)
    if ($script:answerQueue.Count -gt 0) {
        $preset = $script:answerQueue.Dequeue()
        Add-Out ('（预置回答：' + $preset + '）')
        if ($Allowed -contains $preset.Trim()) { return $preset.Trim() }
        return $null
    }
    try { $raw = Read-Host $Prompt } catch { return $null }
    if ($null -eq $raw) { return $null }
    $t = $raw.Trim()
    if ($Allowed -contains $t) { return $t }
    return $null
}

function Show-Target {
    param($Target)
    Add-Out ''
    Add-Out ('─' * 62)
    Add-Out ('需要你决定：' + $Target.Headline)
    Add-Out ''
    foreach ($f in $Target.Facts) { Add-Out ('  ' + $f) }
    Add-Out ''
    Add-Out ('  为什么碍事：' + $Target.Reason)
    Add-Out ''
    Add-Out ('  [1] 关掉它 —— ' + $Target.IfStopped)
    Add-Out '  [2] 先不动 —— 保持现状，接着看下一个'
}

$exitCode = 0
try {
    Add-Out 'gnirehtet 环境体检'
    Add-Out ('时间     : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
    Add-Out ('计算机名 : ' + $env:COMPUTERNAME + '　用户：' + $env:USERNAME)
    Add-Out ('包目录   : ' + $Root)
    $mode = if ($Fix -and $Apply) {
        if ($DryRun) { '交互处理 · 演练（只说不做）+ 清理下载临时文件' } else { '交互处理 + 顺手清理本包残留' }
    } elseif ($Fix) {
        if ($DryRun) { '交互处理 · 演练（只说不做）' } else { '交互处理（每次关东西前会再问一遍）' }
    } elseif ($Apply) { '顺手清理本包残留' } else { '只看不动' }
    Add-Out ('模式     : ' + $mode)
    Add-Out ''

    $before = Invoke-EnvPreflight -Root $Root
    Write-Result -Result $before

    if ($Fix) {
        Add-Out ''
        Add-Out ('=' * 68)
        Add-Out '开始处理'
        Add-Out ('=' * 68)

        $targets = @(Get-InterferenceTargets -Root $Root)
        if ($targets.Count -eq 0) {
            Add-Out '没有发现需要关掉的东西，这里不用动。'
        } else {
            Add-Out ('一共发现 {0} 个会互相打扰的地方，一个一个来，你随时可以选「先不动」。' -f $targets.Count)
            $stopped = New-Object System.Collections.Generic.List[string]
            $planned = New-Object System.Collections.Generic.List[string]
            $failed  = New-Object System.Collections.Generic.List[string]
            $kept    = New-Object System.Collections.Generic.List[string]

            foreach ($t in $targets) {
                Show-Target -Target $t
                $choice = Read-Answer -Allowed @('1', '2') -Prompt '输入 1 或 2，然后回车：'
                if ($choice -ne '1') {
                    Add-Out ''
                    Add-Out '  → 好，保持不动，接着看下一个。'
                    $kept.Add("$($t.Headline)（进程编号 $($t.Pid)）")
                    continue
                }

                $confirm = Read-Answer -Allowed @('关', '确认', 'yes') -Prompt '最后确认：真的要关掉它吗？输入「关」确认，直接回车就取消：'
                if (-not $confirm) {
                    Add-Out ''
                    Add-Out '  → 已取消，什么都没做。'
                    $kept.Add("$($t.Headline)（进程编号 $($t.Pid)）")
                    continue
                }

                Add-Out ''
                Add-Out '  正在关闭……'
                $res = Stop-InterferenceTarget -Target $t -Root $Root -DryRun:$DryRun
                if ($res.Ok) {
                    Add-Out ('  ✔ ' + $res.Message)
                    if ($DryRun) {
                        $planned.Add("$($t.Headline)（进程编号 $($t.Pid)）")
                    } else {
                        $stopped.Add("$($t.Headline)（进程编号 $($t.Pid)）")
                    }
                } else {
                    Add-Out ('  ✘ ' + $res.Message)
                    $failed.Add("$($t.Headline)（进程编号 $($t.Pid)）：$($res.Message)")
                }
            }

            Add-Out ''
            Add-Out ('─' * 62)
            if ($planned.Count) { Add-Out ('演练：本来会关掉：' + ($planned -join '；')) }
            if ($stopped.Count) { Add-Out ('这次关掉了：' + ($stopped -join '；')) }
            if ($kept.Count)    { Add-Out ('保持没动：' + ($kept -join '；')) }
            if ($failed.Count)  { Add-Out ('没能关掉：' + ($failed -join '；')) }
        }

        if ($Apply -and (Test-Path -LiteralPath $p.DownloadDir)) {
            $parts = @(Get-ChildItem -LiteralPath $p.DownloadDir -Filter '*.part' -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
            foreach ($f in $parts) {
                if ($DryRun) {
                    Add-Out ('[演练] 本来会删除下载临时文件：' + $f.Name)
                } else {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    Add-Out ('[执行] 删除下载临时文件：' + $f.Name)
                }
            }
        }

        Add-Out ''
        Add-Out ('=' * 68)
        Add-Out '处理完再看一眼'
        Add-Out ('=' * 68)
        $after = Invoke-EnvPreflight -Root $Root
        Write-Result -Result $after
        $final = $after
        Add-Out ''
        Add-Out '说明：安装和启动都没有执行。真要连手机，再用 scripts\gnirehtet.ps1。'
    }
    elseif ($Apply) {
        Add-Out ''
        Add-Out ('=' * 68)
        Add-Out '顺手清理（只动这套工具自己的东西）'
        Add-Out ('=' * 68)
        $didSomething = $false

        $cleanRes = Stop-OwnPackageProcesses -Root $Root -StopAdbServer -Quiet
        if ($cleanRes.StoppedGnirehtetPids.Count -gt 0) {
            Add-Out ('[执行] 已清理本包残留 gnirehtet 进程：PID ' + ($cleanRes.StoppedGnirehtetPids -join ', '))
            $didSomething = $true
        }
        if ($cleanRes.StoppedAdbPids.Count -gt 0) {
            Add-Out ('[执行] 已关闭本包自己的 adb 服务：PID ' + ($cleanRes.StoppedAdbPids -join ', '))
            $didSomething = $true
        }

        if (Test-Path -LiteralPath $p.DownloadDir) {
            $parts = @(Get-ChildItem -LiteralPath $p.DownloadDir -Filter '*.part' -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
            foreach ($f in $parts) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Add-Out ('[执行] 删除下载临时文件：' + $f.Name)
                $didSomething = $true
            }
        }

        $untouched = @($before.Findings | Where-Object {
                (@('BLOCKER', 'WARN') -contains $_.Severity) -and
                ($_.Id -ne 'adb-server-own') -and
                ($_.Id -ne 'gnirehtet-running') -and
                (-not ($_.Id -eq 'port-31416-busy' -and $_.Severity -eq 'WARN'))
            })
        if ($untouched.Count -gt 0) {
            Add-Out ''
            Add-Out '下面这些涉及别人的服务，这次不碰（想处理可以加 -Fix 交互确认）：'
            foreach ($f in $untouched) { Add-Out ('  - ' + $f.Title) }
        }
        if (-not $didSomething) { Add-Out '没有可清理的本包残留。' }

        Add-Out ''
        Add-Out ('=' * 68)
        Add-Out '清理后复查'
        Add-Out ('=' * 68)
        $after = Invoke-EnvPreflight -Root $Root
        Write-Result -Result $after
        $final = $after
        Add-Out ''
        Add-Out '说明：安装/启动仍未执行，本脚本不连接手机、不启动隧道。'
    }
    else {
        $final = $before
        if ($before.Blockers -gt 0 -or $before.Warnings -gt 0) {
            Add-Out ''
            Add-Out '想现在处理？运行：'
            Add-Out '  pwsh -NoProfile -File scripts\10_env_preflight.ps1 -Fix'
            Add-Out '它会一个一个问你，你说“关”才关。'
        }
    }

    $exitCode = if ($final.Clean) { 0 } else { 3 }
}
catch {
    Add-Out ''
    Add-Out ('[异常] 体检中断：' + $_.Exception.Message)
    Add-Out $_.ScriptStackTrace
    $exitCode = 2
}
finally {
    try {
        $logParent = Split-Path -Parent $LogFile
        if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
            New-Item -ItemType Directory -Force -Path $logParent | Out-Null
        }
        [System.IO.File]::WriteAllLines($LogFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ''
        Write-Host ('日志已写入：' + $LogFile)
    } catch {
        Write-Warning ('写入日志失败：' + $_.Exception.Message)
    }
}

exit $exitCode
