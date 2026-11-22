<#
.SYNOPSIS
    构建 gnirehtet 反向 USB 工具包（纯离线准备，不接触手机、不改路由、不改防火墙）。

.DESCRIPTION
    1. 下载 gnirehtet Rust win64 v2.5.1 与 platform-tools（已存在且完整时跳过）。
    2. 解压到 download\.stage 暂存区。
    3. 把 gnirehtet.exe / gnirehtet.apk 等复制到 tools\gnirehtet。
    4. 把 adb.exe、AdbWinApi.dll、AdbWinUsbApi.dll 复制到同一个 tools\gnirehtet 目录。
    5. 生成 manifest.json（版本、文件大小、SHA256）供验收核对。
    6. 清理暂存区。

    ！本脚本不会执行 adb、不会启动 gnirehtet、不会修改系统网络配置。

.PARAMETER Root
    包根目录，默认取脚本所在包的根目录（整包可移动，无需指定）。

.PARAMETER Force
    忽略已下载的压缩包，强制重新下载。

.PARAMETER SkipDownload
    跳过下载，直接用 download\ 下已有的压缩包（校验存在性）。

.EXAMPLE
    pwsh -NoProfile -File scripts\build_package.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Force,
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'

# 绿色版：不带参数时以包自身位置为准，整个目录可以随意搬动
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$GnirehtetVersion = '2.5.1'
$GnirehtetUrl     = "https://github.com/Genymobile/gnirehtet/releases/download/v$GnirehtetVersion/gnirehtet-rust-win64-v$GnirehtetVersion.zip"
$PlatformToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

$DownloadDir = Join-Path $Root 'download'
$LogsDir     = Join-Path $Root 'logs'
$ToolsDir    = Join-Path $Root 'tools\gnirehtet'
$StageDir    = Join-Path $DownloadDir '.stage'
$GnirehtetZip = Join-Path $DownloadDir "gnirehtet-rust-win64-v$GnirehtetVersion.zip"
$PlatformZip  = Join-Path $DownloadDir 'platform-tools-latest-windows.zip'
$ManifestPath = Join-Path $Root 'manifest.json'

function Write-Info { param([string]$m) Write-Host "[*] $m" }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

