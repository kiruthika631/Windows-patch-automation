Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PatchVCenterSessions = @{}
$script:PatchVMInventoryCache = @{}
$script:PowerCLIInitialized = $false

function Initialize-PowerCLISession {
    [CmdletBinding()]
    param(
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300
    )

    if ($script:PowerCLIInitialized) { return }

    $certificateAction = if ($IgnoreInvalidCertificate) { 'Ignore' } else { 'Fail' }
    Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP:$false -InvalidCertificateAction $certificateAction `
        -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds -Confirm:$false | Out-Null
    $script:PowerCLIInitialized = $true
}

function Connect-PatchVCenter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][pscredential]$Credential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300
    )

    Initialize-PowerCLISession -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
        -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds

    $sessionKey = $Server.ToLowerInvariant()
    if ($script:PatchVCenterSessions.ContainsKey($sessionKey)) {
        return $script:PatchVCenterSessions[$sessionKey]
    }

    $session = Connect-VIServer -Server $Server -Credential $Credential -Force -ErrorAction Stop
    $script:PatchVCenterSessions[$sessionKey] = $session
    $script:PatchVCenterSessions[$session.Name.ToLowerInvariant()] = $session
    $session
}

function Get-PatchVCenterSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server
    )

    $sessionKey = $Server.ToLowerInvariant()
    if ($script:PatchVCenterSessions.ContainsKey($sessionKey)) {
        return $script:PatchVCenterSessions[$sessionKey]
    }

    $connected = @(Get-VIServer -ErrorAction SilentlyContinue | Where-Object {
            $_.Name.ToLowerInvariant() -eq $sessionKey -or $_.Name.ToLowerInvariant() -like "*$($sessionKey.Split('.')[0])*"
        })
    if ($connected.Count -eq 1) {
        return $connected[0]
    }

    throw "No active vCenter session for '$Server'. Connect with Connect-PatchVCenter first; do not enter Windows guest credentials at a vCenter login prompt."
}

function Test-GuestCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential
    )

    $result = Invoke-VMScript -VM $VM -GuestCredential $GuestCredential -ScriptType PowerShell `
        -ScriptText 'Write-Output $env:COMPUTERNAME' -ErrorAction Stop
    if ($result.ExitCode -ne 0) {
        throw "Guest credential test failed with exit code $($result.ExitCode): $($result.ScriptOutput)"
    }
    [string]($result.ScriptOutput).Trim()
}

function Get-PatchVMInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Server
    )

    $sessionKey = if ($Server -is [string]) { $Server.ToLowerInvariant() } else { $Server.Name.ToLowerInvariant() }
    if ($script:PatchVMInventoryCache.ContainsKey($sessionKey)) {
        return $script:PatchVMInventoryCache[$sessionKey]
    }

    $inventory = @(Get-VM -Server $Server)
    $script:PatchVMInventoryCache[$sessionKey] = $inventory
    $inventory
}

function Get-UniquePatchVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)]$Server,
        [string]$IPAddress
    )

    $matches = @(Get-VM -Name $VMName -Server $Server -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($IPAddress)) {
        $targetIp = $IPAddress.Trim()
        $matches = @(Get-PatchVMInventory -Server $Server | Where-Object {
                @($_.ExtensionData.Guest.IpAddress | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -contains $targetIp
            })
    }

    if ($matches.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
            throw "VM '$VMName' was not found in vCenter (also checked IP '$IPAddress')."
        }
        throw "VM '$VMName' was not found in vCenter."
    }
    if ($matches.Count -gt 1) {
        $detail = if (-not [string]::IsNullOrWhiteSpace($IPAddress)) { " for name '$VMName' or IP '$IPAddress'" } else { " for name '$VMName'" }
        throw "VM lookup$detail is ambiguous ($($matches.Count) matches)."
    }
    $matches[0]
}

function Test-VMToolsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server
    )

    $freshVM = Get-VM -Id $VM.Id -Server $Server -ErrorAction Stop
    $toolsStatus = $freshVM.ExtensionData.Guest.ToolsRunningStatus
    $guestState = $freshVM.ExtensionData.Guest.GuestState
    ($freshVM.PowerState -eq 'PoweredOn' -and
        $toolsStatus -eq 'guestToolsRunning' -and
        $guestState -eq 'running')
}

