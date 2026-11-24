<#
    Windows 7 老环境依赖与驱动自动检测/安装库（兼容 PowerShell 2.0 ~ 7.x）。

    负责：
      1. 判断当前系统是否为老版本 Windows（Windows 7 / Server 2008 R2 / Windows 8）
      2. 检测本包 adb.exe 能否正常运行（缺 UCRT / VC++ 运行库时会失败）
      3. 检测设备管理器中是否存在缺少驱动的 Android / USB 设备，并提取硬件 ID（VID/PID/MI）
      4. 自动安装内置微软运行库（vc_redist.x86.exe）与通用 Android ADB USB 驱动：
         - 在当前管理员进程（或提权子进程）中直接执行，不拼接临时 .cmd 批处理
         - 直接调用系统 newdev.dll!UpdateDriverForPlugAndPlayDevices 强制绑定通用 WinUSB INF
         - 再调用 pnputil -i -a 写入系统驱动库；仅当仍有异常设备时再跑 UniversalAdbDriverSetup.msi 兜底
#>

$script:Win7DepsLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-IsLegacyWindows {
    $v = [Environment]::OSVersion.Version
    return (($v.Major -lt 6) -or ($v.Major -eq 6 -and $v.Minor -le 1))
}

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-AdbRunnable {
    param([string]$AdbExe)
    $ver = Get-AdbVersionInfo -Exe $AdbExe
    return $ver.Ok
}

function Get-BrokenAndroidUsbDevices {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $items = $null
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            try {
                $items = Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop
            } catch { $items = $null }
        }
        if ($null -eq $items -and (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) {
            try {
                $items = Get-WmiObject Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop
            } catch { $items = $null }
        }
        if ($items) {
            foreach ($dev in $items) {
                $name = if ($dev.Name) { [string]$dev.Name } else { '' }
                $pnp  = if ($dev.PNPDeviceID) { [string]$dev.PNPDeviceID } else { '' }
                $cls  = if ($dev.PNPClass) { [string]$dev.PNPClass } else { '' }
                $hwId = ''
                if ($pnp -match '^(USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}(?:&MI_[0-9A-Fa-f]{2})?)') {
                    $hwId = $Matches[1].ToUpperInvariant()
                }
                if (-not $hwId -and $dev.HardwareID) {
                    foreach ($h in @($dev.HardwareID)) {
                        $hs = [string]$h
                        if ($hs -match '^USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}(?:&MI_[0-9A-Fa-f]{2})?') {
                            $hwId = $Matches[0].ToUpperInvariant()
                            break
                        }
                    }
                    if (-not $hwId) {
                        foreach ($h in @($dev.HardwareID)) {
                            $hs = [string]$h
                            if ($hs -match '^USB\\') {
                                $hwId = $hs.ToUpperInvariant()
                                break
                            }
                        }
                    }
                }
                $isUsb = ($pnp -match '^USB\\') -or ($hwId -match '^USB\\')
                $isCandidate = $isUsb -or ($name -match 'Android|ADB|Composite|MTP|Phone|Xiaomi|Redmi|Huawei|Honor|OPPO|vivo|OnePlus|Samsung|Pixel|未知设备|Unknown')
                if ($isCandidate) {
                    $list.Add((New-Object PSObject -Property @{
                        Name       = $name
                        DeviceId   = $pnp
                        HardwareId = $hwId
                        PnpClass   = $cls
                        ErrorCode  = $dev.ConfigManagerErrorCode
                    }))
                }
            }
        }
    } catch { }
    return $list.ToArray()
}

function Get-BundledDepsInfo {
    param([string]$Root)
    $depsDir   = Join-Path $Root 'deps'
    $vcRedist  = Join-Path $depsDir 'vc_redist.x86.exe'
    $uniMsi    = Join-Path $depsDir 'UniversalAdbDriverSetup.msi'
    $googleDir = Join-Path $depsDir 'google-usb-driver'
    $googleInf = Join-Path $googleDir 'android_winusb.inf'
    return (New-Object PSObject -Property @{
        DepsDir        = $depsDir
        VcRedistExe    = $vcRedist
        HasVcRedist    = (Test-Path -LiteralPath $vcRedist -PathType Leaf)
        UniversalMsi   = $uniMsi
        HasUniversal   = (Test-Path -LiteralPath $uniMsi -PathType Leaf)
        GoogleDir      = $googleDir
        GoogleInf      = $googleInf
        HasGoogleInf   = (Test-Path -LiteralPath $googleInf -PathType Leaf)
    })
}

