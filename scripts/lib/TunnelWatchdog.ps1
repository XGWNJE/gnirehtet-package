<#
    断连自愈守护库（兼容 Windows 7 原厂 PowerShell 2.0 ~ PowerShell 7.x）。

    解决以下运行中断连与多次拔插恢复失败的场景：
      1. 关闭控制台「快速编辑」模式并异步托管 relay 输出，防止鼠标误点窗口触发「选择」导致进程冻结；
      2. 覆盖 PersistentRelayTunnel 的 5 秒重试周期，采用三阶无竞态恢复（tunnel-only -> start -> stop + 2s + start）；
      3. 规避 USB 重插瞬间的 MTP 枚举抖动（稳定等待 + 失败保留待办重试）；
      4. 检测 3 秒巡检间隙内的亚秒级闪断（DisconnectEvents 计数）与半开僵尸连接（GnirehtetService 存活）；
      5. 设备 offline 或恢复命令连续失败时自动执行 adb reconnect / 重启 adb server。

    调用前需先点引用 EnvCheck.ps1 与 AdbDevices.ps1。
#>

function Ensure-GnirehtetWatchdogNative {
    if (('GnirehtetConsoleGuard' -as [type]) -and ('GnirehtetRelayRunner' -as [type])) {
        return $true
    }
    $src = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public static class GnirehtetConsoleGuard {
    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_INSERT_MODE = 0x0020;
    private const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    public static bool DisableQuickEdit() {
        try {
            IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
            if (hIn == IntPtr.Zero || hIn == new IntPtr(-1)) {
                return false;
            }
            uint mode;
            if (!GetConsoleMode(hIn, out mode)) {
                return false;
            }
            uint next = (mode & ~ENABLE_QUICK_EDIT_MODE & ~ENABLE_INSERT_MODE) | ENABLE_EXTENDED_FLAGS;
            if (next == mode) {
                return true;
            }
            return SetConsoleMode(hIn, next);
        } catch {
            return false;
        }
    }
}

public class GnirehtetRelayRunner {
    private readonly object _sync = new object();
    private readonly Dictionary<string, bool> _activeClients = new Dictionary<string, bool>();
    private readonly Queue<string> _importantLines = new Queue<string>();
    private readonly Regex _connectedRegex = new Regex(@"TunnelServer:\s+Client\s+#(\d+)\s+connected\b", RegexOptions.Compiled);
    private readonly Regex _disconnectedRegex = new Regex(@"TunnelServer:\s+Client\s+#(\d+)\s+disconnected\b", RegexOptions.Compiled);

    private Process _process;
    private long _connectEvents = 0;
    private long _disconnectEvents = 0;
    private long _totalPacketEvents = 0;

    public bool Start(string exePath, string arguments, string workingDirectory) {
        Stop();
        lock (_sync) {
            _activeClients.Clear();
            _importantLines.Clear();
            _connectEvents = 0;
            _disconnectEvents = 0;
            _totalPacketEvents = 0;
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = exePath;
        psi.Arguments = arguments;
        if (workingDirectory != null && workingDirectory.Length > 0) {
            psi.WorkingDirectory = workingDirectory;
        }
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        Process proc = new Process();
        proc.StartInfo = psi;
        proc.EnableRaisingEvents = true;
        proc.OutputDataReceived += new DataReceivedEventHandler(OnOutputDataReceived);
        proc.ErrorDataReceived += new DataReceivedEventHandler(OnErrorDataReceived);

        if (!proc.Start()) {
            return false;
        }
        _process = proc;
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        return true;
    }

    private void OnOutputDataReceived(object sender, DataReceivedEventArgs e) {
        if (e != null && e.Data != null) {
            HandleLine(e.Data);
        }
    }

    private void OnErrorDataReceived(object sender, DataReceivedEventArgs e) {
        if (e != null && e.Data != null) {
            HandleLine(e.Data);
        }
    }

    private void HandleLine(string line) {
        if (line == null) {
            return;
        }
        string trimmed = line.Trim();
        if (trimmed.Length == 0) {
            return;
        }

        lock (_sync) {
            if (trimmed.IndexOf("TcpConnection:", StringComparison.Ordinal) >= 0 ||
                trimmed.IndexOf("UdpConnection:", StringComparison.Ordinal) >= 0) {
                _totalPacketEvents++;
                return;
            }

            Match mc = _connectedRegex.Match(trimmed);
            if (mc.Success) {
                string cid = mc.Groups[1].Value;
                _activeClients[cid] = true;
                _connectEvents++;
                EnqueueImportantLocked(trimmed);
                return;
            }

            Match md = _disconnectedRegex.Match(trimmed);
            if (md.Success) {
                string did = md.Groups[1].Value;
                if (_activeClients.ContainsKey(did)) {
                    _activeClients.Remove(did);
                }
                _disconnectEvents++;
                EnqueueImportantLocked(trimmed);
                return;
            }

            EnqueueImportantLocked(trimmed);
        }
    }

    private void EnqueueImportantLocked(string line) {
        if (_importantLines.Count >= 200) {
            _importantLines.Dequeue();
        }
        _importantLines.Enqueue(line);
    }

    public bool IsRunning {
        get {
            Process p = _process;
            if (p == null) {
                return false;
            }
            try {
                return !p.HasExited;
            } catch {
                return false;
            }
        }
    }

    public int ProcessId {
        get {
            Process p = _process;
            if (p == null) {
                return 0;
            }
            try {
                return p.Id;
            } catch {
                return 0;
            }
        }
    }

    public int ActiveClientCount {
        get {
            lock (_sync) {
                return _activeClients.Count;
            }
        }
    }

    public long ConnectEvents {
        get {
            lock (_sync) {
                return _connectEvents;
            }
        }
    }

    public long DisconnectEvents {
        get {
            lock (_sync) {
                return _disconnectEvents;
            }
        }
    }

    public long TotalPacketEvents {
        get {
            lock (_sync) {
                return _totalPacketEvents;
            }
        }
    }

    public string[] DrainImportantLines() {
        lock (_sync) {
            string[] arr = _importantLines.ToArray();
            _importantLines.Clear();
            return arr;
        }
    }

    public void Stop() {
        Process p = _process;
        _process = null;
        if (p == null) {
            return;
        }
        try {
            if (!p.HasExited) {
                try { p.CancelOutputRead(); } catch { }
                try { p.CancelErrorRead(); } catch { }
                p.Kill();
                p.WaitForExit(3000);
            }
        } catch {
        } finally {
            try { p.Dispose(); } catch { }
        }
    }
}
'@
    Add-Type -TypeDefinition $src -ErrorAction Stop
    return $true
}

function Disable-ConsoleQuickEdit {
    try {
        if (Ensure-GnirehtetWatchdogNative) {
            return [GnirehtetConsoleGuard]::DisableQuickEdit()
        }
    } catch { }
    return $false
}

function Test-AndroidApkInstalled {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    if (-not $AdbExe -or -not $Serial) { return $false }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', 'pm', 'path', 'com.genymobile.gnirehtet') -TimeoutSeconds 8
        if ($cap.TimedOut -or $cap.ExitCode -ne 0) { return $false }
        $raw = $cap.StdOut + "`n" + $cap.StdErr
        return ($raw -match 'package:')
    } catch {
        return $false
    }
}

