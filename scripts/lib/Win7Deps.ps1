<#
    Windows 7 老环境依赖与驱动自动检测/安装库（兼容 PowerShell 2.0 ~ 7.x）。

    负责：
      1. 判断当前系统是否为老版本 Windows（Windows 7 / Server 2008 R2 / Windows 8）
      2. 检测本包 adb.exe 能否正常运行（缺 UCRT / VC++ 运行库时会失败）
      3. 检测设备管理器中是否存在缺少驱动的 Android / USB 设备，并提取硬件 ID（VID/PID/MI）
      4. 自动安装内置微软运行库（vc_redist.x86.exe）与通用 Android ADB USB 驱动：
         - 自动基于 Google 官方 WinUSB 驱动包，生成包含通用 ADB 类 ID（USB\Class_FF&SubClass_42&Prot_01）
           及当前缺失驱动手机真实 VID/PID 的 INF，前台调用 pnputil -i -a 绑定到微软原装 WinUSB.sys
#>

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
                $isUsb = ($pnp -match '^USB\\')
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
        RuntimeAttempt  = $false
        DriverAttempt   = $false
        RebootSuggested = $false
        Log             = ''
    }

    $tempDriverPkg = $null
    $commands = New-Object System.Collections.Generic.List[string]

    if ($InstallRuntime -and $info.HasVcRedist) {
        $result.RuntimeAttempt = $true
        $vcPath = $info.VcRedistExe
        $commands.Add('echo [1] Installing Microsoft VC++ Runtime (x86 / Win7 UCRT)...')
        $commands.Add('"' + $vcPath + '" /install /quiet /norestart')
        $commands.Add('echo VC_EXIT=%errorlevel%')
    }

    if ($InstallDrivers) {
        if ($info.HasGoogleInf) {
            $result.DriverAttempt = $true
            $tempDriverPkg = New-UniversalAdbInfPackage -GoogleDir $info.GoogleDir -ExtraHardwareIds $ExtraHardwareIds
            $infPath = $tempDriverPkg.InfPath
            $commands.Add('echo [2] Installing Universal Android ADB Driver (WinUSB Class_FF + Device VID/PID)...')
            $commands.Add('"%SystemRoot%\System32\pnputil.exe" -i -a "' + $infPath + '"')
            $commands.Add('echo PNP_UNIVERSAL_EXIT=%errorlevel%')
        }
        if ($info.HasUniversal) {
            $result.DriverAttempt = $true
            $msiPath = $info.UniversalMsi
            $commands.Add('echo [3] Installing ClockworkMod Universal ADB Driver...')
            $commands.Add('msiexec.exe /i "' + $msiPath + '" /qn /norestart')
            $commands.Add('echo UNI_DRV_EXIT=%errorlevel%')
        }
    }

    if (-not $result.RuntimeAttempt -and -not $result.DriverAttempt) {
        $result.Log = '包内 deps\ 目录没有找到可安装的离线依赖文件。'
        return $result
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $batchFile = Join-Path $env:TEMP ('gnirehtet-deps-' + $stamp + '.cmd')
    $logFile   = Join-Path $env:TEMP ('gnirehtet-deps-' + $stamp + '.log')

    $wrapper = New-Object System.Collections.Generic.List[string]
    $wrapper.Add('@echo off')
    $wrapper.Add('(')
    foreach ($line in $commands) {
        $wrapper.Add('  ' + $line)
    }
    $wrapper.Add(') > "' + $logFile + '" 2>&1')
    $wrapper.Add('exit /b 0')

    try {
        [System.IO.File]::WriteAllLines($batchFile, $wrapper.ToArray(), [System.Text.Encoding]::Default)

        $isAdmin = Test-IsAdministrator
        # 注意：安装驱动时不使用 Hidden，避免 Windows 7 弹出「始终安装此驱动程序软件」安全确认框被隐藏
        $winStyle = if ($InstallDrivers) { 'Normal' } else { 'Hidden' }

        if ($InstallDrivers) {
            Write-Host '  提示：如 Windows 弹出「无法验证驱动程序发布者」红框，请点击「始终安装此驱动程序软件」。' -ForegroundColor Yellow
        }

        if ($isAdmin) {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $batchFile + '"') -Wait -PassThru -WindowStyle $winStyle
        } else {
            Write-Host '  需要管理员权限来安装系统运行库/驱动，请在弹出的权限提示中点击「是」……' -ForegroundColor Yellow
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $batchFile + '"') -Verb RunAs -Wait -PassThru -WindowStyle $winStyle
        }

        if (Test-Path -LiteralPath $logFile) {
            $result.Log = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::Default)
            if ($result.Log -match 'VC_EXIT=3010' -or $result.Log -match 'UNI_DRV_EXIT=3010') {
                $result.RebootSuggested = $true
            }
        }
        $result.Ok = ($null -ne $p -and $p.ExitCode -eq 0)
    } catch {
        $result.Log = $_.Exception.Message
        $result.Ok = $false
    } finally {
        Remove-Item -LiteralPath $batchFile, $logFile -Force -ErrorAction SilentlyContinue
        if ($tempDriverPkg -and (Test-Path -LiteralPath $tempDriverPkg.StageDir)) {
            Remove-Item -LiteralPath $tempDriverPkg.StageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}