function Wait-VMToolsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [ValidateRange(30, 7200)][int]$TimeoutSeconds = 900,
        [ValidateRange(2, 120)][int]$PollSeconds = 10,
        [switch]$RequireObservedNotReady
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observedNotReady = -not $RequireObservedNotReady
    do {
        try {
            $ready = Test-VMToolsReady -VM $VM -Server $Server
            if (-not $ready) { $observedNotReady = $true }
            if ($ready -and $observedNotReady) { return }
        }
        catch {
            $observedNotReady = $true
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "VMware Tools/guest readiness timed out after $TimeoutSeconds seconds for '$($VM.Name)'."
}

function Invoke-GuestPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$ScriptText,
        [switch]$RunAsync
    )

    $invokeParams = @{
        VM = $VM
        GuestCredential = $GuestCredential
        ScriptType = 'PowerShell'
        ScriptText = $ScriptText
        ErrorAction = 'Stop'
    }
    if ($RunAsync) {
        $invokeParams.RunAsync = $true
    }

    $result = Invoke-VMScript @invokeParams
    if (-not $RunAsync -and $result.ExitCode -ne 0) {
        throw "Guest operation exited with code $($result.ExitCode): $($result.ScriptOutput)"
    }
    if ($RunAsync) { return $result }
    $result.ScriptOutput
}

function Enable-GuestLocalAdminTokenPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential
    )

    $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @'
$ErrorActionPreference = 'Stop'
$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$current = 0
try {
    $current = [int](Get-ItemProperty -LiteralPath $regPath -Name LocalAccountTokenFilterPolicy -ErrorAction Stop).LocalAccountTokenFilterPolicy
}
catch {
    $current = 0
}
$changed = $false
if ($current -ne 1) {
    New-ItemProperty -Path $regPath -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
    $changed = $true
}
[pscustomobject]@{
    changed = $changed
    previousValue = $current
    currentValue = 1
} | ConvertTo-Json -Compress
'@

    $parsed = $output.Trim() | ConvertFrom-Json
    [pscustomobject]@{
        Changed = [bool]$parsed.changed
        PreviousValue = [int]$parsed.previousValue
        CurrentValue = [int]$parsed.currentValue
    }
}

function Test-GuestWindowsUpdateComAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [string]$SearchCriteria = 'IsInstalled=0 and IsHidden=0'
    )

    try {
        $escapedCriteria = $SearchCriteria.Replace("'", "''")
        $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
try {
    `$session = New-Object -ComObject Microsoft.Update.Session
    `$session.ClientApplicationID = 'Enterprise Windows Patch Automation Framework'
    `$null = New-Object -ComObject Microsoft.Update.SystemInfo
    `$searcher = `$session.CreateUpdateSearcher()
    `$null = `$searcher.Search('$escapedCriteria').Updates
    Write-Output 'OK'
}
catch {
    Write-Output 'FAIL'
}
"@
        return ($output.Trim() -eq 'OK')
    }
    catch {
        return $false
    }
}

function Get-GuestDetachedJobLauncherScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EncodedCommand,
        [Parameter(Mandatory)][string]$EscapedResultPath,
        [Parameter(Mandatory)][string]$EscapedLogPath,
        [Parameter(Mandatory)][string]$EscapedPidPath
    )

    @"
`$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath '$EscapedResultPath', '$EscapedLogPath', '$EscapedPidPath' -Force -ErrorAction SilentlyContinue
`$exe = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
`$commandLine = "`$exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $EncodedCommand"
`$processClass = [wmiclass]'Win32_Process'
`$createResult = `$processClass.Create(`$commandLine)
if (`$createResult.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed with return code `$(`$createResult.ReturnValue)."
}
`$processId = [int]`$createResult.ProcessId
Set-Content -LiteralPath '$EscapedPidPath' -Value `$processId -Encoding ascii
Write-Output `$processId
"@
}

function Initialize-GuestPatchWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory
    )

    $escaped = $GuestWorkingDirectory.Replace("'", "''")
    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path '$escaped' -Force | Out-Null
"@ | Out-Null
}

function Reset-GuestPatchWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory
    )

    $escaped = $GuestWorkingDirectory.Replace("'", "''")
    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'SilentlyContinue'
`$root = '$escaped'
if (-not (Test-Path -LiteralPath `$root)) { return }
Get-ChildItem -LiteralPath `$root -Filter '*.pid' -File | ForEach-Object {
    `$processId = 0
    [void][int]::TryParse((Get-Content -LiteralPath `$_.FullName -Raw).Trim(), [ref]`$processId)
    if (`$processId -gt 0) {
        Stop-Process -Id `$processId -Force -ErrorAction SilentlyContinue
    }
}
Get-ChildItem -LiteralPath `$root -File |
    Where-Object { `$_.Name -like 'cycle-*' -or `$_.Name -like 'repair-*' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
"@ | Out-Null
}

function Copy-PatchScriptToGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $Source -Destination $Destination `
        -LocalToGuest -Force -ErrorAction Stop | Out-Null
}

function Start-GuestPatchCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [Parameter(Mandatory)][string]$SearchCriteria,
        [ValidateRange(1, 100)][int]$Cycle
    )

    $guestRoot = $GuestWorkingDirectory.TrimEnd('\', '/')
    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = "$guestRoot\cycle-$Cycle-$jobId-result.json"
    $logPath = "$guestRoot\cycle-$Cycle-$jobId-log.jsonl"
    $pidPath = "$guestRoot\cycle-$Cycle-$jobId.pid"
    $escapedScript = $GuestScriptPath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $escapedPid = $pidPath.Replace("'", "''")
    $escapedCriteria = $SearchCriteria.Replace("'", "''")
    $patchCommand = "& '$escapedScript' -Cycle $Cycle -ResultPath '$escapedResult' -LogPath '$escapedLog' -SearchCriteria '$escapedCriteria'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($patchCommand))

    $launcherScript = Get-GuestDetachedJobLauncherScript -EncodedCommand $encodedCommand `
        -EscapedResultPath $escapedResult -EscapedLogPath $escapedLog -EscapedPidPath $escapedPid
    $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText $launcherScript

    [pscustomobject]@{
        ProcessId = [int]($output.Trim() -split '\s+')[-1]
        ResultPath = $resultPath
        LogPath = $logPath
        PidPath = $pidPath
    }
}

function Invoke-GuestPatchCycleSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [Parameter(Mandatory)][string]$SearchCriteria,
        [ValidateRange(1, 100)][int]$Cycle
    )

    $guestRoot = $GuestWorkingDirectory.TrimEnd('\', '/')
    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = "$guestRoot\cycle-$Cycle-$jobId-result.json"
    $logPath = "$guestRoot\cycle-$Cycle-$jobId-log.jsonl"
    $escapedScript = $GuestScriptPath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $escapedCriteria = $SearchCriteria.Replace("'", "''")
    $patchCommand = "& '$escapedScript' -Cycle $Cycle -ResultPath '$escapedResult' -LogPath '$escapedLog' -SearchCriteria '$escapedCriteria'"

    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText $patchCommand | Out-Null

    [pscustomobject]@{
        ProcessId = 0
        ResultPath = $resultPath
        LogPath = $logPath
        PidPath = $null
    }
}

function Repair-PatchVCenterSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][pscredential]$Credential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300
    )

    try {
        Connect-PatchVCenter -Server $Server -Credential $Credential -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
            -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds | Out-Null
    }
    catch {
        # Best-effort reconnect during long-running guest polling.
    }
}