function Set-AndroidPowerSavingWhitelist {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    if (-not $AdbExe -or -not $Serial) { return }
    try {
        $shellCmd = 'dumpsys deviceidle whitelist +com.genymobile.gnirehtet 2>/dev/null; cmd appops set com.genymobile.gnirehtet RUN_IN_BACKGROUND allow 2>/dev/null; cmd appops set com.genymobile.gnirehtet RUN_ANY_IN_BACKGROUND allow 2>/dev/null; true'
        Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', $shellCmd) -TimeoutSeconds 8 | Out-Null
    } catch { }
}

function Test-AdbReverseActive {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$Port = 31416
    )
    $res = New-Object PSObject -Property @{
        Ok        = $false
        HasTunnel = $false
        Raw       = ''
        TimedOut  = $false
    }
    if (-not $AdbExe -or -not $Serial) { return $res }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'reverse', '--list') -TimeoutSeconds 8
        $res.TimedOut = [bool]$cap.TimedOut
        $raw = ($cap.StdOut + "`n" + $cap.StdErr).Trim()
        $res.Raw = $raw
        if (-not $cap.TimedOut -and $cap.ExitCode -eq 0) {
            $res.Ok = $true
            $pattern = "localabstract:gnirehtet\s+tcp:$Port\b"
            $res.HasTunnel = [bool]($raw -match $pattern)
        }
    } catch {
        $res.Raw = $_.Exception.Message
    }
    return $res
}

function Test-RelayPortListening {
    param([int]$Port = 31416)
    return (@(Get-TcpPortConnections -Port $Port -ListenOnly).Count -gt 0)
}

function Test-RelayClientConnected {
    param(
        [int]$Port = 31416,
        $RelayRunner = $null
    )
    if ($null -ne $RelayRunner) {
        try {
            if ($RelayRunner.IsRunning -and $RelayRunner.ActiveClientCount -gt 0) {
                return $true
            }
        } catch { }
    }
    return (@(Get-TcpPortConnections -Port $Port | Where-Object { $_.State -eq 'Established' }).Count -gt 0)
}

function Test-AndroidGnirehtetServiceAlive {
    param(
        [string]$AdbExe,
        [string]$Serial
    )
    $res = New-Object PSObject -Property @{
        Ok       = $false
        Alive    = $false
        Raw      = ''
        TimedOut = $false
    }
    if (-not $AdbExe -or -not $Serial) { return $res }
    try {
        $cap = Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'shell', 'dumpsys', 'activity', 'services', 'com.genymobile.gnirehtet') -TimeoutSeconds 8
        $res.TimedOut = [bool]$cap.TimedOut
        $raw = ($cap.StdOut + "`n" + $cap.StdErr).Trim()
        $res.Raw = $raw
        if (-not $cap.TimedOut -and $cap.ExitCode -eq 0) {
            $res.Ok = $true
            $res.Alive = [bool]($raw -match 'GnirehtetService')
        }
    } catch {
        $res.Raw = $_.Exception.Message
    }
    return $res
}

