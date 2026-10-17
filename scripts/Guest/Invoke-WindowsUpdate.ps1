#requires -Version 5.1
<#
.SYNOPSIS
Runs one native Windows Update Agent cycle inside a Windows guest.

.DESCRIPTION
This script deliberately has no dependency on PSWindowsUpdate or remote-management
protocols. The orchestrator copies it through VMware Guest Operations and launches
it locally in the guest. It scans, accepts update EULAs, downloads, and installs one
cycle, then writes machine-readable result and JSON Lines log files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Cycle,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$LogPath,
    [string]$SearchCriteria = "IsInstalled=0 and IsHidden=0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow

function Write-GuestLog {
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
        cycle = $Cycle
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

function Get-OperationResultName {
    param([int]$Code)
    switch ($Code) {
        0 { 'NotStarted' }
        1 { 'InProgress' }
        2 { 'Succeeded' }
        3 { 'SucceededWithErrors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { "Unknown($Code)" }
    }
}

function Test-WindowsUpdateComError {
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $message = @(
        $ErrorRecord.Exception.Message
        $ErrorRecord.FullyQualifiedErrorId
    ) -join ' '
    return $message -match '(?i)800703fa|8007041d|80040154|80070005|Microsoft\.Update\.(Session|SystemInfo)|COM class factory|marked for deletion|NoCOMClassIdentified|CimException|GetCimInstanceCommand'
}

function Get-BootAgeMinutes {
    try {
        $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        return (New-TimeSpan -Start $lastBoot -End (Get-Date)).TotalMinutes
    }
    catch {
        return 999
    }
}

function Test-RegistryRebootPending {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return $false
}

function Test-EffectiveRebootRequired {
    param(
        [bool]$SystemInfoRebootRequired
    )

    if (Test-RegistryRebootPending) { return $true }
    return [bool]$SystemInfoRebootRequired
}

function Get-ApplicableUpdates {
    param(
        [Parameter(Mandatory)]$UpdateSession,
        [Parameter(Mandatory)][string]$SearchCriteria
    )

    $searcher = $UpdateSession.CreateUpdateSearcher()
    $primary = $searcher.Search($SearchCriteria)
    $merged = @{}
    foreach ($update in @($primary.Updates)) {
        $merged[$update.Identity.UpdateID] = $update
    }

    # Defender/security intelligence and other definition updates can be missed by a single scan.
    $definitionCriteria = "$SearchCriteria and CategoryIDs contains '798'"
    try {
        $definitionResult = $searcher.Search($definitionCriteria)
        foreach ($update in @($definitionResult.Updates)) {
            if (-not $merged.ContainsKey($update.Identity.UpdateID)) {
                $merged[$update.Identity.UpdateID] = $update
            }
        }
    }
    catch {
        # Some agents reject the category filter; the primary scan is still used.
    }

    return @($merged.Values)
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

function Repair-WindowsUpdateAgent {
    Write-GuestLog -Level Warning -Stage Remediation -Message 'Repairing Windows Update Agent after COM failure.'

    Set-WindowsUpdateServiceState -Action Stop
    Start-Sleep -Seconds 5

    $distributionPath = Join-Path $env:SystemRoot 'SoftwareDistribution'
    if (Test-Path -LiteralPath $distributionPath) {
        $backupName = "SoftwareDistribution.old-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        $backupPath = Join-Path (Split-Path -Parent $distributionPath) $backupName
        try {
            Rename-Item -LiteralPath $distributionPath -NewName $backupName -ErrorAction Stop
            Write-GuestLog -Level Information -Stage Remediation -Message 'Renamed SoftwareDistribution cache.' -Data @{
                backupPath = $backupPath
            }
        }
        catch {
            Write-GuestLog -Level Warning -Stage Remediation -Message 'Could not rename SoftwareDistribution cache; continuing with service restart.' -Data @{
                error = $_.Exception.Message
            }
        }
    }

    Set-WindowsUpdateServiceState -Action Start
    Start-Sleep -Seconds 15
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-GuestLog -Level Information -Stage Remediation -Message 'Windows Update Agent remediation completed.'
}

function Initialize-WindowsUpdateEnvironment {
    $bootAgeMinutes = Get-BootAgeMinutes
    if ($bootAgeMinutes -ge 20) { return }

    Write-GuestLog -Level Information -Stage Initialize -Message 'Recent reboot detected; warming up Windows Update services.' -Data @{
        bootAgeMinutes = [Math]::Round($bootAgeMinutes, 2)
    }
    Set-WindowsUpdateServiceState -Action Start
    $warmUpSeconds = if ($bootAgeMinutes -lt 5) { 90 } else { 45 }
    Start-Sleep -Seconds $warmUpSeconds
}

function New-WindowsUpdateSession {
    param(
        [ValidateRange(1, 4)][int]$MaxAttempts = 3
    )

    $remediationApplied = $false
    $bootAgeMinutes = Get-BootAgeMinutes
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSession.ClientApplicationID = 'Enterprise Windows Patch Automation Framework'
            $systemInformation = New-Object -ComObject Microsoft.Update.SystemInfo
            return [pscustomobject]@{
                Session = $updateSession
                SystemInfo = $systemInformation
                RemediationApplied = $remediationApplied
            }
        }
        catch {
            $isComError = Test-WindowsUpdateComError -ErrorRecord $_
            if (-not $isComError -or $attempt -eq $MaxAttempts) { throw }

            if ($bootAgeMinutes -lt 15) {
                Write-GuestLog -Level Warning -Stage Initialize -Message 'COM unavailable shortly after reboot; waiting for guest servicing to settle.' -Data @{
                    bootAgeMinutes = [Math]::Round($bootAgeMinutes, 2)
                    attempt = $attempt
                }
                Set-WindowsUpdateServiceState -Action Start
                Start-Sleep -Seconds 60
                continue
            }

            Repair-WindowsUpdateAgent
            $remediationApplied = $true
        }
    }

    throw 'Unable to create Windows Update COM session.'
}

$result = [ordered]@{
    schemaVersion = '1.0'
    computerName = $env:COMPUTERNAME
    cycle = $Cycle
    status = 'Failed'
    searchCriteria = $SearchCriteria
    startedUtc = $started.ToString('o')
    completedUtc = $null
    durationSeconds = 0
    applicableCount = 0
    downloadedCount = 0
    installedCount = 0
    failedCount = 0
    rebootRequired = $false
    remediationApplied = $false
    updates = @()
    error = $null
}

try {
    Write-GuestLog -Level Information -Stage Initialize -Message 'Starting Windows Update cycle.'
    try {
        & "$env:SystemRoot\System32\netsh.exe" winhttp reset proxy | Out-Null
        & "$env:SystemRoot\System32\netsh.exe" winhttp import proxy source=ie | Out-Null
        $auKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (Test-Path -LiteralPath $auKey) {
            Remove-ItemProperty -LiteralPath $auKey -Name UseWUServer -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $auKey -Name WUServer -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $auKey -Name WUStatusServer -ErrorAction SilentlyContinue
        }
        Write-GuestLog -Level Information -Stage Initialize -Message 'Reset WinHTTP proxy and cleared WSUS policy overrides when present.'
    }
    catch {
        Write-GuestLog -Level Warning -Stage Initialize -Message 'Could not reset WinHTTP/WSUS settings.' -Data @{
            error = $_.Exception.Message
        }
    }
    try {
        Initialize-WindowsUpdateEnvironment
    }
    catch {
        if (-not (Test-WindowsUpdateComError -ErrorRecord $_)) { throw }
        Write-GuestLog -Level Warning -Stage Initialize -Message 'Initialize warm-up failed due to pending registry deletion; continuing with remediation-aware session startup.'
    }

    $sessionContext = $null
    try {
        $sessionContext = New-WindowsUpdateSession
    }
    catch {
        if (Test-WindowsUpdateComError -ErrorRecord $_) {
            Repair-WindowsUpdateAgent
            $result.remediationApplied = $true
            Start-Sleep -Seconds 30
            try {
                $sessionContext = New-WindowsUpdateSession
            }
            catch {
                $result.rebootRequired = $true
                $result.status = 'RebootRequired'
                Write-GuestLog -Level Warning -Stage Remediation -Message 'Windows Update COM still unavailable after remediation; reboot is required before retrying.'
                return
            }
        }
        else {
            throw
        }
    }

    $result.remediationApplied = [bool]$sessionContext.RemediationApplied
    $updateSession = $sessionContext.Session
    $systemInformation = $sessionContext.SystemInfo

    Write-GuestLog -Level Information -Stage Scan -Message 'Scanning Windows Update Agent.' -Data @{
        criteria = $SearchCriteria
    }
    $applicableUpdates = @(Get-ApplicableUpdates -UpdateSession $updateSession -SearchCriteria $SearchCriteria)
    $result.applicableCount = $applicableUpdates.Count

    if ($applicableUpdates.Count -eq 0) {
        $result.rebootRequired = Test-EffectiveRebootRequired -SystemInfoRebootRequired ([bool]$systemInformation.RebootRequired)
        if ($result.rebootRequired) {
            $result.status = 'RebootRequired'
            Write-GuestLog -Level Information -Stage Scan -Message 'No updates found, but Windows reports a pending reboot.'
        }
        else {
            $result.status = 'NoUpdates'
            Write-GuestLog -Level Information -Stage Scan -Message 'No applicable updates remain.'
        }
    }
    else {
        $downloadCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $applicableUpdates) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
                Write-GuestLog -Level Information -Stage Eula -Message 'Accepted update EULA.' -Data @{
                    title = $update.Title
                }
            }
            [void]$downloadCollection.Add($update)
        }

        Write-GuestLog -Level Information -Stage Download -Message 'Downloading applicable updates.' -Data @{
            count = $downloadCollection.Count
        }
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $downloadCollection
        $downloadResult = $downloader.Download()
        $downloadResultName = Get-OperationResultName -Code ([int]$downloadResult.ResultCode)
        if ($downloadResult.ResultCode -notin 2, 3) {
            throw "Windows Update download failed with result '$downloadResultName'."
        }

        $installCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $downloadCollection.Count; $index++) {
            $update = $downloadCollection.Item($index)
            if ($update.IsDownloaded) {
                [void]$installCollection.Add($update)
                $result.downloadedCount++
            }
        }
        if ($installCollection.Count -eq 0) {
            throw 'No updates were downloaded successfully.'
        }

        Write-GuestLog -Level Information -Stage Install -Message 'Installing downloaded updates.' -Data @{
            count = $installCollection.Count
        }
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $installCollection
        $installResult = $installer.Install()
        $systemInformation = New-Object -ComObject Microsoft.Update.SystemInfo
        $result.rebootRequired = Test-EffectiveRebootRequired -SystemInfoRebootRequired (
            [bool]($installResult.RebootRequired -or $systemInformation.RebootRequired)
        )

        for ($index = 0; $index -lt $installCollection.Count; $index++) {
            $update = $installCollection.Item($index)
            $perUpdateResult = $installResult.GetUpdateResult($index)
            $code = [int]$perUpdateResult.ResultCode
            $succeeded = $code -in 2, 3
            if ($succeeded) { $result.installedCount++ } else { $result.failedCount++ }
            $kbArticleIds = @($update.KBArticleIDs | ForEach-Object { "KB$_" })
            $hResultUnsigned = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int32]$perUpdateResult.HResult), 0
            )
            $result.updates += [ordered]@{
                title = $update.Title
                kbArticleIds = $kbArticleIds
                resultCode = $code
                result = Get-OperationResultName -Code $code
                hResult = ('0x{0:X8}' -f $hResultUnsigned)
                rebootRequired = [bool]$update.RebootRequired
            }
        }

        $overallResult = Get-OperationResultName -Code ([int]$installResult.ResultCode)
        if ($installResult.ResultCode -notin 2, 3 -or $result.failedCount -gt 0) {
            throw "Windows Update installation completed as '$overallResult' with $($result.failedCount) failed update(s)."
        }
        $result.status = 'Installed'
        Write-GuestLog -Level Information -Stage Install -Message 'Update installation cycle completed.' -Data @{
            installedCount = $result.installedCount
            rebootRequired = $result.rebootRequired
            result = $overallResult
        }
    }
}
catch {
    $result.status = 'Failed'
    $result.error = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        fullyQualifiedErrorId = $_.FullyQualifiedErrorId
        scriptStackTrace = $_.ScriptStackTrace
    }
    Write-GuestLog -Level Error -Stage Failure -Message $_.Exception.Message -Data @{
        type = $_.Exception.GetType().FullName
    }
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