function New-UniversalAdbInfPackage {
    param(
        [string]$GoogleDir,
        [string[]]$ExtraHardwareIds = @()
    )

    $stageDir = Join-Path $env:TEMP ('gnirehtet-adb-drv-' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $GoogleDir -Destination $stageDir -Recurse -Force

    # 移除旧 .cat（因为下面会追加通用 ADB 类 ID 及当前手机的 VID/PID）
    Get-ChildItem -LiteralPath $stageDir -Filter '*.cat' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $infPath = Join-Path $stageDir 'android_winusb.inf'
    $raw = [System.IO.File]::ReadAllText($infPath, [System.Text.Encoding]::ASCII)

    # 注释掉原 CatalogFile 行，避免与追加的硬件 ID 签名不匹配报错
    $raw = [regex]::Replace($raw, '(?mi)^(\s*CatalogFile[^\r\n]*)', ';$1')

    $extraLines = New-Object System.Collections.Generic.List[string]
    $extraLines.Add('')
    $extraLines.Add('; Universal Android ADB Class (all brands)')
    $extraLines.Add('%CompositeAdbInterface%     = USB_Install, USB\Class_FF&SubClass_42&Prot_01')
    $extraLines.Add('%SingleAdbInterface%        = USB_Install, USB\Class_FF&SubClass_42&Prot_03')

    $seen = @{}
    foreach ($hid in $ExtraHardwareIds) {
        if (-not $hid) { continue }
        $h = $hid.Trim().ToUpperInvariant()
        if ($h -and -not $seen.ContainsKey($h)) {
            $seen[$h] = $true
            $extraLines.Add('; Detected local Android device')
            $extraLines.Add('%CompositeAdbInterface%     = USB_Install, ' + $h)
        }
    }
    $inject = ($extraLines.ToArray() -join "`r`n") + "`r`n"

    $raw = [regex]::Replace($raw, '(?mi)^(\[Google\.NTx86\])', "`$1`r`n$inject")
    $raw = [regex]::Replace($raw, '(?mi)^(\[Google\.NTamd64\])', "`$1`r`n$inject")

    [System.IO.File]::WriteAllText($infPath, $raw, [System.Text.Encoding]::ASCII)
    return (New-Object PSObject -Property @{
        StageDir = $stageDir
        InfPath  = $infPath
    })
}

function Ensure-Win7NewDevType {
    if (-not ('Win7NewDev' -as [type])) {
        $src = @'
using System;
using System.Runtime.InteropServices;
public static class Win7NewDev {
    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent,
        string HardwareId,
        string FullInfPath,
        uint InstallFlags,
        out bool bRebootRequired
    );
}
'@
        Add-Type -TypeDefinition $src -ErrorAction Stop
    }
}

function Invoke-BindDriverToHardwareId {
    param(
        [string]$HardwareId,
        [string]$InfPath
    )
    $res = New-Object PSObject -Property @{
        Ok           = $false
        Reboot       = $false
        ErrorCodeHex = ''
        ErrorMessage = ''
    }
    try {
        Ensure-Win7NewDevType
        $reboot = $false
        # INSTALLFLAG_FORCE = 1：强制将匹配硬件 ID 的设备绑定到指定 WinUSB INF
        $ok = [Win7NewDev]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, $HardwareId, $InfPath, 1, [ref]$reboot)
        if ($ok) {
            $res.Ok = $true
            $res.Reboot = [bool]$reboot
        } else {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $uerr = $err -band 0xFFFFFFFFL
            $res.ErrorCodeHex = ('0x{0:X8}' -f $uerr)
            try {
                $res.ErrorMessage = (New-Object System.ComponentModel.Win32Exception($err)).Message
            } catch {
                $res.ErrorMessage = ('Win32 error ' + $res.ErrorCodeHex)
            }
        }
    } catch {
        $res.ErrorCodeHex = 'EXCEPTION'
        $res.ErrorMessage = $_.Exception.Message
    }
    return $res
}

function Start-ProcessGetExitCode {
    param(
        [string]$FilePath,
        [string]$Arguments = '',
        [switch]$CaptureOutput
    )
    $out = New-Object PSObject -Property @{
        ExitCode = -1
        StdOut   = ''
        StdErr   = ''
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($CaptureOutput) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        $out.StdErr = ('无法启动进程：' + $FilePath)
        return $out
    }
    $null = $proc.Handle
    if ($CaptureOutput) {
        $out.StdOut = $proc.StandardOutput.ReadToEnd()
        $out.StdErr = $proc.StandardError.ReadToEnd()
    }
    $proc.WaitForExit()
    $out.ExitCode = [int]$proc.ExitCode
    return $out
}

