#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsuPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$LogPath,
    [int]$MinimumUbr = 5074
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow

function Write-OfflineLog {
    param([string]$Level, [string]$Stage, [string]$Message)
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        stage = $Stage
        message = $Message
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8
}

$result = [ordered]@{
    schemaVersion = '1.0'
    status = 'Failed'
    startedUtc = $started.ToString('o')
    completedUtc = $null
    msuPath = $MsuPath
    wusaExitCode = $null
    rebootRequired = $false
    buildBefore = $null
    buildAfter = $null
    error = $null
}

try {
    if (-not (Test-Path -LiteralPath $MsuPath -PathType Leaf)) {
        throw "MSU not found at '$MsuPath'."
    }
    $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $result.buildBefore = "{0}.{1}" -f $ver.CurrentBuild, $ver.UBR
    Write-OfflineLog Information Install 'Starting offline cumulative MSU install.'

    $wusa = Join-Path $env:SystemRoot 'System32\wusa.exe'
    $proc = Start-Process -FilePath $wusa -ArgumentList @($MsuPath, '/quiet', '/norestart') -Wait -PassThru -NoNewWindow
    $result.wusaExitCode = [int]$proc.ExitCode
    if ($result.wusaExitCode -eq 3010) { $result.rebootRequired = $true }
    elseif ($result.wusaExitCode -ne 0) { throw "wusa.exe exited with code $($result.wusaExitCode)." }

    $ver2 = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $result.buildAfter = "{0}.{1}" -f $ver2.CurrentBuild, $ver2.UBR
    $ubr = [int]$ver2.UBR
    if ($ubr -ge $MinimumUbr) {
        $result.status = if ($result.rebootRequired) { 'RebootRequired' } else { 'Installed' }
    }
    else {
        $result.status = if ($result.rebootRequired) { 'RebootRequired' } else { 'InstalledPendingReboot' }
    }
    Write-OfflineLog Information Install 'Offline MSU install completed.' 
}
catch {
    $result.error = @{ message = $_.Exception.Message }
    Write-OfflineLog Error Failure $_.Exception.Message
}
finally {
    $result.completedUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

if ($result.status -eq 'Failed') { exit 1 }
exit 0
