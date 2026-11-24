<#
.SYNOPSIS
    构建 gnirehtet 反向 USB 工具包（全离线准备，内置 Windows 7 老环境运行库与 USB 驱动）。

.DESCRIPTION
    1. 下载/校验：
       - gnirehtet Rust win64 v2.5.1
       - Android platform-tools r33.0.3（官方签名，零 Win8+ API 依赖，兼容 Windows 7/10/11）
       - Microsoft Visual C++ 2015-2022 Redistributable x86（自带 Win7 UCRT / KB2999226）
       - Google USB Driver（latest_usb_driver_windows.zip）
       - Universal ADB Driver（UniversalAdbDriverSetup.msi）
    2. 合入 tools\gnirehtet\ 与 deps\ 目录。
    3. 生成 manifest.json（版本、文件大小、SHA256）供验收核对。
    4. 清理暂存区。

.PARAMETER Root
    包根目录，默认按脚本自身位置定位。

.PARAMETER Force
    忽略已下载的缓存，强制重新下载。

.PARAMETER SkipDownload
    跳过下载，直接使用 download\ 中已有的缓存文件。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Force,
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows 7 / 旧版 .NET 默认仅开启 TLS 1.0，强开 TLS 1.2（3072）
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

$script:BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $script:BuildDir }

$GnirehtetVersion     = '2.5.1'
$GnirehtetUrl         = "https://github.com/Genymobile/gnirehtet/releases/download/v$GnirehtetVersion/gnirehtet-rust-win64-v$GnirehtetVersion.zip"
$GnirehtetZipSha256   = '7f5b1063e7895182aa60def1437e50363c3758144088dcd079037bb7c3c46a1c'

$PlatformToolsVersion = '33.0.3'
$PlatformToolsUrl     = 'https://dl.google.com/android/repository/platform-tools_r33.0.3-windows.zip'
$PlatformToolsSha256  = '1e59afd40a74c5c0eab0a9fad3f0faf8a674267106e0b19921be9f67081808c2'

$VcRedistUrl          = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
$GoogleUsbUrl         = 'https://dl.google.com/android/repository/latest_usb_driver_windows.zip'
$UniversalAdbUrl      = 'https://github.com/koush/adb.clockworkmod.com/releases/latest/download/UniversalAdbDriverSetup.msi'
$UniversalAdbSha256   = '4e77e303bba6cf84588bdb6da91f7a875d406f7930cbe9f4d2aae0b643c0c928'

$DownloadDir    = Join-Path $Root 'download'
$LogsDir        = Join-Path $Root 'logs'
$ToolsDir       = Join-Path $Root 'tools\gnirehtet'
$DepsDir        = Join-Path $Root 'deps'
$GoogleDrvDest  = Join-Path $DepsDir 'google-usb-driver'
$StageDir       = Join-Path $DownloadDir '.stage'

$GnirehtetZip   = Join-Path $DownloadDir "gnirehtet-rust-win64-v$GnirehtetVersion.zip"
$PlatformZip    = Join-Path $DownloadDir "platform-tools_r$PlatformToolsVersion-windows.zip"
$VcRedistSrc    = Join-Path $DownloadDir 'vc_redist.x86.exe'
$GoogleUsbZip   = Join-Path $DownloadDir 'latest_usb_driver_windows.zip'
$UniversalMsi   = Join-Path $DownloadDir 'UniversalAdbDriverSetup.msi'
$ManifestPath   = Join-Path $Root 'manifest.json'

function Write-Info { param([string]$m) Write-Host "[*] $m" }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

function Fail {
    param([string]$m)
    Write-Host "[-] 失败：$m" -ForegroundColor Red
    exit 2
}

