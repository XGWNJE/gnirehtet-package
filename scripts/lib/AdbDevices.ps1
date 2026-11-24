<#
    设备识别库：读取 adb devices 列表、把状态翻译成人话、多设备时让人选。

    只在“已经通过环境闸门、准备操作手机”时使用——因为 `adb devices`
    会拉起 adb 服务，属于会改变运行状态的动作。
#>

function Get-AdbDevices {
    param([string]$AdbExe)

    $result = [pscustomobject]@{ Ok = $false; Devices = @(); Raw = '' }
    if (-not $AdbExe -or -not (Test-Path -LiteralPath $AdbExe)) {
        $result.Raw = '找不到 adb.exe'
        return $result
    }

    $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('devices', '-l') -TimeoutSeconds 25
    if ($cap.TimedOut) {
        $result.Raw = 'adb 25 秒没有响应，可能存在驱动或服务冲突。'
        return $result
    }

    $raw = ($cap.StdOut + $cap.StdErr)
    $result.Raw = $raw

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($raw -split "`r?`n")) {
        # 形如：a1b2c3d4  device product:.. model:Mi_13 device:..
        if ($line -match '^\s*([A-Za-z0-9._:\-]+)\s+(device|unauthorized|offline|bootloader|recovery|sideload)\b(.*)$') {
            $serial = $Matches[1]
            $state = $Matches[2]
            $rest = $Matches[3]
            $model = ''
            if ($rest -match 'model:(\S+)') { $model = ($Matches[1] -replace '_', ' ') }
            $list.Add([pscustomobject]@{
                Serial = $serial
                State  = $state
                Model  = $model
            })
        }
    }
    $result.Devices = $list.ToArray()
    $result.Ok = ($cap.ExitCode -eq 0)
    $result
}

<#
.SYNOPSIS
    确保 adb 服务已经就绪，避免第一次查询时由 adb 客户端临时拉起常驻 server。

.DESCRIPTION
    adb 客户端拉起 server 时会把自己的句柄表复制给 server。如果调用方的标准输出
    是管道（例如 | Tee-Object），那个写端会被 server 长期持有，导致管道永远等不到
    结束——脚本早就跑完了，外层却一直挂着。

    因此在任何查询之前，先用 ShellExecute 方式（不继承句柄）单独把 server 拉起来。
    版本或来源不一致时，先停再起，保证用的是本包 adb。
#>
function Initialize-AdbServer {
    param([string]$AdbExe, [int]$TimeoutSeconds = 25)

    if (-not $AdbExe -or -not (Test-Path -LiteralPath $AdbExe)) { return $false }

    $port = if (Get-Command Get-AdbServerPort -ErrorAction SilentlyContinue) {
        Get-AdbServerPort
    } else {
        $parsed = 5037
        if ($env:ANDROID_ADB_SERVER_PORT) {
            $tmp = 0
            if ([int]::TryParse($env:ANDROID_ADB_SERVER_PORT.Trim(), [ref]$tmp) -and $tmp -ge 1 -and $tmp -le 65535) {
                $parsed = $tmp
            }
        }
        $parsed
    }

    $listening = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listening.Count -gt 0) {
        $owner = Get-CimProcess -ProcessId $listening[0].OwningProcess
        # 安全防线：端口占用者不是 adb.exe 时，绝不调用其可执行文件，也不强行 kill-server
        if ($owner -and $owner.Name -ine 'adb.exe') {
            Write-Host ("  [阻断] 端口 {0} 被非 adb 程序占用：{1}（PID {2}），跳过重启。" -f $port, $owner.Name, $listening[0].OwningProcess) -ForegroundColor Yellow
            return $false
        }
        $ownerPath = if ($owner) { $owner.ExecutablePath } else { $null }
        $versionOk = $true
        if ($ownerPath) {
            $srv = Get-AdbVersionInfo -Exe $ownerPath
            $mine = Get-AdbVersionInfo -Exe $AdbExe
            $versionOk = ($srv.Ok -and $mine.Ok -and $srv.Build -eq $mine.Build)
        } else {
            $versionOk = $false
        }
        if ($versionOk) { return $true }

        Write-Host ('  正在重启 adb 服务（端口 {0} 上的服务来源或版本不一致）……' -f $port) -ForegroundColor DarkGray
        Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('kill-server') -TimeoutSeconds 15 | Out-Null
        for ($i = 0; $i -lt 25; $i++) {
            if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
    }

    # 关键：ShellExecute 启动，子进程不继承调用方的管道句柄
    Start-Process -FilePath $AdbExe -ArgumentList 'start-server' -WindowStyle Hidden | Out-Null

    for ($i = 0; $i -lt ($TimeoutSeconds * 5); $i++) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-DeviceStateText {
    param([string]$State)
    switch ($State) {
        'device'       { '已授权' }
        'unauthorized' { '未授权（手机上点“允许”）' }
        'offline'      { '离线（拔插数据线试试）' }
        'bootloader'   { '在 bootloader 模式，不能这样用' }
        'recovery'     { '在 recovery 模式，不能这样用' }
        'sideload'     { '在 sideload 模式，不能这样用' }
        default        { "状态：$State" }
    }
}

function Get-DeviceLabel {
    param($Device)
    if ($Device.Model) { "$($Device.Model)（$($Device.Serial)）" } else { "未知型号（$($Device.Serial)）" }
}

<#
.SYNOPSIS
    从设备列表里选一台。只有一台时直接返回，不打扰。
.PARAMETER Preset
    预置回答，供自动化测试使用；正常交互时留空。
#>
function Select-AdbDevice {
    param(
        $Devices,
        [string]$Preset
    )

    $usable = @($Devices | Where-Object State -eq 'device')
    if ($usable.Count -eq 0) { return $null }
    if ($usable.Count -eq 1) { return $usable[0] }

    Write-Host ''
    Write-Host '发现多台可以用的设备，装错机器不好回退，所以问一下：'
    for ($i = 0; $i -lt $usable.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (Get-DeviceLabel -Device $usable[$i]))
    }

    $answer = $Preset
    if (-not $answer) {
        try { $answer = Read-Host '用哪台？输入编号，直接回车用第 1 台' } catch { return $null }
    }

    if ($null -eq $answer) { return $null }
    $trimmed = $answer.Trim()
    if ($trimmed -eq '') {
        return $usable[0]
    }
    if ($trimmed -match '^\d+$') {
        $n = 0
        if ([int]::TryParse($trimmed, [ref]$n) -and $n -ge 1 -and $n -le $usable.Count) {
            return $usable[$n - 1]
        }
    }
    Write-Host ("输入无效（{0}），已取消选择，未操作任何设备。" -f $trimmed) -ForegroundColor Yellow
    return $null
}