function Invoke-BundledDepsElevatedWorker {
    param(
        [string]$Root,
        [switch]$InstallRuntime,
        [switch]$InstallDrivers,
        [string[]]$ExtraHardwareIds = @()
    )

    $info = Get-BundledDepsInfo -Root $Root
    $lines = New-Object System.Collections.Generic.List[string]
    $runtimeOk = $true
    $driverOk  = $true
    $rebootSuggested = $false
    $tempDriverPkg = $null

    function Add-WorkerLog {
        param([string]$Text)
        $lines.Add($Text)
        Write-Host ('  ' + $Text) -ForegroundColor DarkGray
    }

    try {
        if ($InstallRuntime) {
            $runtimeOk = $false
            if (-not $info.HasVcRedist) {
                Add-WorkerLog '[运行库] 包内缺少 deps\vc_redist.x86.exe'
            } else {
                Add-WorkerLog '[运行库] 正在静默安装 Microsoft VC++ Runtime (x86 / Win7 UCRT)...'
                $r = Start-ProcessGetExitCode -FilePath $info.VcRedistExe -Arguments '/install /quiet /norestart'
                Add-WorkerLog ('VC_EXIT=' + $r.ExitCode)
                if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 1638 -or $r.ExitCode -eq 3010) {
                    $runtimeOk = $true
                    if ($r.ExitCode -eq 3010) { $rebootSuggested = $true }
                }
            }
        }

        if ($InstallDrivers) {
            $driverOk = $false
            if ($info.HasGoogleInf) {
                $tempDriverPkg = New-UniversalAdbInfPackage -GoogleDir $info.GoogleDir -ExtraHardwareIds $ExtraHardwareIds
                $infPath = $tempDriverPkg.InfPath

                # 1. 若有已知硬件 ID，直接调用系统 newdev.dll 强制绑定（对 Error 28 最有效）
                if ($ExtraHardwareIds -and $ExtraHardwareIds.Count -gt 0) {
                    foreach ($hid in $ExtraHardwareIds) {
                        if (-not $hid) { continue }
                        Add-WorkerLog ('[驱动] 正在直接绑定设备 ' + $hid + ' ...')
                        $bindRes = Invoke-BindDriverToHardwareId -HardwareId $hid -InfPath $infPath
                        if ($bindRes.Ok) {
                            $driverOk = $true
                            if ($bindRes.Reboot) { $rebootSuggested = $true }
                            Add-WorkerLog ('NEWDEV_BIND_OK=' + $hid + ' (Reboot=' + $bindRes.Reboot + ')')
                        } else {
                            Add-WorkerLog ('NEWDEV_BIND_FAIL=' + $hid + ' Code=' + $bindRes.ErrorCodeHex + ' Msg=' + $bindRes.ErrorMessage)
                        }
                    }
                }

                # 2. 调用 pnputil 将通用驱动加入系统 DriverStore
                $pnputil = Join-Path $env:windir 'Sysnative\pnputil.exe'
                if (-not (Test-Path -LiteralPath $pnputil -PathType Leaf)) {
                    $pnputil = Join-Path $env:windir 'System32\pnputil.exe'
                }
                if (Test-Path -LiteralPath $pnputil -PathType Leaf) {
                    Add-WorkerLog '[驱动] 正在通过 pnputil 预存通用 ADB 驱动包...'
                    $pr = Start-ProcessGetExitCode -FilePath $pnputil -Arguments ('-i -a "' + $infPath + '"') -CaptureOutput
                    Add-WorkerLog ('PNP_UNIVERSAL_EXIT=' + $pr.ExitCode)
                    $pnpText = (($pr.StdOut + "`n" + $pr.StdErr).Trim())
                    if ($pnpText) {
                        foreach ($pl in ($pnpText -split "`r?`n")) {
                            if ($pl.Trim()) { Add-WorkerLog ('pnputil: ' + $pl.Trim()) }
                        }
                    }
                    if ($pr.ExitCode -eq 0 -or $pr.ExitCode -eq 259 -or $pr.ExitCode -eq 3010) {
                        $driverOk = $true
                        if ($pr.ExitCode -eq 3010) { $rebootSuggested = $true }
                    }
                } else {
                    Add-WorkerLog ('[驱动] 未找到 pnputil.exe：' + $pnputil)
                }
            }

            # 3. 仅当上述步骤后仍检测到异常 USB 设备时，运行 UniversalAdbDriverSetup.msi 作为补充
            $stillBroken = @(Get-BrokenAndroidUsbDevices)
            if ((-not $driverOk -or $stillBroken.Count -gt 0) -and $info.HasUniversal) {
                Add-WorkerLog '[驱动] 正在运行 UniversalAdbDriverSetup.msi 补充驱动...'
                $mr = Start-ProcessGetExitCode -FilePath 'msiexec.exe' -Arguments ('/i "' + $info.UniversalMsi + '" /qn /norestart')
                Add-WorkerLog ('UNI_DRV_EXIT=' + $mr.ExitCode)
                if ($mr.ExitCode -eq 0 -or $mr.ExitCode -eq 3010) {
                    $driverOk = $true
                    if ($mr.ExitCode -eq 3010) { $rebootSuggested = $true }
                }
            }
        }
    } finally {
        if ($tempDriverPkg -and (Test-Path -LiteralPath $tempDriverPkg.StageDir)) {
            Remove-Item -LiteralPath $tempDriverPkg.StageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $overallOk = $true
    if ($InstallRuntime -and -not $runtimeOk) { $overallOk = $false }
    if ($InstallDrivers -and -not $driverOk)  { $overallOk = $false }

    return (New-Object PSObject -Property @{
        Ok              = $overallOk
        RuntimeOk       = $runtimeOk
        DriverOk        = $driverOk
        RebootSuggested = $rebootSuggested
        Lines           = $lines.ToArray()
    })
}

function Install-BundledDeps {
    param(
        [string]$Root,
        [switch]$InstallRuntime,
        [switch]$InstallDrivers,
        [string[]]$ExtraHardwareIds = @()
    )

    $info = Get-BundledDepsInfo -Root $Root
    $result = New-Object PSObject -Property @{
        Ok              = $false
        RuntimeAttempt  = [bool]$InstallRuntime
        DriverAttempt   = [bool]$InstallDrivers
        RebootSuggested = $false
        Log             = ''
    }

    if ((-not $InstallRuntime -or -not $info.HasVcRedist) -and (-not $InstallDrivers -or (-not $info.HasGoogleInf -and -not $info.HasUniversal))) {
        $result.Log = '包内 deps\ 目录没有找到可安装的离线依赖文件。'
        return $result
    }

    if ($InstallDrivers) {
        Write-Host '  提示：如 Windows 弹出「Windows 安全」红框，请点击「始终安装此驱动程序软件」。' -ForegroundColor Yellow
    }

    # 已是管理员：直接在当前进程内执行，无子进程、无 .cmd 语法隐患
    if (Test-IsAdministrator) {
        $w = Invoke-BundledDepsElevatedWorker -Root $Root -InstallRuntime:$InstallRuntime -InstallDrivers:$InstallDrivers -ExtraHardwareIds $ExtraHardwareIds
        $result.Ok = [bool]$w.Ok
        $result.RebootSuggested = [bool]$w.RebootSuggested
        $result.Log = ($w.Lines -join "`r`n")
        return $result
    }

    # 非管理员：通过临时状态文件唤起提权 PowerShell 执行 -Action elevated-deps
    $stamp = [guid]::NewGuid().ToString('N')
    $stateFile = Join-Path $env:TEMP ('gnirehtet-deps-state-' + $stamp + '.txt')
    $reqLines = New-Object System.Collections.Generic.List[string]
    $reqLines.Add('RUNTIME=' + $(if ($InstallRuntime) { '1' } else { '0' }))
    $reqLines.Add('DRIVERS=' + $(if ($InstallDrivers) { '1' } else { '0' }))
    foreach ($hid in $ExtraHardwareIds) {
        if ($hid) { $reqLines.Add('HWID=' + $hid) }
    }

    try {
        [System.IO.File]::WriteAllLines($stateFile, $reqLines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

        $psExe = Join-Path $PSHome 'powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
            $psExe = 'powershell.exe'
        }
        $entryPs1 = Join-Path (Split-Path -Parent $script:Win7DepsLibDir) 'gnirehtet.ps1'

        Write-Host '  需要管理员权限来安装系统运行库/驱动，请在弹出的权限提示中点击「是」……' -ForegroundColor Yellow
        $argArr = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $entryPs1 + '"'),
            '-Action', 'elevated-deps',
            '-Root', ('"' + $Root + '"'),
            '-DepsStateFile', ('"' + $stateFile + '"')
        )
        $null = Start-Process -FilePath $psExe -ArgumentList $argArr -Verb RunAs -Wait

        if (Test-Path -LiteralPath $stateFile) {
            $outLines = [System.IO.File]::ReadAllLines($stateFile, [System.Text.Encoding]::UTF8)
            $logList = New-Object System.Collections.Generic.List[string]
            $sawResult = $false
            foreach ($ol in $outLines) {
                if ($ol -eq 'RESULT_OK=1') { $result.Ok = $true; $sawResult = $true }
                elseif ($ol -eq 'RESULT_OK=0') { $result.Ok = $false; $sawResult = $true }
                elseif ($ol -eq 'REBOOT=1') { $result.RebootSuggested = $true }
                elseif ($ol.StartsWith('LOG=')) { $logList.Add($ol.Substring(4)) }
            }
            if (-not $sawResult) {
                $result.Log = '未授予管理员权限或提权子进程被取消。'
            } else {
                $result.Log = ($logList.ToArray() -join "`r`n")
            }
        } else {
            $result.Log = '未生成提权状态文件（可能取消了 UAC 授权）。'
        }
    } catch {
        $result.Log = $_.Exception.Message
        $result.Ok = $false
    } finally {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    }

    return $result
}