function Get-OsDescription {
    $rt = 'System.Runtime.InteropServices.RuntimeInformation' -as [type]
    if ($rt) {
        try { return ([string]$rt::OSDescription).Trim() } catch { }
    }
    return [Environment]::OSVersion.VersionString
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
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

function Assert-AuthenticodeSigner {
    param([string]$Path, [string]$SubjectPattern, [string]$Label)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or ($sig.SignerCertificate.Subject -notmatch $SubjectPattern)) {
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '无签名' }
        Fail "数字签名校验失败：$(Split-Path -Leaf $Path)（状态=$($sig.Status)，签发者=$subject）"
    }
    Write-Ok "数字签名通过（$Label）：$(Split-Path -Leaf $Path)"
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$OutFile,
        [int64]$MinBytes = 1024,
        [string]$ExpectedSha256 = ''
    )

    if (-not $Force -and (Test-Path -LiteralPath $OutFile)) {
        $len = (Get-Item -LiteralPath $OutFile).Length
        if ($len -ge $MinBytes) {
            if ($ExpectedSha256) {
                $actual = Get-Sha256 -Path $OutFile
                if ($actual -eq $ExpectedSha256.ToLowerInvariant()) {
                    Write-Ok "已存在且 SHA256 校验通过，跳过下载：$(Split-Path -Leaf $OutFile)（$len 字节）"
                    return
                }
                if ($SkipDownload) {
                    Fail "本地缓存 SHA256 不匹配（指定了 -SkipDownload）：$(Split-Path -Leaf $OutFile)，实际=$actual，预期=$ExpectedSha256"
                }
                Write-Note "本地缓存 SHA256 不匹配，重新下载：$(Split-Path -Leaf $OutFile)"
            } else {
                Write-Ok "已存在，跳过下载：$(Split-Path -Leaf $OutFile)（$len 字节）"
                return
            }
        } else {
            Write-Note "已有文件不完整（$len 字节），重新下载：$(Split-Path -Leaf $OutFile)"
        }
    }

    if ($SkipDownload) {
        Fail "指定了 -SkipDownload，但 $(Split-Path -Leaf $OutFile) 不存在或不完整"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    $tmp = "$OutFile.part"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    Write-Info "下载：$Url"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 -o $tmp $Url
        if ($LASTEXITCODE -ne 0) { Fail "下载失败（curl 退出码 $LASTEXITCODE）：$Url" }
    } else {
        $wc = New-Object System.Net.WebClient
        try {
            $wc.DownloadFile($Url, $tmp)
        } catch {
            Fail "下载失败（WebClient）：$Url（$($_.Exception.Message)）"
        } finally {
            $wc.Dispose()
        }
    }
    if (-not (Test-Path -LiteralPath $tmp)) { Fail "下载未产生文件：$Url" }

    $len = (Get-Item -LiteralPath $tmp).Length
    if ($len -lt $MinBytes) {
        Remove-Item -LiteralPath $tmp -Force
        Fail "下载内容过小（$len 字节），疑似失败页面：$Url"
    }

    if ($ExpectedSha256) {
        $actual = Get-Sha256 -Path $tmp
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $tmp -Force
            Fail "下载文件 SHA256 校验失败：$(Split-Path -Leaf $OutFile)，实际=$actual，预期=$ExpectedSha256"
        }
        Write-Ok "SHA256 校验通过：$(Split-Path -Leaf $OutFile)"
    }

    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    Write-Ok "下载完成：$(Split-Path -Leaf $OutFile)（$len 字节）"
}

function Expand-ToStage {
    param([string]$Zip, [string]$Dest)

    if (-not (Test-Path -LiteralPath $Zip)) { Fail "压缩包不存在：$Zip" }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null

    Write-Info "解压：$(Split-Path -Leaf $Zip)"
    try {
        if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
            Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force -ErrorAction Stop
        } else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest)
        }
    } catch {
        Fail "解压失败：$Zip（$($_.Exception.Message)）"
    }
}

# ---------------------------------------------------------------- 目录准备
Write-Info "包根目录：$Root"
New-Item -ItemType Directory -Force -Path $DownloadDir, $LogsDir, $ToolsDir, $DepsDir | Out-Null