function Start-GnirehtetRelayProcess {
    param(
        [string]$GnExe,
        [string]$ToolsDir,
        [int]$Port = 31416
    )
    Ensure-GnirehtetWatchdogNative | Out-Null
    $runner = New-Object GnirehtetRelayRunner
    $argLine = if ($Port -ne 31416) { "relay -p $Port" } else { 'relay' }
    if (-not $runner.Start($GnExe, $argLine, $ToolsDir)) {
        return $runner
    }

    for ($i = 0; $i -lt 25; $i++) {
        if (-not $runner.IsRunning) {
            return $runner
        }
        if (Test-RelayPortListening -Port $Port) {
            return $runner
        }
        Start-Sleep -Milliseconds 200
    }
    return $runner
}

function Stop-GnirehtetRelayProcess {
    param($Process)
    if (-not $Process) { return }
    try {
        $Process.Stop()
    } catch { }
}

function Write-RelayImportantLines {
    param($RelayRunner, $Hooks = $null)
    $lines = @()
    if ($Hooks -and $Hooks.ContainsKey('DrainRelayLines') -and $Hooks['DrainRelayLines']) {
        $lines = @(& $Hooks['DrainRelayLines'])
    } elseif ($null -ne $RelayRunner) {
        try { $lines = @($RelayRunner.DrainImportantLines()) } catch { $lines = @() }
    }
    foreach ($ln in $lines) {
        if (-not $ln) { continue }
        if ($ln -match 'ERROR') {
            Write-Host ('  [relay] ' + $ln) -ForegroundColor Red
        } elseif ($ln -match 'TunnelServer:\s+Client\s+#\d+\s+connected') {
            Write-Host ('  [relay] ' + $ln) -ForegroundColor Green
        } elseif ($ln -match 'TunnelServer:\s+Client\s+#\d+\s+disconnected') {
            Write-Host ('  [relay] ' + $ln) -ForegroundColor DarkYellow
        } elseif ($ln -match 'TunnelServer|listening') {
            Write-Host ('  [relay] ' + $ln) -ForegroundColor DarkGray
        }
    }
}

function Repair-AdbDeviceTransport {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$OfflineStreak
    )
    if (-not $AdbExe) { return $false }

    if ($OfflineStreak -eq 1 -or $OfflineStreak -eq 2) {
        if ($Serial) {
            try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('-s', $Serial, 'reconnect') -TimeoutSeconds 10 | Out-Null } catch { }
        }
        try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('reconnect', 'offline') -TimeoutSeconds 10 | Out-Null } catch { }
        return $true
    }

    if ($OfflineStreak -eq 4 -or ($OfflineStreak -gt 4 -and (($OfflineStreak - 4) % 5 -eq 0))) {
        try { Invoke-ProcessCapture -FilePath $AdbExe -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
        return (Initialize-AdbServer -AdbExe $AdbExe)
    }

    return $true
}

function Invoke-WatchdogHook {
    param(
        $Hooks,
        [string]$Name,
        [scriptblock]$DefaultAction,
        [object[]]$Arguments = @()
    )
    if ($Hooks -and $Hooks.ContainsKey($Name) -and $Hooks[$Name]) {
        return (& $Hooks[$Name] @Arguments)
    }
    return (& $DefaultAction @Arguments)
}

function Wait-ClientConnectedPolling {
    param(
        [int]$Port = 31416,
        $RelayRunner = $null,
        [int]$MaxWaitMs = 6500,
        [int]$StepMs = 500,
        $Hooks = $null
    )
    $elapsed = 0
    while ($true) {
        Write-RelayImportantLines -RelayRunner $RelayRunner -Hooks $Hooks
        $connected = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestClientConnected' -DefaultAction {
            param($p, $rr) Test-RelayClientConnected -Port $p -RelayRunner $rr
        } -Arguments @($Port, $RelayRunner)
        if ($connected) {
            return $true
        }
        if ($elapsed -ge $MaxWaitMs) {
            return $false
        }
        $waitNow = if (($elapsed + $StepMs) -gt $MaxWaitMs) { ($MaxWaitMs - $elapsed) } else { $StepMs }
        if ($Hooks -and $Hooks.ContainsKey('Sleep') -and $Hooks['Sleep']) {
            & $Hooks['Sleep'] 1
            $elapsed += 1000
        } else {
            Start-Sleep -Milliseconds $waitNow
            $elapsed += $waitNow
        }
    }
}