function Fail {
    param([string]$m)
    Write-Host "[-] 失败：$m" -ForegroundColor Red
    exit 2
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$OutFile,
        [int64]$MinBytes = 1024
    )

    if (-not $Force -and (Test-Path -LiteralPath $OutFile)) {
        $len = (Get-Item -LiteralPath $OutFile).Length
        if ($len -ge $MinBytes) {
            Write-Ok "已存在，跳过下载：$(Split-Path -Leaf $OutFile)（$len 字节）"
            return
        }
        Write-Note "已有文件不完整（$len 字节），重新下载：$(Split-Path -Leaf $OutFile)"
    }

    if ($SkipDownload) {
        Fail "指定了 -SkipDownload，但 $(Split-Path -Leaf $OutFile) 不存在或不完整"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    $tmp = "$OutFile.part"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    Write-Info "下载：$Url"
    & curl.exe -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 -o $tmp $Url
    if ($LASTEXITCODE -ne 0) { Fail "下载失败（curl 退出码 $LASTEXITCODE）：$Url" }
    if (-not (Test-Path -LiteralPath $tmp)) { Fail "下载未产生文件：$Url" }

    $len = (Get-Item -LiteralPath $tmp).Length
    if ($len -lt $MinBytes) {
        Remove-Item -LiteralPath $tmp -Force
        Fail "下载内容过小（$len 字节），疑似失败页面：$Url"
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
        Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force -ErrorAction Stop
    } catch {
        Fail "解压失败：$Zip（$($_.Exception.Message)）"
    }
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------- 目录准备
Write-Info "包根目录：$Root"
New-Item -ItemType Directory -Force -Path $DownloadDir, $LogsDir, $ToolsDir | Out-Null

# ---------------------------------------------------------------- 下载
Get-RemoteFile -Url $GnirehtetUrl     -OutFile $GnirehtetZip -MinBytes 100000
Get-RemoteFile -Url $PlatformToolsUrl -OutFile $PlatformZip  -MinBytes 1000000

# ---------------------------------------------------------------- gnirehtet
$gStage = Join-Path $StageDir 'gnirehtet'
Expand-ToStage -Zip $GnirehtetZip -Dest $gStage

$gnExe = Get-ChildItem -LiteralPath $gStage -Recurse -File -Filter 'gnirehtet.exe' |
    Select-Object -First 1
if (-not $gnExe) { Fail 'gnirehtet 压缩包内未找到 gnirehtet.exe' }

Write-Info "合入 gnirehtet 文件：$($gnExe.DirectoryName)"
Copy-Item -Path (Join-Path $gnExe.DirectoryName '*') -Destination $ToolsDir -Recurse -Force

# ---------------------------------------------------------------- platform-tools
$pStage = Join-Path $StageDir 'platform-tools'
Expand-ToStage -Zip $PlatformZip -Dest $pStage

$adbExe = Get-ChildItem -LiteralPath $pStage -Recurse -File -Filter 'adb.exe' |
    Select-Object -First 1
if (-not $adbExe) { Fail 'platform-tools 压缩包内未找到 adb.exe' }

$adbDir = $adbExe.DirectoryName
Write-Info "合入 adb 三件套：$adbDir"
foreach ($name in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
    $src = Join-Path $adbDir $name
    if (-not (Test-Path -LiteralPath $src)) { Fail "platform-tools 内缺少 $name" }
    Copy-Item -LiteralPath $src -Destination $ToolsDir -Force
    Write-Ok "复制 $name"
}

# ---------------------------------------------------------------- 校验落地文件
$required = @(
    @{ Name = 'gnirehtet.exe';   Min = 1000 },
    @{ Name = 'gnirehtet.apk';   Min = 10000 },
    @{ Name = 'adb.exe';         Min = 1000 },
    @{ Name = 'AdbWinApi.dll';   Min = 1000 },
    @{ Name = 'AdbWinUsbApi.dll'; Min = 1000 }
)

Write-Info '校验 tools\gnirehtet 落地文件'
foreach ($r in $required) {
    $p = Join-Path $ToolsDir $r.Name
    if (-not (Test-Path -LiteralPath $p)) { Fail "落地文件缺失：$p" }
    $len = (Get-Item -LiteralPath $p).Length
    if ($len -lt $r.Min) { Fail "落地文件过小（$len 字节）：$p" }
    Write-Ok ('{0,-18} {1,10} 字节' -f $r.Name, $len)
}

# 额外附带文件仅做提示，不作硬性要求
$extras = Get-ChildItem -LiteralPath $ToolsDir -File |
    Where-Object { $required.Name -notcontains $_.Name }
if ($extras) {
    Write-Note ('同目录附带文件：' + (($extras | Select-Object -ExpandProperty Name) -join ', '))
}

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    createdAt        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    machine          = $env:COMPUTERNAME
    os               = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    gnirehtetVersion = $GnirehtetVersion
    archives         = @(
        [ordered]@{
            file   = Split-Path -Leaf $GnirehtetZip
            url    = $GnirehtetUrl
            bytes  = (Get-Item -LiteralPath $GnirehtetZip).Length
            sha256 = Get-Sha256 -Path $GnirehtetZip
        },
        [ordered]@{
            file   = Split-Path -Leaf $PlatformZip
            url    = $PlatformToolsUrl
            bytes  = (Get-Item -LiteralPath $PlatformZip).Length
            sha256 = Get-Sha256 -Path $PlatformZip
        }
    )
    tools = @(
        Get-ChildItem -LiteralPath $ToolsDir -File | Sort-Object Name | ForEach-Object {
            [ordered]@{
                file   = $_.Name
                bytes  = $_.Length
                sha256 = Get-Sha256 -Path $_.FullName
            }
        }
    )
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
Write-Ok "已生成清单：$ManifestPath"

# ---------------------------------------------------------------- 清理暂存
if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
    Write-Info '已清理暂存区 download\.stage'
}

Write-Host ''
Write-Ok "构建完成：$ToolsDir"
Write-Host ''
Write-Host '提醒：构建只准备文件，不接触手机。实机前请先跑环境预检：' -ForegroundColor Yellow
Write-Host '      pwsh -NoProfile -File scripts\10_env_preflight.ps1' -ForegroundColor Yellow
exit 0