# ---------------------------------------------------------------- 下载
Get-RemoteFile -Url $GnirehtetUrl    -OutFile $GnirehtetZip -MinBytes 100000   -ExpectedSha256 $GnirehtetZipSha256
Get-RemoteFile -Url $PlatformToolsUrl -OutFile $PlatformZip -MinBytes 1000000  -ExpectedSha256 $PlatformToolsSha256
Get-RemoteFile -Url $VcRedistUrl     -OutFile $VcRedistSrc  -MinBytes 5000000
Get-RemoteFile -Url $GoogleUsbUrl    -OutFile $GoogleUsbZip -MinBytes 1000000
Get-RemoteFile -Url $UniversalAdbUrl -OutFile $UniversalMsi -MinBytes 1000000  -ExpectedSha256 $UniversalAdbSha256

# ---------------------------------------------------------------- gnirehtet
$gStage = Join-Path $StageDir 'gnirehtet'
Expand-ToStage -Zip $GnirehtetZip -Dest $gStage

$gnExe = Get-ChildItem -LiteralPath $gStage -Recurse -Filter 'gnirehtet.exe' |
    Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
if (-not $gnExe) { Fail 'gnirehtet 压缩包内未找到 gnirehtet.exe' }

Write-Info "合入 gnirehtet 文件：$($gnExe.DirectoryName)"
Get-ChildItem -LiteralPath $gnExe.DirectoryName | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $ToolsDir -Recurse -Force
}

# ---------------------------------------------------------------- platform-tools (r33.0.3 Win7/10/11 全兼容)
$pStage = Join-Path $StageDir 'platform-tools'
Expand-ToStage -Zip $PlatformZip -Dest $pStage

$adbExe = Get-ChildItem -LiteralPath $pStage -Recurse -Filter 'adb.exe' |
    Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
if (-not $adbExe) { Fail 'platform-tools 压缩包内未找到 adb.exe' }

$adbDir = $adbExe.DirectoryName
Write-Info "合入 Win7/10/11 兼容 adb 三件套（r$PlatformToolsVersion）：$adbDir"
foreach ($name in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
    $src = Join-Path $adbDir $name
    if (-not (Test-Path -LiteralPath $src)) { Fail "platform-tools 内缺少 $name" }
    Copy-Item -LiteralPath $src -Destination $ToolsDir -Force
    Write-Ok "复制 $name"
}

# ---------------------------------------------------------------- Win7 离线依赖 deps\
Write-Info '合入 Windows 7 老环境离线依赖（运行库 + USB 驱动）'
Assert-AuthenticodeSigner -Path $VcRedistSrc -SubjectPattern 'CN=Microsoft Corporation' -Label 'Microsoft'
Copy-Item -LiteralPath $VcRedistSrc  -Destination (Join-Path $DepsDir 'vc_redist.x86.exe') -Force
Write-Ok '复制 deps\vc_redist.x86.exe'

Copy-Item -LiteralPath $UniversalMsi -Destination (Join-Path $DepsDir 'UniversalAdbDriverSetup.msi') -Force
Write-Ok '复制 deps\UniversalAdbDriverSetup.msi'

$uStage = Join-Path $StageDir 'google-usb'
Expand-ToStage -Zip $GoogleUsbZip -Dest $uStage
$infFile = Get-ChildItem -LiteralPath $uStage -Recurse -Filter 'android_winusb.inf' |
    Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
if (-not $infFile) { Fail 'Google USB 驱动包内未找到 android_winusb.inf' }
if (Test-Path -LiteralPath $GoogleDrvDest) { Remove-Item -LiteralPath $GoogleDrvDest -Recurse -Force }
Copy-Item -LiteralPath $infFile.DirectoryName -Destination $GoogleDrvDest -Recurse -Force
Write-Ok '展开 deps\google-usb-driver\'

# ---------------------------------------------------------------- 校验落地文件
$required = @(
    @{ Path = (Join-Path $ToolsDir 'gnirehtet.exe');   Min = 1000 },
    @{ Path = (Join-Path $ToolsDir 'gnirehtet.apk');   Min = 10000 },
    @{ Path = (Join-Path $ToolsDir 'adb.exe');         Min = 1000 },
    @{ Path = (Join-Path $ToolsDir 'AdbWinApi.dll');   Min = 1000 },
    @{ Path = (Join-Path $ToolsDir 'AdbWinUsbApi.dll'); Min = 1000 },
    @{ Path = (Join-Path $DepsDir  'vc_redist.x86.exe'); Min = 5000000 },
    @{ Path = (Join-Path $DepsDir  'UniversalAdbDriverSetup.msi'); Min = 1000000 },
    @{ Path = (Join-Path $GoogleDrvDest 'android_winusb.inf'); Min = 1000 }
)