function Repair-GnirehtetConnection {
    param(
        [string]$GnExe,
        [string]$AdbExe,
        [string]$ToolsDir,
        [string]$Serial,
        [ValidateSet('initial', 'tunnel-only', 'reconnect', 'start', 'hard-restart', 'restart')]
        [string]$Mode,
        [int]$Port = 31416,
        [int]$TunnelWaitMs = 6500,
        [switch]$Stabilize,
        $RelayRunner = $null,
        $Hooks = $null
    )

    $tunnelArgs = if ($Port -ne 31416) { @('tunnel', $Serial, '-p', "$Port") } else { @('tunnel', $Serial) }
    $startArgs  = if ($Port -ne 31416) { @('start', $Serial, '-p', "$Port") }  else { @('start', $Serial) }
    $stopArgs   = @('stop', $Serial)

    if ($Mode -eq 'initial') {
        $installed = Test-AndroidApkInstalled -AdbExe $AdbExe -Serial $Serial
        if (-not $installed) {
            Write-Host '[安装] 正在向设备安装 gnirehtet 客户端……' -ForegroundColor Cyan
            $instCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments @('install', $Serial) -TimeoutSeconds 45 -WorkingDirectory $ToolsDir
            if ($instCap.TimedOut -or $instCap.ExitCode -ne 0) {
                $msg = (($instCap.StdOut + ' ' + $instCap.StdErr).Trim() -replace '\s+', ' ')
                Write-Host ("[提示] 客户端安装返回异常（退出码 {0}）：{1}" -f $instCap.ExitCode, $msg) -ForegroundColor Yellow
            }
        }
        Set-AndroidPowerSavingWhitelist -AdbExe $AdbExe -Serial $Serial
        $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
        $sCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $startArgs -TimeoutSeconds 20 -WorkingDirectory $ToolsDir
        $connected = $false
        if (-not $tCap.TimedOut -and $tCap.ExitCode -eq 0 -and -not $sCap.TimedOut -and $sCap.ExitCode -eq 0) {
            $connected = Wait-ClientConnectedPolling -Port $Port -RelayRunner $RelayRunner -MaxWaitMs 5000 -StepMs 500 -Hooks $Hooks
        }
        return (New-Object PSObject -Property @{
            Ok        = (-not $tCap.TimedOut -and $tCap.ExitCode -eq 0 -and -not $sCap.TimedOut -and $sCap.ExitCode -eq 0)
            Connected = $connected
            Mode      = 'initial'
            Tunnel    = $tCap
            Action    = $sCap
        })
    }

    if ($Mode -eq 'reconnect' -or $Mode -eq 'tunnel-only') {
        if ($Stabilize) {
            # 等待 USB 插入后 MTP/ADB 接口枚举稳定，避免瞬间抖动误判
            if ($Hooks -and $Hooks.ContainsKey('Sleep') -and $Hooks['Sleep']) {
                & $Hooks['Sleep'] 1
            } else {
                Start-Sleep -Seconds 1
            }
            $stabProbe = Invoke-WatchdogHook -Hooks $Hooks -Name 'GetDevices' -DefaultAction {
                param($a) Get-AdbDevices -AdbExe $a
            } -Arguments @($AdbExe)
            $stabHit = if ($stabProbe -and $stabProbe.Ok) {
                @($stabProbe.Devices | Where-Object { $_.Serial -eq $Serial -and $_.State -eq 'device' }) | Select-Object -First 1
            } else { $null }
            if (-not $stabHit) {
                return (New-Object PSObject -Property @{
                    Ok        = $false
                    Connected = $false
                    Mode      = 'tunnel-only'
                    Tunnel    = $null
                    Action    = $null
                })
            }
        }

        $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
        if ($tCap.TimedOut -or $tCap.ExitCode -ne 0) {
            return (New-Object PSObject -Property @{
                Ok        = $false
                Connected = $false
                Mode      = 'tunnel-only'
                Tunnel    = $tCap
                Action    = $null
            })
        }

        # 覆盖 gnirehtet.apk PersistentRelayTunnel 的 5 秒重连周期
        $connected = Wait-ClientConnectedPolling -Port $Port -RelayRunner $RelayRunner -MaxWaitMs $TunnelWaitMs -StepMs 500 -Hooks $Hooks
        if ($connected) {
            return (New-Object PSObject -Property @{
                Ok        = $true
                Connected = $true
                Mode      = 'tunnel-only'
                Tunnel    = $tCap
                Action    = $null
            })
        }

        Write-Host '[恢复] 隧道重建后客户端未回连，正在无竞态拉起手机端服务……' -ForegroundColor Cyan
        return (Repair-GnirehtetConnection -GnExe $GnExe -AdbExe $AdbExe -ToolsDir $ToolsDir -Serial $Serial -Mode 'start' -Port $Port -TunnelWaitMs $TunnelWaitMs -RelayRunner $RelayRunner -Hooks $Hooks)
    }

    if ($Mode -eq 'start') {
        Set-AndroidPowerSavingWhitelist -AdbExe $AdbExe -Serial $Serial
        $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
        if ($tCap.TimedOut -or $tCap.ExitCode -ne 0) {
            return (New-Object PSObject -Property @{
                Ok        = $false
                Connected = $false
                Mode      = 'start'
                Tunnel    = $tCap
                Action    = $null
            })
        }
        $sCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $startArgs -TimeoutSeconds 20 -WorkingDirectory $ToolsDir
        if ($sCap.TimedOut -or $sCap.ExitCode -ne 0) {
            return (New-Object PSObject -Property @{
                Ok        = $false
                Connected = $false
                Mode      = 'start'
                Tunnel    = $tCap
                Action    = $sCap
            })
        }
        $connected = Wait-ClientConnectedPolling -Port $Port -RelayRunner $RelayRunner -MaxWaitMs 5000 -StepMs 500 -Hooks $Hooks
        if ($connected) {
            return (New-Object PSObject -Property @{
                Ok        = $true
                Connected = $true
                Mode      = 'start'
                Tunnel    = $tCap
                Action    = $sCap
            })
        }

        Write-Host '[恢复] 手机端服务无响应（可能处于僵尸状态），正在执行安全硬重启……' -ForegroundColor Yellow
        return (Repair-GnirehtetConnection -GnExe $GnExe -AdbExe $AdbExe -ToolsDir $ToolsDir -Serial $Serial -Mode 'hard-restart' -Port $Port -TunnelWaitMs $TunnelWaitMs -RelayRunner $RelayRunner -Hooks $Hooks)
    }

    # Mode -eq 'hard-restart' 或 'restart'：先 stop，显式间隔 2 秒让 Android 释放 tun0，再 tunnel + start（规避原生 gnirehtet restart 的 0ms 竞态）
    Invoke-ProcessCapture -FilePath $GnExe -Arguments $stopArgs -TimeoutSeconds 10 -WorkingDirectory $ToolsDir | Out-Null
    if ($Hooks -and $Hooks.ContainsKey('Sleep') -and $Hooks['Sleep']) {
        & $Hooks['Sleep'] 2
    } else {
        Start-Sleep -Seconds 2
    }
    Set-AndroidPowerSavingWhitelist -AdbExe $AdbExe -Serial $Serial
    $tCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $tunnelArgs -TimeoutSeconds 15 -WorkingDirectory $ToolsDir
    if ($tCap.TimedOut -or $tCap.ExitCode -ne 0) {
        return (New-Object PSObject -Property @{
            Ok        = $false
            Connected = $false
            Mode      = 'hard-restart'
            Tunnel    = $tCap
            Action    = $null
        })
    }
    $sCap = Invoke-ProcessCapture -FilePath $GnExe -Arguments $startArgs -TimeoutSeconds 20 -WorkingDirectory $ToolsDir
    $ok = (-not $sCap.TimedOut -and $sCap.ExitCode -eq 0)
    $connected = if ($ok) { Wait-ClientConnectedPolling -Port $Port -RelayRunner $RelayRunner -MaxWaitMs 6000 -StepMs 500 -Hooks $Hooks } else { $false }
    return (New-Object PSObject -Property @{
        Ok        = $ok
        Connected = $connected
        Mode      = 'hard-restart'
        Tunnel    = $tCap
        Action    = $sCap
    })
}