function Wait-GuestPatchCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$CycleHandle,
        [string]$Server,
        [pscredential]$VCenterCredential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300,
        [ValidateRange(60, 28800)][int]$TimeoutSeconds = 7200,
        [ValidateRange(5, 300)][int]$PollSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $escapedResult = $CycleHandle.ResultPath.Replace("'", "''")
    $pid = $CycleHandle.ProcessId
    $lastPollError = $null
    do {
        try {
            $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
if (Test-Path -LiteralPath '$escapedResult' -PathType Leaf) { 'COMPLETE' }
elseif (Get-Process -Id $pid -ErrorAction SilentlyContinue) { 'RUNNING' }
else { 'EXITED' }
"@
            if ($output -match 'COMPLETE') { return }
            if ($output -match 'EXITED') {
                throw "Guest patch process $pid exited without producing a result file."
            }
            $lastPollError = $null
        }
        catch {
            if ($_.Exception.Message -match 'exited without producing') { throw }
            $lastPollError = $_.Exception.Message
            if ($Server -and $VCenterCredential -and $_.Exception.Message -match 'connection|timed out|not authenticated|required by the current operation') {
                Repair-PatchVCenterSession -Server $Server -Credential $VCenterCredential `
                    -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
                    -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds
            }
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    try {
        Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText `
            "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" | Out-Null
    }
    catch { }
    $detail = if ($lastPollError) { " Last polling error: $lastPollError" } else { '' }
    throw "Windows Update cycle exceeded the $TimeoutSeconds second timeout.$detail"
}

function Start-GuestRepairJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [switch]$DeepRepair,
        [switch]$ForceDeepRepair
    )

    $guestRoot = $GuestWorkingDirectory.TrimEnd('\', '/')
    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = "$guestRoot\repair-$jobId-result.json"
    $logPath = "$guestRoot\repair-$jobId-log.jsonl"
    $pidPath = "$guestRoot\repair-$jobId.pid"
    $escapedScript = $GuestScriptPath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $escapedPid = $pidPath.Replace("'", "''")
    $deepRepairFlag = if ($DeepRepair -or $ForceDeepRepair) { '-DeepRepair' } else { '' }
    $repairCommand = "& '$escapedScript' -ResultPath '$escapedResult' -LogPath '$escapedLog' $deepRepairFlag"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($repairCommand))

    $launcherScript = Get-GuestDetachedJobLauncherScript -EncodedCommand $encodedCommand `
        -EscapedResultPath $escapedResult -EscapedLogPath $escapedLog -EscapedPidPath $escapedPid
    $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText $launcherScript

    [pscustomobject]@{
        ProcessId = [int]($output.Trim() -split '\s+')[-1]
        ResultPath = $resultPath
        LogPath = $logPath
        PidPath = $pidPath
    }
}

function Wait-GuestRepairJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$RepairHandle,
        [string]$Server,
        [pscredential]$VCenterCredential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300,
        [ValidateRange(60, 28800)][int]$TimeoutSeconds = 7200,
        [ValidateRange(5, 300)][int]$PollSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $escapedResult = $RepairHandle.ResultPath.Replace("'", "''")
    $pid = $RepairHandle.ProcessId
    $lastPollError = $null
    do {
        try {
            $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
if (Test-Path -LiteralPath '$escapedResult' -PathType Leaf) { 'COMPLETE' }
elseif (Get-Process -Id $pid -ErrorAction SilentlyContinue) { 'RUNNING' }
else { 'EXITED' }
"@
            if ($output -match 'COMPLETE') { return }
            if ($output -match 'EXITED') {
                throw "Guest repair process $pid exited without producing a result file."
            }
            $lastPollError = $null
        }
        catch {
            if ($_.Exception.Message -match 'exited without producing') { throw }
            $lastPollError = $_.Exception.Message
            if ($Server -and $VCenterCredential -and $_.Exception.Message -match 'connection|timed out|not authenticated|required by the current operation') {
                Repair-PatchVCenterSession -Server $Server -Credential $VCenterCredential `
                    -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
                    -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds
            }
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    try {
        Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText `
            "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" | Out-Null
    }
    catch { }
    $detail = if ($lastPollError) { " Last polling error: $lastPollError" } else { '' }
    throw "Windows Update repair exceeded the $TimeoutSeconds second timeout.$detail"
}

function Copy-GuestRepairArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$RepairHandle,
        [Parameter(Mandatory)][string]$LocalDirectory
    )

    New-Item -ItemType Directory -Path $LocalDirectory -Force | Out-Null
    $localResult = Join-Path $LocalDirectory 'repair-result.json'
    $localLog = Join-Path $LocalDirectory 'repair-log.jsonl'
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $RepairHandle.ResultPath `
        -Destination $localResult -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $RepairHandle.LogPath `
        -Destination $localLog -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Get-Content -LiteralPath $localResult -Raw | ConvertFrom-Json -Depth 20
}

function Invoke-GuestWindowsUpdateRepairSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [Parameter(Mandatory)][string]$LocalDirectory,
        [switch]$DeepRepair,
        [switch]$ForceDeepRepair
    )

    $guestRoot = $GuestWorkingDirectory.TrimEnd('\', '/')
    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = "$guestRoot\repair-sync-$jobId-result.json"
    $logPath = "$guestRoot\repair-sync-$jobId-log.jsonl"
    $escapedScript = $GuestScriptPath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $deepRepairFlag = if ($DeepRepair -or $ForceDeepRepair) { '-DeepRepair' } else { '' }

    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
& '$escapedScript' -ResultPath '$escapedResult' -LogPath '$escapedLog' $deepRepairFlag
"@ | Out-Null

    New-Item -ItemType Directory -Path $LocalDirectory -Force | Out-Null
    $localResult = Join-Path $LocalDirectory 'repair-result.json'
    $localLog = Join-Path $LocalDirectory 'repair-log.jsonl'
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $resultPath `
        -Destination $localResult -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $logPath `
        -Destination $localLog -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Get-Content -LiteralPath $localResult -Raw | ConvertFrom-Json -Depth 20
}

function Invoke-GuestWindowsUpdateRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [Parameter(Mandatory)][string]$LocalDirectory,
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][pscredential]$VCenterCredential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300,
        [ValidateRange(60, 28800)][int]$TimeoutSeconds = 7200,
        [ValidateRange(5, 300)][int]$PollSeconds = 20,
        [switch]$DeepRepair,
        [switch]$ForceDeepRepair
    )

    $useDeepRepair = [bool]$DeepRepair -or [bool]$ForceDeepRepair

    if ($useDeepRepair) {
        $repairHandle = Start-GuestRepairJob -VM $VM -GuestCredential $GuestCredential `
            -GuestScriptPath $GuestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory `
            -DeepRepair -ForceDeepRepair:$ForceDeepRepair
        Wait-GuestRepairJob -VM $VM -GuestCredential $GuestCredential -RepairHandle $repairHandle `
            -Server $Server -VCenterCredential $VCenterCredential -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
            -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds -TimeoutSeconds $TimeoutSeconds `
            -PollSeconds $PollSeconds
        return Copy-GuestRepairArtifacts -VM $VM -GuestCredential $GuestCredential -RepairHandle $repairHandle `
            -LocalDirectory $LocalDirectory
    }

    try {
        return Invoke-GuestWindowsUpdateRepairSync -VM $VM -GuestCredential $GuestCredential `
            -GuestScriptPath $GuestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory `
            -LocalDirectory $LocalDirectory
    }
    catch {
        # Fall back to detached worker for environments where sync repair fails.
    }

    $repairHandle = Start-GuestRepairJob -VM $VM -GuestCredential $GuestCredential `
        -GuestScriptPath $GuestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory
    Wait-GuestRepairJob -VM $VM -GuestCredential $GuestCredential -RepairHandle $repairHandle `
        -Server $Server -VCenterCredential $VCenterCredential -IgnoreInvalidCertificate $IgnoreInvalidCertificate `
        -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds -TimeoutSeconds $TimeoutSeconds `
        -PollSeconds $PollSeconds
    Copy-GuestRepairArtifacts -VM $VM -GuestCredential $GuestCredential -RepairHandle $repairHandle `
        -LocalDirectory $LocalDirectory
}

function Copy-GuestPatchArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$CycleHandle,
        [Parameter(Mandatory)][string]$LocalDirectory,
        [ValidateRange(1, 100)][int]$Cycle
    )

    New-Item -ItemType Directory -Path $LocalDirectory -Force | Out-Null
    $localResult = Join-Path $LocalDirectory "cycle-$Cycle-result.json"
    $localLog = Join-Path $LocalDirectory "cycle-$Cycle-guest.jsonl"
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $CycleHandle.ResultPath `
        -Destination $localResult -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $CycleHandle.LogPath `
        -Destination $localLog -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Get-Content -LiteralPath $localResult -Raw | ConvertFrom-Json -Depth 20
}

function Restart-PatchVMGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [ValidateRange(30, 7200)][int]$TimeoutSeconds = 1200,
        [ValidateRange(2, 120)][int]$PollSeconds = 10,
        [ValidateRange(0, 600)][int]$PostRebootWarmUpSeconds = 90
    )

    try {
        Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText `
            'Restart-Computer -Force' | Out-Null
    }
    catch {
        # Guest Operations commonly loses the response while Windows is shutting down.
    }
    Wait-VMToolsReady -VM $VM -Server $Server -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -RequireObservedNotReady

    if ($PostRebootWarmUpSeconds -gt 0) {
        Invoke-GuestPostRebootWarmUp -VM $VM -GuestCredential $GuestCredential -WarmUpSeconds $PostRebootWarmUpSeconds
    }
}

