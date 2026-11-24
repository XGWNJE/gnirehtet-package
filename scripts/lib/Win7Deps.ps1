<#
    Windows 7 老环境依赖与驱动自动检测/安装库（兼容 PowerShell 2.0 ~ 7.x）。

    负责：
      1. 判断当前系统是否为老版本 Windows（Windows 7 / Server 2008 R2 / Windows 8）
      2. 检测本包 adb.exe 能否正常运行（缺 UCRT / VC++ 运行库时会失败）
      3. 检测设备管理器中是否存在缺少驱动的 Android / USB 设备
      4. 将包内 deps\ 下的运行库（vc_redist.x86.exe）与 USB 驱动（Google USB Driver + Universal ADB Driver）
         在一次 UAC 提权中全自动静默安装完毕
#>

function Test-IsLegacyWindows {
    $v = [Environment]::OSVersion.Version
    # Windows 7 = 6.1, Windows 8 = 6.2, Windows 10/11 = 10.0
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
                $isUsb = ($pnp -match '^USB\\')
                $isCandidate = $isUsb -or ($name -match 'Android|ADB|Composite|MTP|Phone|Xiaomi|Redmi|Huawei|Honor|OPPO|vivo|OnePlus|Samsung|Pixel|未知设备|Unknown')
                if ($isCandidate) {
                    $list.Add((New-Object PSObject -Property @{
                        Name      = $name
                        DeviceId  = $pnp
                        PnpClass  = $cls
                        ErrorCode = $dev.ConfigManagerErrorCode
                    }))
                }
            }
        }
    } catch { }
    return $list.ToArray()
}

function Get-BundledDepsInfo {
    param([string]$Root)
    $depsDir = Join-Path $Root 'deps'
    $vcRedist = Join-Path $depsDir 'vc_redist.x86.exe'
    $uniMsi   = Join-Path $depsDir 'UniversalAdbDriverSetup.msi'
    $googleInf = Join-Path $depsDir 'google-usb-driver\android_winusb.inf'
    return (New-Object PSObject -Property @{
        DepsDir        = $depsDir
        VcRedistExe    = $vcRedist
        HasVcRedist    = (Test-Path -LiteralPath $vcRedist -PathType Leaf)
        UniversalMsi   = $uniMsi
        HasUniversal   = (Test-Path -LiteralPath $uniMsi -PathType Leaf)
        GoogleInf      = $googleInf
        HasGoogleInf   = (Test-Path -LiteralPath $googleInf -PathType Leaf)
    })
}

function Install-BundledDeps {
    param(
        [string]$Root,
        [switch]$InstallRuntime,
        [switch]$InstallDrivers
    )

    $info = Get-BundledDepsInfo -Root $Root
    $result = New-Object PSObject -Property @{
        Ok             = $false
        RuntimeAttempt = $false
        DriverAttempt  = $false
        RebootSuggested = $false
        Log            = ''
    }

    $commands = New-Object System.Collections.Generic.List[string]
    $commands.Add('@echo off')
    $commands.Add('setlocal')

    if ($InstallRuntime -and $info.HasVcRedist) {
        $result.RuntimeAttempt = $true
        $vcPath = $info.VcRedistExe
        $commands.Add('echo [1/2] Installing Microsoft VC++ Runtime (x86 / UCRT)...')
        $commands.Add('"' + $vcPath + '" /install /quiet /norestart')
        $commands.Add('echo VC_EXIT=%errorlevel%')
    }

    if ($InstallDrivers) {
        if ($info.HasGoogleInf) {
            $result.DriverAttempt = $true
            $infPath = $info.GoogleInf
            $commands.Add('echo [Driver] Installing Google USB Driver...')
            $commands.Add('"%SystemRoot%\System32\pnputil.exe" -i -a "' + $infPath + '"')
            $commands.Add('echo GOOGLE_DRV_EXIT=%errorlevel%')
        }
        if ($info.HasUniversal) {
            $result.DriverAttempt = $true
            $msiPath = $info.UniversalMsi
            $commands.Add('echo [Driver] Installing Universal ADB Driver...')
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
        if ($line -ne '@echo off' -and $line -ne 'setlocal') {
            $wrapper.Add('  ' + $line)
        }
    }
    $wrapper.Add(') > "' + $logFile + '" 2>&1')
    $wrapper.Add('exit /b 0')

    try {
        [System.IO.File]::WriteAllLines($batchFile, $wrapper.ToArray(), [System.Text.Encoding]::Default)

        $isAdmin = Test-IsAdministrator
        if ($isAdmin) {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $batchFile + '"') -Wait -PassThru -WindowStyle Hidden
        } else {
            Write-Host '  需要管理员权限来安装系统运行库/驱动，请在弹出的权限提示中点击「是」……' -ForegroundColor Yellow
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $batchFile + '"') -Verb RunAs -Wait -PassThru -WindowStyle Hidden
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
    }

    return $result
}