function Invoke-GnirehtetWatchdog {
    param(
        [string]$GnExe,
        [string]$AdbExe,
        [string]$ToolsDir,
        [string]$Serial,
        [string]$DeviceLabel = '',
        [int]$Port = 31416,
        [int]$PollIntervalSeconds = 3,
        [int]$ClientGracePolls = 3,
        [int]$ServiceCheckEveryPolls = 7,
        [int]$StartupGraceSeconds = 15,
        [int]$RecoveryGraceSeconds = 10,
        [int]$MaxIterations = 0,
        $Hooks = $null
    )

    if (-not $DeviceLabel) { $DeviceLabel = $Serial }
    Disable-ConsoleQuickEdit | Out-Null

    $getNow = {
        if ($Hooks -and $Hooks.ContainsKey('Now') -and $Hooks['Now']) {
            return (& $Hooks['Now'])
        }
        return (Get-Date)
    }
    $doSleep = {
        param([int]$Sec)
        if ($Hooks -and $Hooks.ContainsKey('Sleep') -and $Hooks['Sleep']) {
            & $Hooks['Sleep'] $Sec
        } else {
            Start-Sleep -Seconds $Sec
        }
    }

    $relayProc = $null
    try {
        $relayProc = Invoke-WatchdogHook -Hooks $Hooks -Name 'StartRelay' -DefaultAction {
            param($g, $td, $p) Start-GnirehtetRelayProcess -GnExe $g -ToolsDir $td -Port $p
        } -Arguments @($GnExe, $ToolsDir, $Port)

        $relayAlive = Invoke-WatchdogHook -Hooks $Hooks -Name 'IsRelayAlive' -DefaultAction {
            param($pr) ($null -ne $pr -and $pr.IsRunning)
        } -Arguments @($relayProc)
        $relayListening = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestRelayListening' -DefaultAction {
            param($p) Test-RelayPortListening -Port $p
        } -Arguments @($Port)

        if (-not $relayAlive -or -not $relayListening) {
            Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks
            Write-Host ("[阻断] gnirehtet relay 启动失败（端口 {0} 未就绪）。" -f $Port) -ForegroundColor Red
            return 2
        }

        Write-Host ("[就绪] 本机转发服务已在 127.0.0.1:{0} 启动（已关闭窗口误点卡死保护）。" -f $Port) -ForegroundColor Green

        $initRes = Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
            param($g, $a, $td, $s, $m, $p, $rr, $h, $stab)
            Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -RelayRunner $rr -Hooks $h -Stabilize:$stab
        } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'initial', $Port, $relayProc, $Hooks, $false)

        Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks
        if (-not $initRes -or -not $initRes.Ok) {
            Write-Host '[提示] 首次启动客户端未完全就绪，守护循环将继续自动重试。' -ForegroundColor Yellow
        }

        $graceUntil = (& $getNow).AddSeconds($StartupGraceSeconds)
        $lastState = 'starting'
        $hadDisconnect = $false
        $adbFailStreak = 0
        $offlineStreak = 0
        $repairFailStreak = 0
        $noClientStreak = 0
        $restartFailStreak = 0
        $warnedPersistentFail = $false
        $lastDisconnectEvents = 0L
        $lastPacketEvents = 0L
        $trafficReported = $false
        $pollCount = 0

        while ($MaxIterations -le 0 -or $pollCount -lt $MaxIterations) {
            $pollCount++
            & $doSleep $PollIntervalSeconds
            Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks

            # 统计 relay 关键状态变化（亚秒级闪断 & 流量存活）
            $stats = if ($Hooks -and $Hooks.ContainsKey('GetRelayStats') -and $Hooks['GetRelayStats']) {
                & $Hooks['GetRelayStats']
            } elseif ($null -ne $relayProc) {
                try {
                    New-Object PSObject -Property @{
                        DisconnectEvents  = [int64]$relayProc.DisconnectEvents
                        TotalPacketEvents = [int64]$relayProc.TotalPacketEvents
                    }
                } catch { $null }
            } else { $null }

            if ($stats) {
                if ($stats.DisconnectEvents -gt $lastDisconnectEvents) {
                    $lastDisconnectEvents = $stats.DisconnectEvents
                    $stillConn = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestClientConnected' -DefaultAction {
                        param($p, $rr) Test-RelayClientConnected -Port $p -RelayRunner $rr
                    } -Arguments @($Port, $relayProc)
                    if (-not $stillConn) {
                        $hadDisconnect = $true
                        $trafficReported = $false
                    }
                }
                if (-not $trafficReported -and $stats.TotalPacketEvents -gt $lastPacketEvents) {
                    $lastPacketEvents = $stats.TotalPacketEvents
                    $trafficReported = $true
                    Write-Host '[流量] 手机网络数据包已开始正常转发。' -ForegroundColor DarkGreen
                } elseif ($stats.TotalPacketEvents -gt $lastPacketEvents) {
                    $lastPacketEvents = $stats.TotalPacketEvents
                }
            }

            # 1. 检查本机 relay 是否仍在监听
            $relayAlive = Invoke-WatchdogHook -Hooks $Hooks -Name 'IsRelayAlive' -DefaultAction {
                param($pr) ($null -ne $pr -and $pr.IsRunning)
            } -Arguments @($relayProc)
            $relayListening = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestRelayListening' -DefaultAction {
                param($p) Test-RelayPortListening -Port $p
            } -Arguments @($Port)

            if (-not $relayAlive -or -not $relayListening) {
                Write-Host '[恢复] 检测到本机转发服务已退出，正在自动重启……' -ForegroundColor Yellow
                Invoke-WatchdogHook -Hooks $Hooks -Name 'StopRelay' -DefaultAction {
                    param($pr) Stop-GnirehtetRelayProcess -Process $pr
                } -Arguments @($relayProc) | Out-Null
                $relayProc = Invoke-WatchdogHook -Hooks $Hooks -Name 'StartRelay' -DefaultAction {
                    param($g, $td, $p) Start-GnirehtetRelayProcess -GnExe $g -ToolsDir $td -Port $p
                } -Arguments @($GnExe, $ToolsDir, $Port)
                $hadDisconnect = $true
                $trafficReported = $false
                $lastDisconnectEvents = 0L
                $lastPacketEvents = 0L
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                continue
            }

            # 2. 探测 adb 设备列表
            $probe = Invoke-WatchdogHook -Hooks $Hooks -Name 'GetDevices' -DefaultAction {
                param($a) Get-AdbDevices -AdbExe $a
            } -Arguments @($AdbExe)

            if (-not $probe -or -not $probe.Ok) {
                $adbFailStreak++
                if ($adbFailStreak -ge 3) {
                    Write-Host '[恢复] adb 服务连续无响应，正在重启 adb server……' -ForegroundColor Yellow
                    Invoke-WatchdogHook -Hooks $Hooks -Name 'RestartAdbServer' -DefaultAction {
                        param($a)
                        try { Invoke-ProcessCapture -FilePath $a -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
                        Initialize-AdbServer -AdbExe $a
                    } -Arguments @($AdbExe) | Out-Null
                    $adbFailStreak = 0
                    $hadDisconnect = $true
                }
                continue
            }
            $adbFailStreak = 0

            $hit = @($probe.Devices | Where-Object { $_.Serial -eq $Serial }) | Select-Object -First 1

            # 3. 设备从列表消失（USB 线松动 / 拔出）
            if (-not $hit) {
                if ($lastState -ne 'disconnected') {
                    Write-Host ("[断连] 未检测到设备「{0}」（数据线可能松动或已拔出），等待重新连接……" -f $DeviceLabel) -ForegroundColor Yellow
                    $lastState = 'disconnected'
                }
                $hadDisconnect = $true
                $trafficReported = $false
                $offlineStreak = 0
                $noClientStreak = 0
                continue
            }

            # 4. 设备处于 offline
            if ($hit.State -eq 'offline') {
                $offlineStreak++
                if ($lastState -ne 'offline') {
                    Write-Host ("[断连] 设备「{0}」处于离线状态（offline），正在自动尝试恢复 ADB 连接……" -f $DeviceLabel) -ForegroundColor Yellow
                    $lastState = 'offline'
                }
                $hadDisconnect = $true
                $trafficReported = $false
                $noClientStreak = 0
                Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairTransport' -DefaultAction {
                    param($a, $s, $st) Repair-AdbDeviceTransport -AdbExe $a -Serial $s -OfflineStreak $st
                } -Arguments @($AdbExe, $Serial, $offlineStreak) | Out-Null
                continue
            }

            $offlineStreak = 0

            # 5. 设备未授权
            if ($hit.State -eq 'unauthorized') {
                if ($lastState -ne 'unauthorized') {
                    Write-Host ("[等待授权] 设备「{0}」需要重新授权，请在手机屏幕上点击「允许 USB 调试」……" -f $DeviceLabel) -ForegroundColor Cyan
                    $lastState = 'unauthorized'
                }
                $hadDisconnect = $true
                $trafficReported = $false
                $noClientStreak = 0
                continue
            }

            # 6. 其他非可用状态（bootloader / recovery / sideload）
            if ($hit.State -ne 'device') {
                if ($lastState -ne $hit.State) {
                    Write-Host ("[等待] 设备「{0}」当前状态：{1}，等待恢复……" -f $DeviceLabel, (Get-DeviceStateText -State $hit.State)) -ForegroundColor Yellow
                    $lastState = $hit.State
                }
                $hadDisconnect = $true
                $trafficReported = $false
                $noClientStreak = 0
                continue
            }

            # 7. 设备已在线（device）：处理断连后恢复
            if ($hadDisconnect) {
                Write-Host ("[重连] 设备「{0}」已重新连接，正在自动恢复隧道与服务……" -f $DeviceLabel) -ForegroundColor Cyan
                $repRes = Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $rr, $h, $stab)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -RelayRunner $rr -Hooks $h -Stabilize:$stab
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'tunnel-only', $Port, $relayProc, $Hooks, $true)
                Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks

                if ($repRes -and $repRes.Ok) {
                    $hadDisconnect = $false
                    $repairFailStreak = 0
                    $noClientStreak = 0
                    $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                    $lastState = 'recovering'
                } else {
                    # 命令失败或 USB 刚插上抖动：保留 hadDisconnect=$true，按阶梯自愈 ADB
                    $repairFailStreak++
                    if ($repairFailStreak -eq 2) {
                        Write-Host '[恢复] 重建隧道连续失败，尝试重置 ADB 设备连接……' -ForegroundColor Yellow
                        Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairTransport' -DefaultAction {
                            param($a, $s, $st) Repair-AdbDeviceTransport -AdbExe $a -Serial $s -OfflineStreak $st
                        } -Arguments @($AdbExe, $Serial, 1) | Out-Null
                    } elseif ($repairFailStreak -ge 3) {
                        Write-Host '[恢复] 重建隧道多次失败，正在重启 adb server……' -ForegroundColor Yellow
                        Invoke-WatchdogHook -Hooks $Hooks -Name 'RestartAdbServer' -DefaultAction {
                            param($a)
                            try { Invoke-ProcessCapture -FilePath $a -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
                            Initialize-AdbServer -AdbExe $a
                        } -Arguments @($AdbExe) | Out-Null
                        $repairFailStreak = 0
                    }
                }
                continue
            }

            # 8. 轻量校验 adb reverse 映射是否存在（同时起到 USB/ADB 链路保活作用）
            $rev = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestReverse' -DefaultAction {
                param($a, $s, $p) Test-AdbReverseActive -AdbExe $a -Serial $s -Port $p
            } -Arguments @($AdbExe, $Serial, $Port)

            if ($rev -and $rev.Ok -and -not $rev.HasTunnel) {
                Write-Host '[恢复] 检测到 adb reverse 隧道丢失，正在自动重建……' -ForegroundColor Yellow
                $repRes = Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $rr, $h, $stab)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -RelayRunner $rr -Hooks $h -Stabilize:$stab
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'tunnel-only', $Port, $relayProc, $Hooks, $false)
                Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks
                if ($repRes -and $repRes.Ok) {
                    $repairFailStreak = 0
                    $noClientStreak = 0
                    $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                    $lastState = 'recovering'
                } else {
                    $hadDisconnect = $true
                }
                continue
            }

            # 9. 检查是否存在活跃客户端连接
            $clientConnected = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestClientConnected' -DefaultAction {
                param($p, $rr) Test-RelayClientConnected -Port $p -RelayRunner $rr
            } -Arguments @($Port, $relayProc)

            if ($clientConnected) {
                if ($lastState -ne 'connected') {
                    if ($lastState -eq 'recovering') {
                        Write-Host ("[已恢复] 「{0}」USB 反向网络已自动恢复连通。" -f $DeviceLabel) -ForegroundColor Green
                    } else {
                        Write-Host ("[运行中] 「{0}」USB 反向网络已连通，断连自愈守护已开启。" -f $DeviceLabel) -ForegroundColor Green
                    }
                    $lastState = 'connected'
                }
                $noClientStreak = 0
                $restartFailStreak = 0
                $repairFailStreak = 0
                $warnedPersistentFail = $false

                # 定期排查「半开僵尸连接」：端口仍显示连通，但手机端服务已被锁屏清理
                if ($ServiceCheckEveryPolls -gt 0 -and ($pollCount % $ServiceCheckEveryPolls -eq 0)) {
                    $svc = Invoke-WatchdogHook -Hooks $Hooks -Name 'TestServiceAlive' -DefaultAction {
                        param($a, $s) Test-AndroidGnirehtetServiceAlive -AdbExe $a -Serial $s
                    } -Arguments @($AdbExe, $Serial)

                    if ($svc -and $svc.Ok -and -not $svc.Alive) {
                        Write-Host '[恢复] 检测到手机端 gnirehtet 服务已停止（可能因锁屏休眠），正在自动拉起……' -ForegroundColor Yellow
                        Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                            param($g, $a, $td, $s, $m, $p, $rr, $h, $stab)
                            Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -RelayRunner $rr -Hooks $h -Stabilize:$stab
                        } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'start', $Port, $relayProc, $Hooks, $false) | Out-Null
                        Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks
                        $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                        $lastState = 'recovering'
                    }
                }
                continue
            }

            # 未连通：如果在宽限期内则继续等待
            if ((& $getNow) -lt $graceUntil) {
                continue
            }

            $noClientStreak++
            $threshold = if ($restartFailStreak -ge 3) { 7 } else { $ClientGracePolls }
            if ($noClientStreak -ge $threshold) {
                if ($restartFailStreak -ge 3 -and -not $warnedPersistentFail) {
                    Write-Host '[提示] 连续多次自动拉起仍未连通：请解锁手机确认是否弹出 VPN 授权，并建议在「最近任务」锁定 gnirehtet、省电策略设为无限制。程序仍会继续自动重试。' -ForegroundColor Yellow
                    $warnedPersistentFail = $true
                } else {
                    Write-Host '[恢复] 检测到手机端连接已断开（可能锁屏休眠或后台被清理），正在自动拉起客户端……' -ForegroundColor Yellow
                }

                $repRes = Invoke-WatchdogHook -Hooks $Hooks -Name 'RepairConnection' -DefaultAction {
                    param($g, $a, $td, $s, $m, $p, $rr, $h, $stab)
                    Repair-GnirehtetConnection -GnExe $g -AdbExe $a -ToolsDir $td -Serial $s -Mode $m -Port $p -RelayRunner $rr -Hooks $h -Stabilize:$stab
                } -Arguments @($GnExe, $AdbExe, $ToolsDir, $Serial, 'start', $Port, $relayProc, $Hooks, $false)
                Write-RelayImportantLines -RelayRunner $relayProc -Hooks $Hooks

                $noClientStreak = 0
                $restartFailStreak++
                if (-not $repRes -or -not $repRes.Ok) {
                    $repairFailStreak++
                    if ($repairFailStreak -ge 3) {
                        Write-Host '[恢复] 拉起客户端多次失败，正在重启 adb server……' -ForegroundColor Yellow
                        Invoke-WatchdogHook -Hooks $Hooks -Name 'RestartAdbServer' -DefaultAction {
                            param($a)
                            try { Invoke-ProcessCapture -FilePath $a -Arguments @('kill-server') -TimeoutSeconds 10 | Out-Null } catch { }
                            Initialize-AdbServer -AdbExe $a
                        } -Arguments @($AdbExe) | Out-Null
                        $repairFailStreak = 0
                    }
                } else {
                    $repairFailStreak = 0
                }
                $graceUntil = (& $getNow).AddSeconds($RecoveryGraceSeconds)
                $lastState = 'recovering'
            }
        }

        return 0
    } finally {
        Write-Host ''
        Write-Host '[*] 正在收尾：停止本机转发与手机端反向网络……' -ForegroundColor DarkGray
        try {
            Invoke-WatchdogHook -Hooks $Hooks -Name 'StopRelay' -DefaultAction {
                param($pr) Stop-GnirehtetRelayProcess -Process $pr
            } -Arguments @($relayProc) | Out-Null
        } catch { }
        try {
            Invoke-WatchdogHook -Hooks $Hooks -Name 'StopClient' -DefaultAction {
                param($g, $td, $s)
                Invoke-ProcessCapture -FilePath $g -Arguments @('stop', $s) -TimeoutSeconds 8 -WorkingDirectory $td | Out-Null
            } -Arguments @($GnExe, $ToolsDir, $Serial) | Out-Null
            Write-Host '[完成] 已停止，手机已恢复原有网络。' -ForegroundColor Green
        } catch { }
    }
}
