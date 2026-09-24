<#
.SYNOPSIS
  Record read-only Minecraft process, GPU memory, and optional BenchCam frame stats to CSV.
#>
[CmdletBinding()]
param(
    [string]$InstancePath = (Join-Path $env:APPDATA 'PrismLauncher\instances\ShaderBench'),
    [int]$ProcessId,
    [ValidateRange(1, 86400)][int]$DurationSeconds = 60,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 1,
    [string]$OutputPath,
    [switch]$BenchCam,
    [ValidateRange(1, 65535)][int]$BenchCamPort = 25599
)

$ErrorActionPreference = 'Stop'

function Normalize-PathText([string]$Value) {
    return $Value.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

$expectedInstance = Normalize-PathText ([IO.Path]::GetFullPath($InstancePath))
$processRows = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'")
if (-not $ProcessId) {
    $matchesInstance = @($processRows | Where-Object {
        $_.CommandLine -and (Normalize-PathText $_.CommandLine).Contains($expectedInstance)
    })
    if ($matchesInstance.Count -ne 1) {
        throw "Expected exactly one Java process with instance path '$InstancePath'; found $($matchesInstance.Count). Pass -ProcessId only after checking the intended process."
    }
    $ProcessId = [int]$matchesInstance[0].ProcessId
}

$identity = $processRows | Where-Object { [int]$_.ProcessId -eq $ProcessId } | Select-Object -First 1
if (-not $identity) { throw "PID $ProcessId is not a running java.exe/javaw.exe process." }
if (-not $identity.CommandLine -or -not (Normalize-PathText $identity.CommandLine).Contains($expectedInstance)) {
    throw "PID $ProcessId does not identify a Java process launched from '$InstancePath'. No samples written."
}
$initialProcess = Get-Process -Id $ProcessId
$initialPath = [IO.Path]::GetFullPath($initialProcess.Path)
$initialStart = $initialProcess.StartTime

if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $env:TEMP "mc-shader-telemetry-$stamp.csv"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
if (Test-Path -LiteralPath $OutputPath) { throw "Output already exists: $OutputPath" }

$gpuCounterSet = Get-Counter -ListSet 'GPU Process Memory'
$gpuPaths = @($gpuCounterSet.PathsWithInstances | Where-Object {
    $_ -match "(?i)pid_${ProcessId}_" -and $_ -match '(?i)\\(Dedicated Usage|Shared Usage|Total Committed)$'
})
$memoryPaths = @('\Memory\Committed Bytes', '\Memory\Commit Limit', '\Memory\Available MBytes')
$counterPaths = @($gpuPaths) + $memoryPaths
$nvidiaSmi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
$startedAt = Get-Date
$endsAt = $startedAt.AddSeconds($DurationSeconds)
$rowCount = 0

function Get-BenchCamFps {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.ReceiveTimeout = 500
        $client.SendTimeout = 500
        $client.Connect([Net.IPAddress]::Loopback, $BenchCamPort)
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes("status`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
        $reply = $reader.ReadLine()
        if ($reply -match '(^|\s)fps=([0-9]+)') { return [int]$Matches[2] }
        return $null
    } catch {
        return $null
    } finally {
        $client.Dispose()
    }
}

while ((Get-Date) -lt $endsAt) {
    $sampleAt = Get-Date
    $liveProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $liveProcess -or $liveProcess.StartTime -ne $initialStart -or [IO.Path]::GetFullPath($liveProcess.Path) -ne $initialPath) {
        Write-Warning "Validated Java process $ProcessId exited or changed identity; stopping capture."
        break
    }

    $dedicated = $null
    $shared = $null
    $committed = $null
    $systemCommitted = $null
    $systemCommitLimit = $null
    $availablePhysical = $null
    $sampleError = ''
    try {
        $samples = (Get-Counter -Counter $counterPaths).CounterSamples
        foreach ($sample in $samples) {
            $bytes = [int64][math]::Round($sample.CookedValue)
            if ($sample.Path -match '(?i)\\Dedicated Usage$') { $dedicated += $bytes }
            elseif ($sample.Path -match '(?i)\\Shared Usage$') { $shared += $bytes }
            elseif ($sample.Path -match '(?i)\\Total Committed$') { $committed += $bytes }
            elseif ($sample.Path -match '(?i)\\Memory\\Committed Bytes$') { $systemCommitted = $bytes }
            elseif ($sample.Path -match '(?i)\\Memory\\Commit Limit$') { $systemCommitLimit = $bytes }
            elseif ($sample.Path -match '(?i)\\Memory\\Available MBytes$') { $availablePhysical = $bytes * 1MB }
        }
        if ($gpuPaths.Count -eq 0) { $sampleError = "No GPU Process Memory instances found for PID $ProcessId" }
    } catch { $sampleError = "Performance counters: $($_.Exception.Message)" }

    $nvidiaName = $null
    $nvidiaUsed = $null
    $nvidiaTotal = $null
    $nvidiaGpuUtil = $null
    $nvidiaMemoryUtil = $null
    if ($nvidiaSmi) {
        try {
            $gpuLine = @(& $nvidiaSmi --query-gpu=name,memory.used,memory.total,utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if ($gpuLine.Count -gt 0) {
                $fields = $gpuLine[0] -split ',\s*'
                if ($fields.Count -ge 5) {
                    $nvidiaName = $fields[0].Trim()
                    $nvidiaUsed = [int]$fields[1].Trim()
                    $nvidiaTotal = [int]$fields[2].Trim()
                    $parsed = 0
                    if ([int]::TryParse($fields[3].Trim(), [ref]$parsed)) { $nvidiaGpuUtil = $parsed }
                    if ([int]::TryParse($fields[4].Trim(), [ref]$parsed)) { $nvidiaMemoryUtil = $parsed }
                }
            }
        } catch { if ($sampleError) { $sampleError += '; ' }; $sampleError += "nvidia-smi: $($_.Exception.Message)" }
    } elseif ($sampleError) { $sampleError += '; nvidia-smi.exe not found' } else { $sampleError = 'nvidia-smi.exe not found' }

    $benchFps = $null
    if ($BenchCam) { $benchFps = Get-BenchCamFps }

    $row = [pscustomobject]@{
        TimestampLocal = $sampleAt.ToString('o')
        ProcessId = $ProcessId
        ProcessStartTimeLocal = $initialStart.ToString('o')
        InstancePath = $InstancePath
        JavaPrivateBytes = [int64]$liveProcess.PrivateMemorySize64
        JavaWorkingSetBytes = [int64]$liveProcess.WorkingSet64
        GpuDedicatedBytes = $dedicated
        GpuSharedBytes = $shared
        GpuTotalCommittedBytes = $committed
        SystemCommittedBytes = $systemCommitted
        SystemCommitLimitBytes = $systemCommitLimit
        AvailablePhysicalBytes = $availablePhysical
        NvidiaGpuName = $nvidiaName
        NvidiaVramUsedMiB = $nvidiaUsed
        NvidiaVramTotalMiB = $nvidiaTotal
        NvidiaGpuUtilPercent = $nvidiaGpuUtil
        NvidiaMemoryUtilPercent = $nvidiaMemoryUtil
        BenchCamFps = $benchFps
        SampleError = $sampleError
    }
    if ($rowCount -eq 0) { $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8 }
    else { $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8 -Append }
    $rowCount++

    $remaining = $endsAt - (Get-Date)
    if ($remaining.TotalSeconds -gt 0) {
        $sleepMs = [math]::Max(0, [int](($IntervalSeconds * 1000) - ((Get-Date) - $sampleAt).TotalMilliseconds))
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds ([math]::Min($sleepMs, [int]$remaining.TotalMilliseconds)) }
    }
}

Write-Host "Wrote $rowCount samples to $OutputPath"
