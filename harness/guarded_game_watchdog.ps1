# Guard one deliberately risky Minecraft shader run. Start this in a separate,
# hidden PowerShell process only after BenchCam is listening for the target game.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$TargetProcessId,
    [Parameter(Mandatory)][string]$InstancePath,
    [Parameter(Mandatory)][ValidateRange(1, 9223372036854775807)][long]$ExpectedStartFileTimeUtc,
    [Parameter(Mandatory)][DateTimeOffset]$DeadlineUtc,
    [Parameter(Mandatory)][string]$CancelSignalPath,
    [ValidateRange(1, 65535)][int]$BenchCamPort = 25599
)

$ErrorActionPreference = 'Stop'

if (-not ('GuardedGameProcess' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class GuardedGameProcess {
    const uint PROCESS_TERMINATE = 0x0001;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint SYNCHRONIZE = 0x00100000;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr process,
        out System.Runtime.InteropServices.ComTypes.FILETIME creation,
        out System.Runtime.InteropServices.ComTypes.FILETIME exit,
        out System.Runtime.InteropServices.ComTypes.FILETIME kernel,
        out System.Runtime.InteropServices.ComTypes.FILETIME user);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool ClipCursor(IntPtr rect);

    public static IntPtr Open(int pid) {
        IntPtr handle = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                                    false, pid);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
        return handle;
    }

    public static long StartFileTimeUtc(IntPtr handle) {
        System.Runtime.InteropServices.ComTypes.FILETIME created, exited, kernel, user;
        if (!GetProcessTimes(handle, out created, out exited, out kernel, out user))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcessTimes failed");
        return unchecked((long)(((ulong)(uint)created.dwHighDateTime << 32) |
                                (uint)created.dwLowDateTime));
    }

    public static bool Running(IntPtr handle) {
        uint result = WaitForSingleObject(handle, 0);
        if (result == WAIT_OBJECT_0) return false;
        if (result == WAIT_TIMEOUT) return true;
        throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
    }

    public static bool StopAndWait(IntPtr handle) {
        if (!Running(handle)) return false;
        if (!TerminateProcess(handle, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateProcess failed");
        uint result = WaitForSingleObject(handle, 3000);
        if (result == WAIT_OBJECT_0) return true;
        if (result == WAIT_TIMEOUT) throw new TimeoutException("Minecraft did not exit within three seconds");
        throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
    }

    public static void ReleaseCursor() {
        if (!ClipCursor(IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ClipCursor(NULL) failed");
    }
}
'@
}

function Test-TargetIdentity {
    param([IntPtr]$Handle, [int]$ProcessId, [string]$CanonicalInstance, [long]$ExpectedStart)
    if ([GuardedGameProcess]::StartFileTimeUtc($Handle) -ne $ExpectedStart) {
        throw 'Process creation FILETIME differs from the expected identity; refusing to arm.'
    }
    if (-not [GuardedGameProcess]::Running($Handle)) {
        throw 'Target Java process has already exited.'
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
    if ($null -eq $process -or $process.Name -notin @('java.exe', 'javaw.exe')) {
        throw 'Target PID is not the intended Minecraft Java process.'
    }
    # Never print or save CommandLine: it can contain a Minecraft access token.
    $commandLine = ([string]$process.CommandLine).Replace('/', '\').ToLowerInvariant()
    $root = $CanonicalInstance.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $instancePattern = [regex]::Escape($root) + '(?:\\|[\s"'']|$)'
    if (-not [regex]::IsMatch($commandLine, $instancePattern)) {
        throw 'Target Java command line does not refer to the requested Prism instance.'
    }
    if (-not ($commandLine.Contains('knotclient') -or
                $commandLine.Contains('net.minecraft.client.main.main') -or
                $commandLine.Contains('org.prismlauncher.entrypoint'))) {
        throw 'Target Java command line does not identify a Minecraft client.'
    }
    # The open handle cannot be retargeted to a reused PID. Recheck it after CIM's PID lookup.
    if (-not [GuardedGameProcess]::Running($Handle) -or
        [GuardedGameProcess]::StartFileTimeUtc($Handle) -ne $ExpectedStart) {
        throw 'Target exited during identity validation.'
    }
}

function Test-BenchCamOwner {
    param([int]$ProcessId, [int]$Port)
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' })
    if ($listeners.Count -eq 0) { return 'missing' }
    if (@($listeners | Where-Object { $_.OwningProcess -ne $ProcessId }).Count -gt 0) { return 'wrong-owner' }
    return 'verified'
}

function Invoke-BenchCam {
    param([string]$Command, [int]$Port, [int]$TimeoutMilliseconds = 1500)
    $client = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connect = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port)
        if (-not $connect.Wait([TimeSpan]::FromMilliseconds([Math]::Min(500, $TimeoutMilliseconds)))) {
            return 'timeout'
        }
        $connect.GetAwaiter().GetResult()
        $stream = $client.GetStream()
        $payload = [System.Text.Encoding]::UTF8.GetBytes($Command + "`n")
        $stream.WriteTimeout = [Math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        $stream.Write($payload, 0, $payload.Length)
        $bytes = [System.Collections.Generic.List[byte]]::new()
        while ($bytes.Count -lt 512) {
            $remaining = $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) { return 'timeout' }
            $stream.ReadTimeout = $remaining
            $byte = $stream.ReadByte()
            if ($byte -lt 0) { return 'closed' }
            if ($byte -eq 10) {
                return ([System.Text.Encoding]::UTF8.GetString($bytes.ToArray())).TrimEnd("`r")
            }
            $bytes.Add([byte]$byte)
        }
        return 'oversize-reply'
    } catch [System.TimeoutException] {
        return 'timeout'
    } catch [System.IO.IOException] {
        return 'io-error'
    } catch [System.Net.Sockets.SocketException] {
        return 'socket-error'
    } catch [System.AggregateException] {
        return 'socket-error'
    } finally {
        $client.Dispose()
    }
}

$handle = [IntPtr]::Zero
try {
    $instance = (Resolve-Path -LiteralPath $InstancePath -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath (Join-Path $instance 'minecraft') -PathType Container)) {
        throw 'InstancePath is not a Prism Minecraft instance directory.'
    }
    if (-not [System.IO.Path]::IsPathRooted($CancelSignalPath)) {
        throw 'CancelSignalPath must be an absolute path.'
    }
    $cancel = [System.IO.Path]::GetFullPath($CancelSignalPath)
    if (Test-Path -LiteralPath $cancel) { throw 'Cancel signal already exists; use a fresh path.' }
    if ($DeadlineUtc.Offset -ne [TimeSpan]::Zero) { throw 'DeadlineUtc must have an explicit UTC offset (Z or +00:00).' }
    $remaining = ($DeadlineUtc - [DateTimeOffset]::UtcNow).TotalSeconds
    if ($remaining -le 0 -or $remaining -gt 900) { throw 'Deadline must be in the next 15 minutes.' }

    $handle = [GuardedGameProcess]::Open($TargetProcessId)
    Test-TargetIdentity -Handle $handle -ProcessId $TargetProcessId -CanonicalInstance $instance `
        -ExpectedStart $ExpectedStartFileTimeUtc
    if ((Test-BenchCamOwner -ProcessId $TargetProcessId -Port $BenchCamPort) -ne 'verified') {
        throw 'BenchCam listener is absent or not owned by the verified Java process; refusing to arm.'
    }
    Write-Output "guard armed for PID $TargetProcessId until $($DeadlineUtc.ToString('o'))"

    while ([DateTimeOffset]::UtcNow -lt $DeadlineUtc) {
        if (Test-Path -LiteralPath $cancel) { Write-Output 'guard canceled'; exit 0 }
        if (-not [GuardedGameProcess]::Running($handle)) { Write-Output 'target exited'; exit 0 }
        Start-Sleep -Milliseconds 250
    }
    if (Test-Path -LiteralPath $cancel) { Write-Output 'guard canceled'; exit 0 }
    if (-not [GuardedGameProcess]::Running($handle)) { Write-Output 'target exited'; exit 0 }
    if ((Test-BenchCamOwner -ProcessId $TargetProcessId -Port $BenchCamPort) -ne 'verified') {
        throw 'BenchCam listener ownership changed; refusing to send commands or kill the game.'
    }

    $off = Invoke-BenchCam -Command 'shaders off' -Port $BenchCamPort
    if ($off -eq 'ok') { Write-Output 'shader disable acknowledged'; exit 0 }
    if (Test-Path -LiteralPath $cancel) { Write-Output 'guard canceled'; exit 0 }
    if (-not [GuardedGameProcess]::Running($handle)) { Write-Output 'target exited'; exit 0 }
    if ((Test-BenchCamOwner -ProcessId $TargetProcessId -Port $BenchCamPort) -ne 'verified') {
        throw 'BenchCam listener ownership changed after shader disable attempt; refusing to kill.'
    }
    $status = Invoke-BenchCam -Command 'status' -Port $BenchCamPort
    if ($status.StartsWith('ok ') -or $status.StartsWith('err ')) {
        Write-Warning "Render thread replied, but shader disable was not acknowledged ($off); leaving Minecraft alive."
        exit 2
    }
    if (Test-Path -LiteralPath $cancel) { Write-Output 'guard canceled'; exit 0 }
    if ((Test-BenchCamOwner -ProcessId $TargetProcessId -Port $BenchCamPort) -ne 'verified') {
        throw 'BenchCam listener ownership changed before forced stop; refusing to kill.'
    }
    if ([GuardedGameProcess]::StartFileTimeUtc($handle) -ne $ExpectedStartFileTimeUtc) {
        throw 'Process identity changed before forced stop; refusing to kill.'
    }
    if ([GuardedGameProcess]::StopAndWait($handle)) {
        [GuardedGameProcess]::ReleaseCursor()
        Write-Warning "Unresponsive guarded Minecraft PID $TargetProcessId was stopped; stale ClipCursor released."
        exit 3
    }
    Write-Output 'target exited before forced stop'
    exit 0
} catch {
    [Console]::Error.WriteLine("guard error: $($_.Exception.Message)")
    exit 2
} finally {
    if ($handle -ne [IntPtr]::Zero) { [void][GuardedGameProcess]::CloseHandle($handle) }
}