Write-Info '校验工具与依赖落地文件'
foreach ($r in $required) {
    if (-not (Test-Path -LiteralPath $r.Path)) { Fail "落地文件缺失：$($r.Path)" }
    $len = (Get-Item -LiteralPath $r.Path).Length
    if ($len -lt $r.Min) { Fail "落地文件过小（$len 字节）：$($r.Path)" }
    Write-Ok ('{0,-32} {1,10} 字节' -f (Split-Path -Leaf $r.Path), $len)
}

# ---------------------------------------------------------------- manifest
$toolFiles = @(Get-ChildItem -LiteralPath $ToolsDir | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)
$depFiles  = @(
    (Join-Path $DepsDir 'vc_redist.x86.exe'),
    (Join-Path $DepsDir 'UniversalAdbDriverSetup.msi'),
    (Join-Path $GoogleDrvDest 'android_winusb.inf')
)

$manifest = @{
    createdAt            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    os                   = Get-OsDescription
    gnirehtetVersion     = $GnirehtetVersion
    platformToolsVersion = $PlatformToolsVersion
    archives             = @(
        @{
            file   = Split-Path -Leaf $GnirehtetZip
            url    = $GnirehtetUrl
            bytes  = (Get-Item -LiteralPath $GnirehtetZip).Length
            sha256 = Get-Sha256 -Path $GnirehtetZip
        },
        @{
            file   = Split-Path -Leaf $PlatformZip
            url    = $PlatformToolsUrl
            bytes  = (Get-Item -LiteralPath $PlatformZip).Length
            sha256 = Get-Sha256 -Path $PlatformZip
        },
        @{
            file   = Split-Path -Leaf $VcRedistSrc
            url    = $VcRedistUrl
            bytes  = (Get-Item -LiteralPath $VcRedistSrc).Length
            sha256 = Get-Sha256 -Path $VcRedistSrc
        },
        @{
            file   = Split-Path -Leaf $GoogleUsbZip
            url    = $GoogleUsbUrl
            bytes  = (Get-Item -LiteralPath $GoogleUsbZip).Length
            sha256 = Get-Sha256 -Path $GoogleUsbZip
        },
        @{
            file   = Split-Path -Leaf $UniversalMsi
            url    = $UniversalAdbUrl
            bytes  = (Get-Item -LiteralPath $UniversalMsi).Length
            sha256 = Get-Sha256 -Path $UniversalMsi
        }
    )
    tools = @(
        foreach ($tf in $toolFiles) {
            @{
                file   = $tf.Name
                bytes  = $tf.Length
                sha256 = Get-Sha256 -Path $tf.FullName
            }
        }
    )
    deps = @(
        foreach ($dp in $depFiles) {
            $item = Get-Item -LiteralPath $dp
            $rel  = $dp.Substring($DepsDir.Length).TrimStart('\', '/')
            @{
                file   = $rel -replace '\\', '/'
                bytes  = $item.Length
                sha256 = Get-Sha256 -Path $dp
            }
        }
    )
}

if (Get-Command ConvertTo-Json -ErrorAction SilentlyContinue) {
    $jsonText = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($ManifestPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "已生成清单：$ManifestPath"
} else {
    Write-Note '当前 PowerShell 版本不支持 ConvertTo-Json，已跳过 manifest.json 重写。'
}

# ---------------------------------------------------------------- 清理暂存
if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
    Write-Info '已清理暂存区 download\.stage'
}

Write-Host ''
Write-Ok "构建完成：$ToolsDir + $DepsDir"
Write-Host '使用方式：直接双击根目录 gnirehtet.bat 即可全自动运行。' -ForegroundColor Yellow
exit 0