function Invoke-GuestPostRebootWarmUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [ValidateRange(0, 600)][int]$WarmUpSeconds = 90
    )

    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'SilentlyContinue'
foreach (`$serviceName in @('cryptsvc','bits','wuauserv','msiserver')) {
    Set-Service -Name `$serviceName -StartupType Manual
    Start-Service -Name `$serviceName
}
Start-Sleep -Seconds $WarmUpSeconds
"@ | Out-Null
}

function Test-GuestPatchConvergence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$SearchCriteria
    )

    $escapedCriteria = $SearchCriteria.Replace("'", "''")
    $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'Stop'
`$criteria = '$escapedCriteria'
`$session = New-Object -ComObject Microsoft.Update.Session
`$searcher = `$session.CreateUpdateSearcher()
`$result = `$searcher.Search(`$criteria)
`$info = New-Object -ComObject Microsoft.Update.SystemInfo
`$registryRebootPending = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
) | Where-Object { Test-Path -LiteralPath `$_ }
`$pendingCount = [int]`$result.Updates.Count
# Pending count and registry reboot keys are authoritative. SystemInfo.RebootRequired can remain
# stale after updates are fully installed and causes false MaxCyclesExceeded / reboot-only loops.
`$isCompliant = (`$pendingCount -eq 0) -and (`$registryRebootPending.Count -eq 0)
[pscustomobject]@{
    pendingUpdates = `$pendingCount
    rebootRequired = [bool]`$info.RebootRequired
    registryRebootPending = (`$registryRebootPending.Count -gt 0)
    isCompliant = `$isCompliant
} | ConvertTo-Json -Compress
"@

    $parsed = $output.Trim() | ConvertFrom-Json
    [pscustomobject]@{
        PendingUpdates = [int]$parsed.pendingUpdates
        RebootRequired = [bool]$parsed.rebootRequired
        RegistryRebootPending = [bool]$parsed.registryRebootPending
        IsCompliant = [bool]$parsed.isCompliant
    }
}

Export-ModuleMember -Function Initialize-PowerCLISession, Connect-PatchVCenter, Get-PatchVCenterSession,
    Repair-PatchVCenterSession, Get-PatchVMInventory, Test-GuestCredential, Get-UniquePatchVM, Test-VMToolsReady,
    Wait-VMToolsReady, Invoke-GuestPowerShell, Enable-GuestLocalAdminTokenPolicy, Test-GuestWindowsUpdateComAvailable,
    Initialize-GuestPatchWorkspace, Reset-GuestPatchWorkspace, Copy-PatchScriptToGuest, Start-GuestPatchCycle,
    Invoke-GuestPatchCycleSync, Wait-GuestPatchCycle, Start-GuestRepairJob, Wait-GuestRepairJob, Copy-GuestRepairArtifacts,
    Invoke-GuestWindowsUpdateRepairSync, Invoke-GuestWindowsUpdateRepair, Copy-GuestPatchArtifacts, Restart-PatchVMGuest, Invoke-GuestPostRebootWarmUp, Test-GuestPatchConvergence
