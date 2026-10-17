#requires -Version 5.1
<#
.SYNOPSIS
Repairs the native Windows Update Agent inside a guest VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$LogPath,
    [switch]$DeepRepair,
    [switch]$ForceDeepRepair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow

function Write-RepairLog {
    param(
        [Parameter(Mandatory)][ValidateSet('Information', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data = @{}
    )
    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        stage = $Stage
        computerName = $env:COMPUTERNAME
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 10 -Compress | ForEach-Object {
        $line = $_
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $stream = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                try {
                    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.UTF8Encoding]::new($false))
                    $writer.WriteLine($line)
                    $writer.Flush()
                }
                finally {
                    $writer.Dispose()
                    $stream.Dispose()
                }
                break
            }
            catch {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }
}

function Test-WindowsUpdateComAvailable {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'Enterprise Windows Patch Automation Framework'
        $null = New-Object -ComObject Microsoft.Update.SystemInfo
        return $true
    }
    catch {
        return $false
    }
}

function Set-WindowsUpdateServiceState {
    param(
        [Parameter(Mandatory)][ValidateSet('Stop', 'Start')][string]$Action,
        [string[]]$ServiceNames = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    )

    foreach ($serviceName in $ServiceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        if ($Action -eq 'Stop' -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }
        if ($Action -eq 'Start' -and $service.Status -ne 'Running') {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Stage
    )

    Write-RepairLog -Level Information -Stage $Stage -Message "Running $FilePath $($ArgumentList -join ' ')."
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $exitCode = [int]$process.ExitCode
    }
    catch {
        if ($_.Exception.Message -match '800703FA|marked for deletion') {
            throw [System.InvalidOperationException]::new('ServicingRebootRequired')
        }
        throw
    }
    Write-RepairLog -Level Information -Stage $Stage -Message 'Command completed.' -Data @{
        exitCode = $exitCode
        processId = $process.Id
    }
    return $exitCode
}

$result = [ordered]@{
    schemaVersion = '1.0'
    computerName = $env:COMPUTERNAME
    status = 'Failed'
    startedUtc = $started.ToString('o')
    completedUtc = $null
    durationSeconds = 0
    basicRepairApplied = $false
    deepRepairApplied = $false
    dismExitCode = $null
    sfcExitCode = $null
    comAvailable = $false
    rebootRequired = $false
    error = $null
}

try {
    Write-RepairLog -Level Information -Stage Initialize -Message 'Starting Windows Update Agent repair.'

    try {
        & "$env:SystemRoot\System32\netsh.exe" winhttp reset proxy | Out-Null
        $auKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (Test-Path -LiteralPath $auKey) {
            Remove-ItemProperty -LiteralPath $auKey -Name UseWUServer -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $auKey -Name WUServer -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $auKey -Name WUStatusServer -ErrorAction SilentlyContinue
        }
        Write-RepairLog -Level Information -Stage Initialize -Message 'Reset WinHTTP proxy and cleared WSUS policy overrides when present.'
    }
    catch {
        Write-RepairLog -Level Warning -Stage Initialize -Message 'Could not reset WinHTTP/WSUS settings.' -Data @{
            error = $_.Exception.Message
        }
    }

    if ($ForceDeepRepair) {
        $DeepRepair = $true
        Write-RepairLog -Level Warning -Stage DeepRepair -Message 'Forced deep repair requested; running DISM/SFC even if quick COM check passes.'
    }

    if (-not $DeepRepair -and (Test-WindowsUpdateComAvailable)) {
        $result.basicRepairApplied = $false
        $result.comAvailable = $true
        $result.status = 'Ready'
        Write-RepairLog -Level Information -Stage Verify -Message 'Windows Update COM is already available.'
        return
    }

    if (-not (Test-WindowsUpdateComAvailable)) {
        Write-RepairLog -Level Warning -Stage Remediation -Message 'Windows Update COM unavailable; applying basic service and cache repair.'
        Set-WindowsUpdateServiceState -Action Stop
        Start-Sleep -Seconds 5

        $distributionPath = Join-Path $env:SystemRoot 'SoftwareDistribution'
        if (Test-Path -LiteralPath $distributionPath) {
            $backupName = "SoftwareDistribution.old-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            try {
                Rename-Item -LiteralPath $distributionPath -NewName $backupName -ErrorAction Stop
                Write-RepairLog -Level Information -Stage Remediation -Message 'Renamed SoftwareDistribution cache.' -Data @{
                    backupName = $backupName
                }
            }
            catch {
                Write-RepairLog -Level Warning -Stage Remediation -Message 'Could not rename SoftwareDistribution; attempting delete.' -Data @{
                    error = $_.Exception.Message
                }
                Remove-Item -LiteralPath $distributionPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Set-WindowsUpdateServiceState -Action Start
        Start-Sleep -Seconds 15
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $result.basicRepairApplied = $true

        if (Test-WindowsUpdateComAvailable) {
            $result.comAvailable = $true
            $result.status = 'Ready'
            Write-RepairLog -Level Information -Stage Verify -Message 'Windows Update COM recovered after basic repair.'
            return
        }
    }

    if (-not $DeepRepair) {
        $result.rebootRequired = $true
        $result.status = 'RebootRequired'
        Write-RepairLog -Level Warning -Stage Verify -Message 'COM still unavailable after basic repair; reboot required.'
        return
    }

    Write-RepairLog -Level Warning -Stage DeepRepair -Message 'Starting DISM and SFC deep repair.'
    $result.deepRepairApplied = $true
    try {
        $result.dismExitCode = Invoke-ExternalCommand -FilePath "$env:SystemRoot\System32\Dism.exe" `
            -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') -Stage 'DeepRepair'
        $result.sfcExitCode = Invoke-ExternalCommand -FilePath "$env:SystemRoot\System32\sfc.exe" `
            -ArgumentList @('/scannow') -Stage 'DeepRepair'
    }
    catch {
        if ($_.Exception.Message -eq 'ServicingRebootRequired' -or $_.Exception.Message -match '800703FA|marked for deletion') {
            $result.rebootRequired = $true
            $result.status = 'RebootRequired'
            Write-RepairLog -Level Warning -Stage DeepRepair -Message 'Servicing registry requires reboot before DISM/SFC can run.'
            return
        }
        throw
    }

    Set-WindowsUpdateServiceState -Action Stop
    Start-Sleep -Seconds 5
    Set-WindowsUpdateServiceState -Action Start
    Start-Sleep -Seconds 20

    if (Test-WindowsUpdateComAvailable) {
        $result.comAvailable = $true
        $result.status = 'Ready'
        Write-RepairLog -Level Information -Stage Verify -Message 'Windows Update COM recovered after deep repair.'
        return
    }

    $result.rebootRequired = $true
    $result.status = 'RebootRequired'
    Write-RepairLog -Level Warning -Stage Verify -Message 'COM still unavailable after deep repair; reboot required.'
}
catch {
    $result.error = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        fullyQualifiedErrorId = $_.FullyQualifiedErrorId
        scriptStackTrace = $_.ScriptStackTrace
    }
    Write-RepairLog -Level Error -Stage Failure -Message $_.Exception.Message
}
finally {
    $completed = [DateTime]::UtcNow
    $result.completedUtc = $completed.ToString('o')
    $result.durationSeconds = [Math]::Round(($completed - $started).TotalSeconds, 2)
    $parent = Split-Path -Parent $ResultPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryResult = "$ResultPath.tmp"
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryResult -Encoding utf8
    Move-Item -LiteralPath $temporaryResult -Destination $ResultPath -Force
}

if ($result.status -eq 'Failed') { exit 1 }
exit 0
